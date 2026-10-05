//! One debug adapter session: the DAP envelope over `rpc/jsonrpc`'s
//! transport, the requests mnml sends, and the state a stop fills
//! (frames, scopes, threads, the variables cache, watch results, the
//! output log). The app-side handler (`app/dap.zig`) drives the
//! handshake and reacts to events; this file owns the wire and the
//! data.
//!
//! Snapshots (D1): frames / scopes / threads live on `snapshot`, replaced
//! wholesale on every stop; variables live on `vars` and are dropped when
//! the program resumes, since their references go stale across a
//! continue. Everything the session keeps for its whole life (filters,
//! output lines, watch results) is gpa-owned and freed in `deinit`.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("mnml_sdk").zig_compat;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const jsonrpc = @import("../rpc/jsonrpc.zig");
const Transport = jsonrpc.Transport;
const Value = jsonrpc.Value;
const event = @import("../core/event.zig");
const alloc = @import("../core/alloc.zig");
const types = @import("types.zig");

/// What a request was for — the transport's `Pending.kind`, so a reply
/// routes without re-reading its `command`.
pub const ReqKind = enum(u16) {
    initialize,
    launch,
    set_breakpoints,
    set_exception_breakpoints,
    configuration_done,
    @"continue",
    next,
    step_in,
    step_out,
    pause,
    step_back,
    reverse_continue,
    threads,
    stack_trace,
    scopes,
    variables,
    evaluate_repl,
    evaluate_watch,
    evaluate_hover,
    set_variable,
    source,
    terminate,
    disconnect,
    cancel,
};

pub const SendError = jsonrpc.SendError || Allocator.Error;

/// A parsed frame from the adapter, by DAP `type`.
pub const Message = union(enum) {
    response: struct { request_seq: i64, command: []const u8, success: bool, message: ?[]const u8, body: ?Value },
    event: struct { name: []const u8, body: ?Value },
    /// A reverse request (`runInTerminal`); answered with a failure.
    request: struct { seq: i64, command: []const u8 },
    unknown,
};

pub fn classify(v: Value) Message {
    const kind = jsonrpc.getStr(v, "type") orelse return .unknown;
    if (std.mem.eql(u8, kind, "response")) {
        return .{ .response = .{
            .request_seq = jsonrpc.getInt(v, "request_seq") orelse return .unknown,
            .command = jsonrpc.getStr(v, "command") orelse "",
            .success = jsonrpc.getBool(v, "success") orelse false,
            .message = jsonrpc.getStr(v, "message"),
            .body = jsonrpc.getField(v, "body"),
        } };
    }
    if (std.mem.eql(u8, kind, "event")) {
        return .{ .event = .{ .name = jsonrpc.getStr(v, "event") orelse return .unknown, .body = jsonrpc.getField(v, "body") } };
    }
    if (std.mem.eql(u8, kind, "request")) {
        return .{ .request = .{ .seq = jsonrpc.getInt(v, "seq") orelse 0, .command = jsonrpc.getStr(v, "command") orelse "" } };
    }
    return .unknown;
}

pub const Session = struct {
    gpa: Allocator,
    io: Io,
    events: *event.EventQueue,
    /// Which session an event belongs to; a late frame from a session
    /// already torn down is dropped by number.
    id: u32,
    transport: *Transport,
    /// The adapter's command, for toasts. Owned.
    adapter: []u8,
    /// The substituted `launch` / `attach` arguments as JSON. Owned;
    /// sent on the `initialize` reply.
    launch_body: []u8,
    /// The body's `request` is `attach`: the debuggee is somebody
    /// else's process. Stop then DETACHES — `disconnect` with
    /// `terminateDebuggee: false` and no `terminate` — where a launched
    /// session ends its program (hunt: dap-stop-kills-attached-process).
    is_attach: bool,

    /// The adapter's `initialized` event has arrived: it is ready for
    /// breakpoints and `configurationDone`.
    initialized: bool = false,
    /// The `initialize` reply has landed (the capabilities are known).
    /// netcoredbg sends `initialized` before it, lldb-dap and debugpy
    /// only while handling `launch`; the configuration step waits for
    /// both flags, whichever order they come in.
    ready: bool = false,
    /// `configurationDone` has been sent.
    configured: bool = false,
    running: bool = false,
    /// The thread the last `stopped` named; step requests address it.
    thread: ?i64 = null,
    /// The frame the call stack selected; null = the top frame. What
    /// `evaluate` and the scopes address. Reset on every stop.
    frame_id: ?i64 = null,
    stopped: ?types.Stopped = null,
    exited: bool = false,

    snapshot: alloc.SnapshotArena,
    frames: []types.StackFrame = &.{},
    scopes: []types.Scope = &.{},
    threads: []types.Thread = &.{},
    vars: alloc.SnapshotArena,
    variables: std.AutoHashMapUnmanaged(i64, []types.Variable) = .empty,
    expanded: std.AutoHashMapUnmanaged(i64, void) = .empty,

    filters: std.ArrayListUnmanaged(types.ExceptionFilter) = .empty,
    /// Enabled filter ids; owned keys.
    enabled_filters: std.StringHashMapUnmanaged(void) = .empty,
    output: std.ArrayListUnmanaged(types.OutputLine) = .empty,
    /// Keyed by expression (owned).
    watch_results: std.StringHashMapUnmanaged(types.WatchResult) = .empty,
    /// The expression behind each in-flight `evaluate`, indexed by the
    /// pending record's `ctx`. Owned strings; a slot is freed when its
    /// reply lands and reused after.
    evals: std.ArrayListUnmanaged(?[]u8) = .empty,
    /// The path behind each in-flight `setBreakpoints`, indexed by the
    /// pending record's `ctx`, so the reply's `verified` flags land on
    /// the right file. Owned strings, slots reused like `evals`.
    bp_paths: std.ArrayListUnmanaged(?[]u8) = .empty,

    pub const max_output = 2000;

    pub const SpawnError = Transport.SpawnError || Io.ConcurrentError;

    /// Start the adapter. `launch_body` is JSON, already substituted.
    pub fn spawn(gpa: Allocator, io: Io, events: *event.EventQueue, id: u32, argv: []const []const u8, cwd: ?[]const u8, env: ?*const std.process.Environ.Map, launch_body: []const u8) SpawnError!*Session {
        const t = try Transport.spawn(gpa, io, argv, cwd, env);
        errdefer t.shutdown();
        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        const adapter = try gpa.dupe(u8, argv[0]);
        errdefer gpa.free(adapter);
        const body = try gpa.dupe(u8, launch_body);
        errdefer gpa.free(body);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .events = events,
            .id = id,
            .transport = t,
            .adapter = adapter,
            .launch_body = body,
            .is_attach = isAttachBody(gpa, body),
            .snapshot = alloc.SnapshotArena.init(gpa),
            .vars = alloc.SnapshotArena.init(gpa),
        };
        try t.start(.{ .ctx = s, .message = onMessage, .closed = onClosed });
        return s;
    }

    /// A session over files already open (tests: a fake adapter in
    /// process). The transport is shut down by `deinit` like a child's.
    pub fn initFiles(gpa: Allocator, io: Io, events: *event.EventQueue, id: u32, stdin: Io.File, stdout: Io.File, launch_body: []const u8) Allocator.Error!*Session {
        const t = try Transport.initFiles(gpa, io, stdin, stdout);
        errdefer t.shutdown();
        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        const adapter = try gpa.dupe(u8, "fake");
        errdefer gpa.free(adapter);
        const body = try gpa.dupe(u8, launch_body);
        errdefer gpa.free(body);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .events = events,
            .id = id,
            .transport = t,
            .adapter = adapter,
            .launch_body = body,
            .is_attach = isAttachBody(gpa, body),
            .snapshot = alloc.SnapshotArena.init(gpa),
            .vars = alloc.SnapshotArena.init(gpa),
        };
        t.start(.{ .ctx = s, .message = onMessage, .closed = onClosed }) catch return error.OutOfMemory;
        return s;
    }

    /// How long the adapter gets to act on `disconnect` — end or
    /// release its debuggee and exit — before it is killed.
    pub const exit_grace_ms: u32 = 500;

    /// Say goodbye (best effort), stop the reader, kill the adapter,
    /// free everything. A launched program is ended with the session
    /// (`terminateDebuggee: true`); an attached one is released and
    /// keeps running, as VS Code's Stop-as-Disconnect does.
    pub fn deinit(self: *Session) void {
        const gpa = self.gpa;
        if (!self.transport.isDead() and !self.exited) _ = self.request(.disconnect, "disconnect", .{ .terminateDebuggee = !self.is_attach }) catch 0;
        self.transport.shutdownWithin(exit_grace_ms);
        if (self.stopped) |*s| s.deinit(gpa);
        for (self.filters.items) |*f| f.deinit(gpa);
        self.filters.deinit(gpa);
        var ek = self.enabled_filters.keyIterator();
        while (ek.next()) |k| gpa.free(k.*);
        self.enabled_filters.deinit(gpa);
        for (self.output.items) |*o| o.deinit(gpa);
        self.output.deinit(gpa);
        var wi = self.watch_results.iterator();
        while (wi.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(gpa);
        }
        self.watch_results.deinit(gpa);
        for (self.evals.items) |e| if (e) |s| gpa.free(s);
        self.evals.deinit(gpa);
        for (self.bp_paths.items) |e| if (e) |s| gpa.free(s);
        self.bp_paths.deinit(gpa);
        self.variables.deinit(gpa);
        self.expanded.deinit(gpa);
        self.vars.deinit();
        self.snapshot.deinit();
        gpa.free(self.launch_body);
        gpa.free(self.adapter);
        gpa.destroy(self);
    }

    // ─── the sink (reader task) ───

    fn onMessage(ctx: *anyopaque, msg: *jsonrpc.Incoming) void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        const ev = self.gpa.create(event.DapEvent) catch {
            msg.destroy(self.gpa);
            return;
        };
        ev.* = .{ .message = msg };
        self.events.post(self.io, .{ .dap = .{ .session = self.id, .msg = ev } });
    }

    fn onClosed(ctx: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        const ev = self.gpa.create(event.DapEvent) catch return;
        ev.* = .closed;
        self.events.post(self.io, .{ .dap = .{ .session = self.id, .msg = ev } });
    }

    // ─── requests ───

    /// Send `command` with `args` (any Stringify-able value); returns
    /// the request seq. The reply routes back by `kind`.
    pub fn request(self: *Session, kind: ReqKind, command: []const u8, args: anytype) SendError!i64 {
        return self.requestCtx(kind, command, args, 0);
    }

    pub fn requestCtx(self: *Session, kind: ReqKind, command: []const u8, args: anytype, ctx: u64) SendError!i64 {
        const seq = self.transport.allocId();
        const body = try envelope(self.gpa, seq, command, args, null);
        defer self.gpa.free(body);
        try self.transport.expect(seq, .{ .kind = @intFromEnum(kind), .ctx = ctx });
        self.transport.send(body) catch |err| {
            _ = self.transport.forget(seq);
            return err;
        };
        return seq;
    }

    /// The same with `arguments` given as JSON text (the launch body).
    pub fn requestRaw(self: *Session, kind: ReqKind, command: []const u8, args_json: []const u8) SendError!i64 {
        const seq = self.transport.allocId();
        const body = try envelope(self.gpa, seq, command, {}, args_json);
        defer self.gpa.free(body);
        try self.transport.expect(seq, .{ .kind = @intFromEnum(kind) });
        self.transport.send(body) catch |err| {
            _ = self.transport.forget(seq);
            return err;
        };
        return seq;
    }

    /// Answer a reverse request. mnml runs nothing for the adapter.
    pub fn respondFailure(self: *Session, request_seq: i64, command: []const u8, message: []const u8) SendError!void {
        const seq = self.transport.allocId();
        const body = try jsonrpc.stringify(self.gpa, .{ .seq = seq, .type = "response", .request_seq = request_seq, .command = command, .success = false, .message = message });
        defer self.gpa.free(body);
        try self.transport.send(body);
    }

    pub fn initialize(self: *Session) SendError!void {
        _ = try self.request(.initialize, "initialize", .{
            .clientID = "mnml",
            .clientName = "mnml",
            .adapterID = std.fs.path.basename(self.adapter),
            .locale = "en-US",
            .linesStartAt1 = true,
            .columnsStartAt1 = true,
            .pathFormat = "path",
            .supportsRunInTerminalRequest = false,
            .supportsVariableType = true,
            .supportsVariablePaging = false,
        });
    }

    /// `launch` or `attach`, whichever the body's `request` names.
    pub fn launch(self: *Session) SendError!void {
        var parsed = std.json.parseFromSlice(Value, self.gpa, self.launch_body, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        defer if (parsed) |*p| p.deinit();
        const cmd: []const u8 = if (parsed) |p| (jsonrpc.getStr(p.value, "request") orelse "launch") else "launch";
        _ = try self.requestRaw(.launch, cmd, self.launch_body);
    }

    pub fn configurationDone(self: *Session) SendError!void {
        _ = try self.request(.configuration_done, "configurationDone", .{});
        self.configured = true;
    }

    /// The whole list for one file — DAP replaces per source. Disabled
    /// breakpoints are left out; the reply's `verified` flags map onto
    /// the enabled ones in order (`takeBpPath`).
    pub fn setBreakpoints(self: *Session, path: []const u8, bps: []const types.Breakpoint) SendError!void {
        const Bp = struct { line: u32, condition: ?[]const u8 = null, hitCondition: ?[]const u8 = null, logMessage: ?[]const u8 = null };
        var n: usize = 0;
        for (bps) |b| if (b.enabled) {
            n += 1;
        };
        const list = try self.gpa.alloc(Bp, n);
        defer self.gpa.free(list);
        const lines = try self.gpa.alloc(u32, n);
        defer self.gpa.free(lines);
        var i: usize = 0;
        for (bps) |b| if (b.enabled) {
            list[i] = .{ .line = b.line + 1, .condition = b.condition, .hitCondition = b.hit_condition, .logMessage = b.log_message };
            lines[i] = b.line + 1;
            i += 1;
        };
        const slot = try self.rememberBpPath(path);
        errdefer self.forgetBpPath(slot);
        _ = try self.requestCtx(.set_breakpoints, "setBreakpoints", .{
            .source = .{ .path = path, .name = std.fs.path.basename(path) },
            .breakpoints = list,
            .lines = lines,
            .sourceModified = false,
        }, slot);
    }

    fn rememberBpPath(self: *Session, path: []const u8) Allocator.Error!u64 {
        const copy = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(copy);
        for (self.bp_paths.items, 0..) |e, i| if (e == null) {
            self.bp_paths.items[i] = copy;
            return i;
        };
        try self.bp_paths.append(self.gpa, copy);
        return self.bp_paths.items.len - 1;
    }

    /// The path a `setBreakpoints` slot named; the caller frees it.
    pub fn takeBpPath(self: *Session, slot: u64) ?[]u8 {
        if (slot >= self.bp_paths.items.len) return null;
        const e = self.bp_paths.items[slot];
        self.bp_paths.items[slot] = null;
        return e;
    }

    fn forgetBpPath(self: *Session, slot: u64) void {
        if (self.takeBpPath(slot)) |e| self.gpa.free(e);
    }

    pub fn setExceptionBreakpoints(self: *Session) SendError!void {
        const ids = try self.gpa.alloc([]const u8, self.enabled_filters.count());
        defer self.gpa.free(ids);
        var i: usize = 0;
        var it = self.enabled_filters.keyIterator();
        while (it.next()) |k| : (i += 1) ids[i] = k.*;
        _ = try self.request(.set_exception_breakpoints, "setExceptionBreakpoints", .{ .filters = ids });
    }

    pub fn toggleFilter(self: *Session, id: []const u8) Allocator.Error!bool {
        if (self.enabled_filters.fetchRemove(id)) |kv| {
            self.gpa.free(kv.key);
            return false;
        }
        const key = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(key);
        try self.enabled_filters.put(self.gpa, key, {});
        return true;
    }

    /// A thread-addressed step / resume. `command` is the DAP verb.
    pub fn threadRequest(self: *Session, kind: ReqKind, command: []const u8) SendError!void {
        _ = try self.request(kind, command, .{ .threadId = self.thread orelse 1 });
    }

    pub fn requestThreads(self: *Session) SendError!void {
        _ = try self.request(.threads, "threads", .{});
    }

    pub fn requestStackTrace(self: *Session, thread_id: i64) SendError!void {
        _ = try self.request(.stack_trace, "stackTrace", .{ .threadId = thread_id, .startFrame = 0, .levels = 64 });
    }

    pub fn requestScopes(self: *Session, frame_id: i64) SendError!void {
        _ = try self.request(.scopes, "scopes", .{ .frameId = frame_id });
    }

    /// Children of `ref`; the reply lands in `variables[ref]`.
    pub fn requestVariables(self: *Session, ref: i64) SendError!void {
        _ = try self.requestCtx(.variables, "variables", .{ .variablesReference = ref }, @bitCast(ref));
    }

    /// The text of a frame whose source is the adapter's (`source_ref`
    /// above 0); the reply carries the reference back as its context.
    pub fn requestSource(self: *Session, ref: i64) SendError!void {
        _ = try self.requestCtx(.source, "source", .{ .source = .{ .sourceReference = ref }, .sourceReference = ref }, @bitCast(ref));
    }

    pub const EvalContext = enum { repl, watch, hover };

    /// The frame evaluations and scopes address: the selected one, else
    /// the top of the stack.
    pub fn currentFrame(self: *const Session) ?i64 {
        if (self.frame_id) |f| return f;
        return if (self.frames.len > 0) self.frames[0].id else null;
    }

    /// `evaluate` against the current frame (or globally). The
    /// expression is remembered so the reply can name it.
    pub fn evaluate(self: *Session, expr: []const u8, context: EvalContext) SendError!i64 {
        const slot = try self.rememberEval(expr);
        errdefer self.forgetEval(slot);
        const frame_id: ?i64 = self.currentFrame();
        const kind: ReqKind = switch (context) {
            .repl => .evaluate_repl,
            .watch => .evaluate_watch,
            .hover => .evaluate_hover,
        };
        return self.requestCtx(kind, "evaluate", .{ .expression = expr, .context = @tagName(context), .frameId = frame_id }, slot);
    }

    fn rememberEval(self: *Session, expr: []const u8) Allocator.Error!u64 {
        const copy = try self.gpa.dupe(u8, expr);
        errdefer self.gpa.free(copy);
        for (self.evals.items, 0..) |e, i| if (e == null) {
            self.evals.items[i] = copy;
            return i;
        };
        try self.evals.append(self.gpa, copy);
        return self.evals.items.len - 1;
    }

    /// The expression a slot held; the caller frees it.
    pub fn takeEval(self: *Session, slot: u64) ?[]u8 {
        if (slot >= self.evals.items.len) return null;
        const e = self.evals.items[slot];
        self.evals.items[slot] = null;
        return e;
    }

    fn forgetEval(self: *Session, slot: u64) void {
        if (self.takeEval(slot)) |e| self.gpa.free(e);
    }

    pub fn setVariable(self: *Session, parent_ref: i64, name: []const u8, value: []const u8) SendError!void {
        _ = try self.request(.set_variable, "setVariable", .{ .variablesReference = parent_ref, .name = name, .value = value });
    }

    /// `terminate` ends a LAUNCHED program. For an attached one it is
    /// not sent — the process is not the session's to end; the
    /// `disconnect` in `deinit` releases it instead.
    pub fn terminate(self: *Session) SendError!void {
        if (self.is_attach) return;
        _ = try self.request(.terminate, "terminate", .{});
    }

    // ─── state the handler fills ───

    /// Forget everything a resume invalidates.
    pub fn onResumed(self: *Session) void {
        if (self.stopped) |*s| s.deinit(self.gpa);
        self.stopped = null;
        self.frame_id = null;
        self.running = true;
        self.scopes = &.{};
        self.variables.clearRetainingCapacity();
        self.expanded.clearRetainingCapacity();
        self.vars.reset();
    }

    /// Replace the stack with the reply's frames (snapshot arena).
    pub fn setFrames(self: *Session, body: ?Value) Allocator.Error!void {
        self.snapshot.reset();
        self.frames = &.{};
        self.scopes = &.{};
        self.threads = &.{};
        const arena = self.snapshot.allocator();
        const arr = if (body) |b| jsonrpc.getArr(b, "stackFrames") orelse &.{} else &.{};
        const out = try arena.alloc(types.StackFrame, arr.len);
        for (arr, 0..) |f, i| {
            const src_obj = jsonrpc.getObj(f, "source");
            // A `sourceReference` above 0 says the text is the
            // adapter's to give (`source`), whatever `path` reads.
            const ref = if (src_obj) |s| jsonrpc.getInt(s, "sourceReference") orelse 0 else 0;
            // With a reference the `path` is only a display string
            // (lldb-dap: `/usr/lib/dyld`start`); the name is the
            // shorter of the two and is what the frame is called.
            const src = if (src_obj) |s| (if (ref > 0) (jsonrpc.getStr(s, "name") orelse jsonrpc.getStr(s, "path")) else (jsonrpc.getStr(s, "path") orelse jsonrpc.getStr(s, "name"))) else null;
            out[i] = .{
                .id = jsonrpc.getInt(f, "id") orelse 0,
                .name = try arena.dupe(u8, jsonrpc.getStr(f, "name") orelse "?"),
                .source = if (src) |p| try arena.dupe(u8, p) else null,
                .source_ref = @max(ref, 0),
                .line = @intCast(@max(jsonrpc.getInt(f, "line") orelse 1, 0)),
                .column = @intCast(@max(jsonrpc.getInt(f, "column") orelse 1, 0)),
            };
        }
        self.frames = out;
    }

    pub fn setScopes(self: *Session, body: ?Value) Allocator.Error!void {
        const arena = self.snapshot.allocator();
        const arr = if (body) |b| jsonrpc.getArr(b, "scopes") orelse &.{} else &.{};
        const out = try arena.alloc(types.Scope, arr.len);
        for (arr, 0..) |s, i| out[i] = .{
            .name = try arena.dupe(u8, jsonrpc.getStr(s, "name") orelse "?"),
            .variables_reference = jsonrpc.getInt(s, "variablesReference") orelse 0,
            .expensive = jsonrpc.getBool(s, "expensive") orelse false,
        };
        self.scopes = out;
    }

    pub fn setThreads(self: *Session, body: ?Value) Allocator.Error!void {
        const arena = self.snapshot.allocator();
        const arr = if (body) |b| jsonrpc.getArr(b, "threads") orelse &.{} else &.{};
        const out = try arena.alloc(types.Thread, arr.len);
        for (arr, 0..) |t, i| out[i] = .{ .id = jsonrpc.getInt(t, "id") orelse 0, .name = try arena.dupe(u8, jsonrpc.getStr(t, "name") orelse "?") };
        self.threads = out;
    }

    /// The children of `ref` from a `variables` reply.
    pub fn setVariables(self: *Session, ref: i64, body: ?Value) Allocator.Error!void {
        const arena = self.vars.allocator();
        const arr = if (body) |b| jsonrpc.getArr(b, "variables") orelse &.{} else &.{};
        const out = try arena.alloc(types.Variable, arr.len);
        for (arr, 0..) |v, i| out[i] = .{
            .name = try arena.dupe(u8, jsonrpc.getStr(v, "name") orelse "?"),
            .value = try arena.dupe(u8, jsonrpc.getStr(v, "value") orelse ""),
            .ty = if (jsonrpc.getStr(v, "type")) |t| try arena.dupe(u8, t) else null,
            .variables_reference = jsonrpc.getInt(v, "variablesReference") orelse 0,
        };
        try self.variables.put(self.gpa, ref, out);
    }

    /// The user's word on a filter, kept by the app across sessions:
    /// filter id → on. A filter with no entry takes the adapter's default.
    pub const FilterOverrides = std.StringHashMapUnmanaged(bool);

    /// The filters from `initialize`'s reply; each goes on when the
    /// user last switched it on (`overrides`), else when the adapter
    /// says it is on by default. A restart is a new session, and
    /// "break on throw" was switched on for exactly the next run
    /// (hunt: dap-restart-drops-exception-filters).
    pub fn setCapabilities(self: *Session, body: ?Value, overrides: ?*const FilterOverrides) Allocator.Error!void {
        const b = body orelse return;
        const arr = jsonrpc.getArr(b, "exceptionBreakpointFilters") orelse return;
        for (arr) |f| {
            const id = jsonrpc.getStr(f, "filter") orelse continue;
            var filter: types.ExceptionFilter = .{
                .filter = try self.gpa.dupe(u8, id),
                .label = undefined,
                .default = jsonrpc.getBool(f, "default") orelse false,
            };
            errdefer self.gpa.free(filter.filter);
            filter.label = try self.gpa.dupe(u8, jsonrpc.getStr(f, "label") orelse id);
            errdefer self.gpa.free(filter.label);
            try self.filters.append(self.gpa, filter);
            const on = if (overrides) |o| (o.get(id) orelse filter.default) else filter.default;
            if (on and !self.enabled_filters.contains(id)) {
                const key = try self.gpa.dupe(u8, id);
                errdefer self.gpa.free(key);
                try self.enabled_filters.put(self.gpa, key, {});
            }
        }
    }

    pub fn setStopped(self: *Session, thread_id: i64, reason: []const u8, description: ?[]const u8, text: ?[]const u8) Allocator.Error!void {
        const st = try types.Stopped.init(self.gpa, thread_id, reason, description, text);
        if (self.stopped) |*old| old.deinit(self.gpa);
        self.stopped = st;
        self.thread = thread_id;
        self.frame_id = null;
        self.running = false;
    }

    /// Append every non-empty line of `text` to the log, capped.
    pub fn appendOutput(self: *Session, category: []const u8, text: []const u8) Allocator.Error!void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;
            var entry: types.OutputLine = .{ .category = try self.gpa.dupe(u8, category), .text = undefined };
            errdefer self.gpa.free(entry.category);
            entry.text = try self.gpa.dupe(u8, line);
            errdefer self.gpa.free(entry.text);
            try self.output.append(self.gpa, entry);
        }
        while (self.output.items.len > max_output) {
            var first = self.output.orderedRemove(0);
            first.deinit(self.gpa);
        }
    }

    pub fn setWatchResult(self: *Session, expr: []const u8, value: []const u8, ty: ?[]const u8, err: ?[]const u8) Allocator.Error!void {
        var r: types.WatchResult = .{ .value = try self.gpa.dupe(u8, value), .ty = null, .err = null };
        errdefer r.deinit(self.gpa);
        if (ty) |t| r.ty = try self.gpa.dupe(u8, t);
        if (err) |e| r.err = try self.gpa.dupe(u8, e);
        if (self.watch_results.getPtr(expr)) |old| {
            old.deinit(self.gpa);
            old.* = r;
            return;
        }
        const key = try self.gpa.dupe(u8, expr);
        errdefer self.gpa.free(key);
        try self.watch_results.put(self.gpa, key, r);
    }

    pub fn clearWatchResults(self: *Session) void {
        var it = self.watch_results.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.watch_results.clearRetainingCapacity();
    }

    pub fn removeWatchResult(self: *Session, expr: []const u8) void {
        if (self.watch_results.fetchRemove(expr)) |kv| {
            self.gpa.free(kv.key);
            var v = kv.value;
            v.deinit(self.gpa);
        }
    }

    /// The flattened variables tree: scope headers, then the rows of
    /// every expanded composite under them. Frame-arena.
    pub fn variableRows(self: *const Session, arena: Allocator) Allocator.Error![]types.VarRow {
        var out: std.ArrayListUnmanaged(types.VarRow) = .empty;
        for (self.scopes) |s| {
            const r = s.variables_reference;
            const expandable = r > 0;
            const expanded = expandable and self.expanded.contains(r);
            try out.append(arena, .{ .depth = 0, .is_scope = true, .label = s.name, .name = s.name, .value = if (s.expensive) "(expensive)" else "", .var_ref = r, .expanded = expanded, .expandable = expandable, .parent_ref = 0 });
            if (expanded) if (self.variables.get(r)) |vars| {
                for (vars) |v| try self.walkVar(arena, &out, v, 1, r);
            };
        }
        return out.items;
    }

    fn walkVar(self: *const Session, arena: Allocator, out: *std.ArrayListUnmanaged(types.VarRow), v: types.Variable, depth: u8, parent: i64) Allocator.Error!void {
        const expandable = v.variables_reference > 0;
        const expanded = expandable and self.expanded.contains(v.variables_reference);
        const label = if (v.ty) |t| (if (t.len > 0) try std.fmt.allocPrint(arena, "{s}: {s}", .{ v.name, t }) else v.name) else v.name;
        try out.append(arena, .{ .depth = depth, .is_scope = false, .label = label, .name = v.name, .value = v.value, .var_ref = v.variables_reference, .expanded = expanded, .expandable = expandable, .parent_ref = parent });
        if (expanded) if (self.variables.get(v.variables_reference)) |kids| {
            for (kids) |k| try self.walkVar(arena, out, k, depth + 1, v.variables_reference);
        };
    }
};

/// Whether a launch body names `"request": "attach"`.
fn isAttachBody(gpa: Allocator, body: []const u8) bool {
    var parsed = std.json.parseFromSlice(Value, gpa, body, .{}) catch return false;
    defer parsed.deinit();
    const req = jsonrpc.getStr(parsed.value, "request") orelse return false;
    return std.mem.eql(u8, req, "attach");
}

/// `{"seq":N,"type":"request","command":C,"arguments":A}`; `raw`
/// supplies the arguments as JSON text when set.
fn envelope(gpa: Allocator, seq: i64, command: []const u8, args: anytype, raw: ?[]const u8) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
    envelopeInto(&js, seq, command, args, raw) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn envelopeInto(js: *std.json.Stringify, seq: i64, command: []const u8, args: anytype, raw: ?[]const u8) std.json.Stringify.Error!void {
    try js.beginObject();
    try js.objectField("seq");
    try js.write(seq);
    try js.objectField("type");
    try js.write("request");
    try js.objectField("command");
    try js.write(command);
    try js.objectField("arguments");
    if (raw) |r| {
        try js.beginWriteRaw();
        try js.writer.writeAll(r);
        js.endWriteRaw();
    } else if (@TypeOf(args) == void or isEmptyStruct(@TypeOf(args))) {
        // DAP types `arguments` as an object. `std.json` writes the
        // empty tuple `.{}` — what every argument-less call passes —
        // as the list `[]`, which debugpy (pydevd's schema) rejects:
        // "argument after ** must be a mapping, not list", and the
        // session never starts (hunt: dap-debugpy-configurationdone-
        // arguments-list). lldb-dap tolerated it, which hid this.
        try js.beginObject();
        try js.endObject();
    } else {
        try js.write(args);
    }
    try js.endObject();
}

/// `.{}` — a tuple with no fields; a struct with none is the same to
/// the wire.
fn isEmptyStruct(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => compat.structFields(T).len == 0,
        else => false,
    };
}

/// `${file}`, `${fileBasename}`, `${fileDirname}`, `${workspaceFolder}`
/// and `${cwd}` inside the launch JSON, JSON-escaped. Frame/gpa-owned
/// result.
pub fn substitute(gpa: Allocator, json_text: []const u8, workspace: []const u8, file: ?[]const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < json_text.len) {
        if (json_text[i] == '$' and i + 1 < json_text.len and json_text[i + 1] == '{') {
            if (std.mem.indexOfScalarPos(u8, json_text, i + 2, '}')) |close| {
                const name = json_text[i + 2 .. close];
                const value: ?[]const u8 = if (std.mem.eql(u8, name, "file"))
                    file
                else if (std.mem.eql(u8, name, "fileBasename"))
                    (if (file) |f| std.fs.path.basename(f) else null)
                else if (std.mem.eql(u8, name, "fileDirname"))
                    (if (file) |f| std.fs.path.dirname(f) orelse "." else null)
                else if (std.mem.eql(u8, name, "workspaceFolder") or std.mem.eql(u8, name, "cwd"))
                    workspace
                else
                    null;
                if (value) |v| {
                    try appendEscaped(gpa, &out, v);
                    i = close + 1;
                    continue;
                }
            }
        }
        try out.append(gpa, json_text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn appendEscaped(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) Allocator.Error!void {
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        else => try out.append(gpa, c),
    };
}

/// `$NAME` / `${NAME}` in an adapter's `cmd` or an argument, from
/// `env`; a name that is not set stays as written. What lets a config
/// point at a binary by variable — `$MNML_FAKE_DAP`, which the `.test`
/// runner exports — without an absolute path in the file. Owned result.
pub fn expandEnv(gpa: Allocator, text: []const u8, env: *const std.process.Environ.Map) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '$' and i + 1 < text.len) {
            const braced = text[i + 1] == '{';
            const start = if (braced) i + 2 else i + 1;
            var end = start;
            while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
            const name = text[start..end];
            const closed = !braced or (end < text.len and text[end] == '}');
            if (name.len > 0 and closed) {
                if (env.get(name)) |v| {
                    try out.appendSlice(gpa, v);
                    i = if (braced) end + 1 else end;
                    continue;
                }
            }
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "envelope: seq/type/command/arguments; a raw body is spliced in verbatim; `.{}` is the object `{}`, never the list `[]`" {
    const gpa = testing.allocator;
    const a = try envelope(gpa, 7, "next", .{ .threadId = 3 }, null);
    defer gpa.free(a);
    try testing.expectEqualStrings("{\"seq\":7,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":3}}", a);
    const b = try envelope(gpa, 8, "launch", {}, "{\"program\":\"x\"}");
    defer gpa.free(b);
    try testing.expectEqualStrings("{\"seq\":8,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"x\"}}", b);
    const c = try envelope(gpa, 9, "configurationDone", {}, null);
    defer gpa.free(c);
    try testing.expect(std.mem.endsWith(u8, c, "\"arguments\":{}}"));
    // What the callers pass — `request(.configuration_done, "configurationDone", .{})`,
    // `threads`, `terminate` — is the empty TUPLE, which std.json would
    // write as `[]`. debugpy refuses a list; the wire must say `{}`.
    const d = try envelope(gpa, 10, "configurationDone", .{}, null);
    defer gpa.free(d);
    try testing.expectEqualStrings("{\"seq\":10,\"type\":\"request\",\"command\":\"configurationDone\",\"arguments\":{}}", d);
    const e = try envelope(gpa, 11, "threads", .{}, null);
    defer gpa.free(e);
    try testing.expect(std.mem.endsWith(u8, e, "\"arguments\":{}}"));
    try testing.expect(std.mem.indexOf(u8, e, "[]") == null);
}

test "isAttachBody: only a body whose `request` is attach" {
    try testing.expect(isAttachBody(testing.allocator, "{\"request\":\"attach\",\"listen\":{\"port\":5678}}"));
    try testing.expect(!isAttachBody(testing.allocator, "{\"request\":\"launch\",\"program\":\"x\"}"));
    try testing.expect(!isAttachBody(testing.allocator, "{\"program\":\"x\"}"));
    try testing.expect(!isAttachBody(testing.allocator, "not json"));
}

test "substitute: file / workspace variables, unknown names kept, quotes escaped" {
    const gpa = testing.allocator;
    const out = try substitute(gpa, "{\"program\":\"${file}\",\"cwd\":\"${workspaceFolder}\",\"x\":\"${nope}\",\"b\":\"${fileBasename}\"}", "/ws", "/ws/a\"b.py");
    defer gpa.free(out);
    try testing.expectEqualStrings("{\"program\":\"/ws/a\\\"b.py\",\"cwd\":\"/ws\",\"x\":\"${nope}\",\"b\":\"a\\\"b.py\"}", out);
    const none = try substitute(gpa, "\"${file}\"", "/ws", null);
    defer gpa.free(none);
    try testing.expectEqualStrings("\"${file}\"", none);
}

test "classify: response / event / reverse request" {
    var p = try std.json.parseFromSlice(Value, testing.allocator, "{\"seq\":2,\"type\":\"response\",\"request_seq\":1,\"command\":\"initialize\",\"success\":true,\"body\":{\"exceptionBreakpointFilters\":[]}}", .{});
    defer p.deinit();
    const r = classify(p.value).response;
    try testing.expectEqual(@as(i64, 1), r.request_seq);
    try testing.expect(r.success);
    var e = try std.json.parseFromSlice(Value, testing.allocator, "{\"seq\":3,\"type\":\"event\",\"event\":\"stopped\",\"body\":{\"reason\":\"breakpoint\",\"threadId\":1}}", .{});
    defer e.deinit();
    try testing.expectEqualStrings("stopped", classify(e.value).event.name);
    var q = try std.json.parseFromSlice(Value, testing.allocator, "{\"seq\":4,\"type\":\"request\",\"command\":\"runInTerminal\"}", .{});
    defer q.deinit();
    try testing.expectEqualStrings("runInTerminal", classify(q.value).request.command);
}

test "setFrames: a `sourceReference` frame keeps the reference and is named by `name`, not the display path; a file frame keeps its path" {
    const gpa = testing.allocator;
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var events = try event.EventQueue.init(gpa, 4);
    defer events.deinit(testing.io);
    const fds_a = try Io.Threaded.pipe2(.{});
    const fds_b = try Io.Threaded.pipe2(.{});
    const in_file: Io.File = .{ .handle = fds_a[1], .flags = .{ .nonblocking = false } };
    const out_file: Io.File = .{ .handle = fds_b[0], .flags = .{ .nonblocking = false } };
    const s = try Session.initFiles(gpa, testing.io, &events, 1, in_file, out_file, "{}");
    defer {
        s.exited = true;
        s.deinit();
        (Io.File{ .handle = fds_a[0], .flags = .{ .nonblocking = false } }).close(testing.io);
        (Io.File{ .handle = fds_b[1], .flags = .{ .nonblocking = false } }).close(testing.io);
    }
    var parsed = try std.json.parseFromSlice(Value, gpa, "{\"stackFrames\":[{\"id\":524289,\"name\":\"start\",\"line\":1749,\"column\":1,\"presentationHint\":\"deemphasize\",\"source\":{\"name\":\"start\",\"path\":\"/usr/lib/dyld`start\",\"sourceReference\":1}},{\"id\":2,\"name\":\"main\",\"line\":22,\"column\":5,\"source\":{\"name\":\"main.c\",\"path\":\"/ws/main.c\"}},{\"id\":3,\"name\":\"nowhere\",\"line\":0,\"column\":0}]}", .{});
    defer parsed.deinit();
    try s.setFrames(parsed.value);
    try testing.expectEqual(@as(usize, 3), s.frames.len);
    try testing.expectEqual(@as(i64, 1), s.frames[0].source_ref);
    try testing.expectEqualStrings("start", s.frames[0].source.?);
    try testing.expectEqual(@as(i64, 0), s.frames[1].source_ref);
    try testing.expectEqualStrings("/ws/main.c", s.frames[1].source.?);
    try testing.expect(s.frames[2].source == null);
    try testing.expectEqual(@as(i64, 0), s.frames[2].source_ref);
}

test "variableRows flattens scopes and only the expanded composites" {
    const gpa = testing.allocator;
    var events = try event.EventQueue.init(gpa, 4);
    defer events.deinit(testing.io);
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds_a = try Io.Threaded.pipe2(.{});
    const fds_b = try Io.Threaded.pipe2(.{});
    const in_file: Io.File = .{ .handle = fds_a[1], .flags = .{ .nonblocking = false } };
    const out_file: Io.File = .{ .handle = fds_b[0], .flags = .{ .nonblocking = false } };
    const s = try Session.initFiles(gpa, testing.io, &events, 1, in_file, out_file, "{}");
    defer {
        s.exited = true;
        s.deinit();
        (Io.File{ .handle = fds_a[0], .flags = .{ .nonblocking = false } }).close(testing.io);
        (Io.File{ .handle = fds_b[1], .flags = .{ .nonblocking = false } }).close(testing.io);
    }
    var scopes = try std.json.parseFromSlice(Value, gpa, "{\"scopes\":[{\"name\":\"Locals\",\"variablesReference\":10,\"expensive\":false},{\"name\":\"Globals\",\"variablesReference\":11,\"expensive\":true}]}", .{});
    defer scopes.deinit();
    try s.setScopes(scopes.value);
    var vars = try std.json.parseFromSlice(Value, gpa, "{\"variables\":[{\"name\":\"self\",\"value\":\"Foo {..}\",\"type\":\"Foo\",\"variablesReference\":20},{\"name\":\"n\",\"value\":\"3\",\"type\":\"i32\",\"variablesReference\":0}]}", .{});
    defer vars.deinit();
    try s.setVariables(10, vars.value);
    var kids = try std.json.parseFromSlice(Value, gpa, "{\"variables\":[{\"name\":\"x\",\"value\":\"1\",\"variablesReference\":0}]}", .{});
    defer kids.deinit();
    try s.setVariables(20, kids.value);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // Nothing expanded: the two scope headers only.
    try testing.expectEqual(@as(usize, 2), (try s.variableRows(arena.allocator())).len);
    try s.expanded.put(gpa, 10, {});
    const rows = try s.variableRows(arena.allocator());
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expectEqualStrings("self: Foo", rows[1].label);
    try testing.expectEqual(@as(i64, 10), rows[1].parent_ref);
    try testing.expect(rows[1].expandable and !rows[1].expanded);
    try testing.expectEqualStrings("(expensive)", rows[3].value);
    try s.expanded.put(gpa, 20, {});
    const deeper = try s.variableRows(arena.allocator());
    try testing.expectEqual(@as(usize, 5), deeper.len);
    try testing.expectEqual(@as(u8, 2), deeper[2].depth);
    try testing.expectEqualStrings("x", deeper[2].name);
    // A resume drops the cache and the expansion state.
    s.onResumed();
    try testing.expectEqual(@as(usize, 0), (try s.variableRows(arena.allocator())).len);
}

test "setCapabilities: a filter goes on by the user's override first, the adapter's default second" {
    const gpa = testing.allocator;
    var events = try event.EventQueue.init(gpa, 4);
    defer events.deinit(testing.io);
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds_a = try Io.Threaded.pipe2(.{});
    const fds_b = try Io.Threaded.pipe2(.{});
    const in_file: Io.File = .{ .handle = fds_a[1], .flags = .{ .nonblocking = false } };
    const out_file: Io.File = .{ .handle = fds_b[0], .flags = .{ .nonblocking = false } };
    const s = try Session.initFiles(gpa, testing.io, &events, 1, in_file, out_file, "{}");
    defer {
        s.exited = true;
        s.deinit();
        (Io.File{ .handle = fds_a[0], .flags = .{ .nonblocking = false } }).close(testing.io);
        (Io.File{ .handle = fds_b[1], .flags = .{ .nonblocking = false } }).close(testing.io);
    }
    var caps = try std.json.parseFromSlice(Value, gpa, "{\"exceptionBreakpointFilters\":[{\"filter\":\"cpp_throw\",\"label\":\"C++ Throw\"},{\"filter\":\"uncaught\",\"label\":\"Uncaught\",\"default\":true},{\"filter\":\"all\",\"label\":\"All\"}]}", .{});
    defer caps.deinit();
    var overrides: Session.FilterOverrides = .empty;
    defer overrides.deinit(gpa);
    // The user switched cpp_throw ON and the default-on uncaught OFF last session.
    try overrides.put(gpa, "cpp_throw", true);
    try overrides.put(gpa, "uncaught", false);
    try s.setCapabilities(caps.value, &overrides);
    try testing.expectEqual(@as(usize, 3), s.filters.items.len);
    try testing.expect(s.enabled_filters.contains("cpp_throw"));
    try testing.expect(!s.enabled_filters.contains("uncaught"));
    try testing.expect(!s.enabled_filters.contains("all"));
    try testing.expectEqual(@as(usize, 1), s.enabled_filters.count());
}

test "expandEnv: $NAME and ${NAME} from the map; unknown names and bare dollars stay" {
    const gpa = testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("MNML_FAKE_DAP", "/zig-out/bin/mnml-fake-dap");
    try env.put("N", "1");
    const a = try expandEnv(gpa, "$MNML_FAKE_DAP", &env);
    defer gpa.free(a);
    try testing.expectEqualStrings("/zig-out/bin/mnml-fake-dap", a);
    const b = try expandEnv(gpa, "x${N}y$N/$NOPE ${UNCLOSED $ $$", &env);
    defer gpa.free(b);
    try testing.expectEqualStrings("x1y1/$NOPE ${UNCLOSED $ $$", b);
    const c = try expandEnv(gpa, "plain", &env);
    defer gpa.free(c);
    try testing.expectEqualStrings("plain", c);
}
