//! mnml-fake-dap — a deterministic Debug Adapter over stdio for testing
//! mnml's debug UI on every platform with no toolchain installed.
//!
//! It speaks DAP (`Content-Length` framing, JSON) and "runs" the
//! launched file as a tiny line-oriented program (`program.zig`, and
//! `README.md` beside it). Every response and event is a function of
//! the program text and the requests received: no clocks, no
//! environment, no randomness.
//!
//! `main` is the stdio loop; `Server` is the protocol, driven the same
//! way by the tests through an in-memory writer.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const program = @import("program.zig");
pub const Program = program.Program;

pub const version = "0.1.0";

pub const Value = std.json.Value;

/// The exception-breakpoint filters `initialize` advertises.
const filters = .{
    .{ .filter = "error", .label = "All errors", .default = false, .description = "Stop on every throw, caught or not" },
    .{ .filter = "uncaught", .label = "Uncaught errors", .default = true, .description = "Stop on a throw that reaches the top level" },
};

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    /// Where frames go: the process's stdout, or a test's buffer.
    out: *Io.Writer,
    seq: i64 = 0,
    prog: ?Program = null,
    /// The launched (or breakpoint-bearing) file, absolute. Owned.
    program_path: ?[]u8 = null,
    /// Breakpoints received before `launch` are applied to the program
    /// once it loads. Owned copies.
    pending_bps: std.ArrayList(program.Breakpoint) = .empty,
    /// Owned copies of the enabled filter ids.
    enabled_filters: std.ArrayList([]u8) = .empty,
    launched: bool = false,
    /// The session came in through `attach`: the program stands in
    /// for somebody else's process, and `<program>.debuggee` beside
    /// it records what the goodbye did to it (`attached` → `killed` /
    /// `detached`), since a fake has no real process a test could
    /// probe with `kill -0`.
    attached: bool = false,
    /// `terminated` has been sent; the program is over.
    terminated: bool = false,
    /// `disconnect` landed: the loop ends.
    done: bool = false,

    pub fn init(gpa: Allocator, io: Io, out: *Io.Writer) Server {
        return .{ .gpa = gpa, .io = io, .out = out };
    }

    pub fn deinit(self: *Server) void {
        if (self.prog) |*p| p.deinit();
        if (self.program_path) |p| self.gpa.free(p);
        self.clearPendingBps();
        self.pending_bps.deinit(self.gpa);
        for (self.enabled_filters.items) |f| self.gpa.free(f);
        self.enabled_filters.deinit(self.gpa);
        self.* = undefined;
    }

    fn clearPendingBps(self: *Server) void {
        for (self.pending_bps.items) |b| {
            if (b.condition) |c| self.gpa.free(c);
            if (b.hit_condition) |h| self.gpa.free(h);
        }
        self.pending_bps.clearRetainingCapacity();
    }

    // ─── the wire ───

    fn nextSeq(self: *Server) i64 {
        self.seq += 1;
        return self.seq;
    }

    fn emit(self: *Server, json: []const u8) Io.Writer.Error!void {
        try self.out.print("Content-Length: {d}\r\n\r\n", .{json.len});
        try self.out.writeAll(json);
        try self.out.flush();
    }

    /// `{"seq":N,"type":"response","request_seq":R,"success":true,"command":C,"body":B}`
    fn respond(self: *Server, request_seq: i64, command: []const u8, body: anytype) !void {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
        try js.beginObject();
        try js.objectField("seq");
        try js.write(self.nextSeq());
        try js.objectField("type");
        try js.write("response");
        try js.objectField("request_seq");
        try js.write(request_seq);
        try js.objectField("success");
        try js.write(true);
        try js.objectField("command");
        try js.write(command);
        try js.objectField("body");
        try js.write(body);
        try js.endObject();
        try self.emit(aw.written());
    }

    fn fail(self: *Server, request_seq: i64, command: []const u8, message: []const u8) !void {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        var js: std.json.Stringify = .{ .writer = &aw.writer };
        try js.beginObject();
        try js.objectField("seq");
        try js.write(self.nextSeq());
        try js.objectField("type");
        try js.write("response");
        try js.objectField("request_seq");
        try js.write(request_seq);
        try js.objectField("success");
        try js.write(false);
        try js.objectField("command");
        try js.write(command);
        try js.objectField("message");
        try js.write(message);
        try js.endObject();
        try self.emit(aw.written());
    }

    fn event(self: *Server, name: []const u8, body: anytype) !void {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
        try js.beginObject();
        try js.objectField("seq");
        try js.write(self.nextSeq());
        try js.objectField("type");
        try js.write("event");
        try js.objectField("event");
        try js.write(name);
        try js.objectField("body");
        try js.write(body);
        try js.endObject();
        try self.emit(aw.written());
    }

    // ─── requests ───

    /// One frame's body: parse, dispatch, answer. A frame that is not a
    /// request is ignored; an unknown command gets `success:false`.
    pub fn handle(self: *Server, body: []const u8) !void {
        var parsed = std.json.parseFromSlice(Value, self.gpa, body, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return, // not JSON: nothing to answer
        };
        defer parsed.deinit();
        const v = parsed.value;
        const kind = getStr(v, "type") orelse return;
        if (!std.mem.eql(u8, kind, "request")) return;
        const command = getStr(v, "command") orelse return;
        const rseq = getInt(v, "seq") orelse 0;
        const args = getField(v, "arguments") orelse Value.null;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        // DAP types `arguments` as an object (or absent). debugpy's
        // schema refuses anything else — `[]` for an argument-less
        // request once cost every Python session its start — so this
        // adapter is as strict, and the corpus catches the shape.
        switch (args) {
            .object, .null => {},
            else => return self.fail(rseq, command, try std.fmt.allocPrint(arena, "{s}: `arguments` must be an object, not {s}", .{ command, @tagName(args) })),
        }
        try self.dispatch(arena, rseq, command, args);
    }

    fn dispatch(self: *Server, arena: Allocator, rseq: i64, command: []const u8, args: Value) !void {
        const eql = std.mem.eql;
        if (eql(u8, command, "initialize")) {
            try self.respond(rseq, command, .{
                .supportsConfigurationDoneRequest = true,
                .supportsConditionalBreakpoints = true,
                .supportsHitConditionalBreakpoints = true,
                .supportsSetVariable = true,
                .supportsEvaluateForHovers = true,
                .supportsTerminateRequest = true,
                .supportsStepBack = false,
                .supportsRestartRequest = false,
                .exceptionBreakpointFilters = filters,
            });
            // debugpy's habit: an `output` event about the adapter itself
            // (`category: telemetry`, `output: <package>`, a version in
            // `data`) right after the reply. Not program output; a
            // console that paints it shows a stray word every session.
            try self.event("output", .{ .category = "telemetry", .output = "fake-dap-telemetry", .data = .{ .packageVersion = version } });
        } else if (eql(u8, command, "launch")) {
            const path = getStr(args, "program") orelse return self.fail(rseq, command, "launch needs `program`");
            self.ensureProgram(path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.fail(rseq, command, try std.fmt.allocPrint(arena, "cannot read {s}: {s}", .{ path, @errorName(err) })),
            };
            self.launched = true;
            try self.respond(rseq, command, .{});
            // `initialized` only now — lldb-dap's and debugpy's order
            // (the protocol's sequence diagram): the client sends
            // `launch` after the `initialize` reply and its breakpoints
            // and `configurationDone` after this event. A client that
            // waits for this event before `launch` deadlocks here, as
            // it does against those adapters.
            try self.event("initialized", .{});
        } else if (eql(u8, command, "attach")) {
            // The same program, "already running": it starts on
            // `configurationDone` like a launch. What differs is the
            // goodbye, written to the ledger.
            const path = getStr(args, "program") orelse return self.fail(rseq, command, "attach needs `program` (the file that stands in for the process)");
            self.ensureProgram(path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.fail(rseq, command, try std.fmt.allocPrint(arena, "cannot read {s}: {s}", .{ path, @errorName(err) })),
            };
            self.launched = true;
            self.attached = true;
            try self.ledger(arena, "attached");
            try self.respond(rseq, command, .{});
            try self.event("initialized", .{});
        } else if (eql(u8, command, "setBreakpoints")) {
            try self.setBreakpoints(arena, rseq, command, args);
        } else if (eql(u8, command, "setExceptionBreakpoints")) {
            for (self.enabled_filters.items) |f| self.gpa.free(f);
            self.enabled_filters.clearRetainingCapacity();
            const list = getArr(args, "filters") orelse &.{};
            for (list) |f| if (asStr(f)) |s| try self.enabled_filters.append(self.gpa, try self.gpa.dupe(u8, s));
            if (self.prog) |*p| p.setExceptionFilters(self.enabled_filters.items);
            try self.respond(rseq, command, .{});
        } else if (eql(u8, command, "configurationDone")) {
            try self.respond(rseq, command, .{});
            if (self.launched and !self.terminated) {
                const p = &self.prog.?;
                if (p.state == .not_started) try self.runAndReport(.@"continue");
            }
        } else if (eql(u8, command, "threads")) {
            try self.respond(rseq, command, .{ .threads = .{.{ .id = 1, .name = "main" }} });
        } else if (eql(u8, command, "stackTrace")) {
            const p = self.stoppedProgram() orelse return self.fail(rseq, command, "not stopped");
            const n = p.frames.items.len;
            const frames = try arena.alloc(FrameJson, n);
            const name = std.fs.path.basename(self.program_path.?);
            for (0..n) |i| {
                const f = p.frames.items[n - 1 - i];
                frames[i] = .{ .id = @intCast(n - i), .name = f.name, .line = @intCast(f.pc + 1), .column = 1, .source = .{ .name = name, .path = self.program_path.? } };
            }
            try self.respond(rseq, command, .{ .stackFrames = frames, .totalFrames = n });
        } else if (eql(u8, command, "scopes")) {
            const p = self.stoppedProgram() orelse return self.fail(rseq, command, "not stopped");
            const frame = frameIndex(p, getInt(args, "frameId")) orelse return self.fail(rseq, command, "no such frameId");
            try self.respond(rseq, command, .{ .scopes = .{
                .{ .name = "Locals", .presentationHint = "locals", .variablesReference = Program.localsRef(frame), .expensive = false },
                .{ .name = "Globals", .variablesReference = Program.globalsRef(frame), .expensive = false },
            } });
        } else if (eql(u8, command, "variables")) {
            const p = self.stoppedProgram() orelse return self.fail(rseq, command, "not stopped");
            const ref = getInt(args, "variablesReference") orelse 0;
            if (p.scopeVars(ref)) |vars| {
                const frame: usize = @intCast(@divFloor(ref - Program.scope_base, 2));
                const out = try arena.alloc(VariableJson, vars.items.len);
                for (vars.items, 0..) |v, i| {
                    out[i] = .{
                        .name = v.name,
                        .value = try v.value.render(arena),
                        .type = v.value.typeName(),
                        .variablesReference = if (v.value == .strct) try p.structRef(frame, v.name) else 0,
                    };
                }
                try self.respond(rseq, command, .{ .variables = out });
            } else if (p.structOf(ref)) |sr| {
                const holder = p.lookup(sr.frame, sr.name) orelse return self.fail(rseq, command, "variable is gone");
                const fields = switch (holder) {
                    .strct => |f| f,
                    else => return self.fail(rseq, command, "not a struct"),
                };
                const out = try arena.alloc(VariableJson, fields.len);
                for (fields, 0..) |f, i| {
                    const fv: program.Value = switch (f.value) {
                        .int => |x| .{ .int = x },
                        .str => |s| .{ .str = s },
                    };
                    out[i] = .{ .name = f.name, .value = try fv.render(arena), .type = fv.typeName(), .variablesReference = 0 };
                }
                try self.respond(rseq, command, .{ .variables = out });
            } else try self.fail(rseq, command, "no such variablesReference");
        } else if (eql(u8, command, "evaluate")) {
            const p = self.stoppedProgram() orelse return self.fail(rseq, command, "not stopped");
            const expr = getStr(args, "expression") orelse "";
            const frame = frameIndex(p, getInt(args, "frameId")) orelse p.frames.items.len - 1;
            const v = p.evaluate(expr, frame) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.fail(rseq, command, program.errName(err)),
            };
            const trimmed = std.mem.trim(u8, expr, " \t");
            const ref: i64 = if (v == .strct and p.lookup(frame, trimmed) != null) try p.structRef(frame, trimmed) else 0;
            try self.respond(rseq, command, .{ .result = try v.render(arena), .type = v.typeName(), .variablesReference = ref });
        } else if (eql(u8, command, "setVariable")) {
            const p = self.stoppedProgram() orelse return self.fail(rseq, command, "not stopped");
            const ref = getInt(args, "variablesReference") orelse 0;
            const name = getStr(args, "name") orelse "";
            const text = getStr(args, "value") orelse "";
            const v = p.setVar(ref, name, text) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.fail(rseq, command, program.errName(err)),
            };
            try self.respond(rseq, command, .{ .value = try v.render(arena), .type = v.typeName(), .variablesReference = 0 });
        } else if (eql(u8, command, "continue")) {
            _ = self.stoppedProgram() orelse return self.fail(rseq, command, "not stopped");
            try self.respond(rseq, command, .{ .allThreadsContinued = true });
            try self.resume_(.@"continue");
        } else if (eql(u8, command, "next")) {
            _ = self.stoppedProgram() orelse return self.fail(rseq, command, "not stopped");
            try self.respond(rseq, command, .{});
            try self.resume_(.next);
        } else if (eql(u8, command, "stepIn")) {
            _ = self.stoppedProgram() orelse return self.fail(rseq, command, "not stopped");
            try self.respond(rseq, command, .{});
            try self.resume_(.step_in);
        } else if (eql(u8, command, "stepOut")) {
            _ = self.stoppedProgram() orelse return self.fail(rseq, command, "not stopped");
            try self.respond(rseq, command, .{});
            try self.resume_(.step_out);
        } else if (eql(u8, command, "pause")) {
            const p: *Program = if (self.prog) |*p| p else return self.fail(rseq, command, "not running");
            const outcome = p.pause() orelse return self.fail(rseq, command, "not running");
            try self.respond(rseq, command, .{});
            try self.report(outcome);
        } else if (eql(u8, command, "terminate")) {
            // Ends the debuggee whatever the session — the client
            // must not send it for an attached one.
            if (self.attached) try self.ledger(arena, "killed");
            try self.respond(rseq, command, .{});
            try self.endProgram(null);
        } else if (eql(u8, command, "disconnect")) {
            // `terminateDebuggee` decides an attached process's fate;
            // absent, DAP leaves it to the adapter, and this one keeps
            // the process it did not start.
            if (self.attached and !self.terminated) {
                const kill = if (getField(args, "terminateDebuggee")) |v| (v == .bool and v.bool) else false;
                try self.ledger(arena, if (kill) "killed" else "detached");
            }
            try self.respond(rseq, command, .{});
            if (!self.terminated) try self.endProgram(null);
            self.done = true;
        } else {
            try self.fail(rseq, command, try std.fmt.allocPrint(arena, "unsupported request: {s}", .{command}));
        }
    }

    const FrameJson = struct { id: i64, name: []const u8, line: i64, column: i64, source: struct { name: []const u8, path: []const u8 } };
    const VariableJson = struct { name: []const u8, value: []const u8, type: []const u8, variablesReference: i64 };
    const BreakpointJson = struct { id: i64, verified: bool, line: i64, message: ?[]const u8 = null };

    fn setBreakpoints(self: *Server, arena: Allocator, rseq: i64, command: []const u8, args: Value) !void {
        const path = if (getObj(args, "source")) |s| getStr(s, "path") else null;
        const list = getArr(args, "breakpoints") orelse &.{};
        // The list replaces this source's breakpoints. The file is
        // loaded now if it is the first we hear of, so `verified` is
        // answered from the real statements.
        if (path) |p| {
            self.ensureProgram(p) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        }
        const same_file = path != null and self.program_path != null and std.mem.eql(u8, path.?, self.program_path.?);
        self.clearPendingBps();
        for (list) |b| {
            const line: u32 = @intCast(@max(getInt(b, "line") orelse 0, 0));
            try self.pending_bps.append(self.gpa, .{
                .line = line,
                .condition = if (getStr(b, "condition")) |c| try self.gpa.dupe(u8, c) else null,
                .hit_condition = if (getStr(b, "hitCondition")) |h| try self.gpa.dupe(u8, h) else null,
            });
        }
        const out = try arena.alloc(BreakpointJson, list.len);
        if (same_file and self.prog != null) {
            const applied = try self.prog.?.setBreakpoints(self.pending_bps.items);
            for (applied, 0..) |b, i| out[i] = .{ .id = @intCast(i + 1), .verified = b.verified, .line = b.line, .message = if (b.verified) null else "not a statement line" };
        } else {
            for (self.pending_bps.items, 0..) |b, i| out[i] = .{ .id = @intCast(i + 1), .verified = false, .line = b.line, .message = "breakpoints are only kept for the launched program" };
        }
        try self.respond(rseq, command, .{ .breakpoints = out });
    }

    /// Load `path` as the program unless it already is. Breakpoints and
    /// filters received so far apply to the fresh program.
    fn ensureProgram(self: *Server, path: []const u8) !void {
        if (self.program_path) |cur| if (std.mem.eql(u8, cur, path) and self.prog != null) return;
        const src = try Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(4 * 1024 * 1024));
        defer self.gpa.free(src);
        var p = Program.init(self.gpa);
        errdefer p.deinit();
        try p.load(src);
        p.setExceptionFilters(self.enabled_filters.items);
        _ = try p.setBreakpoints(self.pending_bps.items);
        const owned = try self.gpa.dupe(u8, path);
        if (self.prog) |*old| old.deinit();
        if (self.program_path) |old| self.gpa.free(old);
        self.prog = p;
        self.program_path = owned;
    }

    /// `<program>.debuggee` ← `word`, the attached process's ledger.
    fn ledger(self: *Server, arena: Allocator, word: []const u8) !void {
        const path = self.program_path orelse return;
        const ledger_path = try std.fmt.allocPrint(arena, "{s}.debuggee", .{path});
        const text = try std.fmt.allocPrint(arena, "{s}\n", .{word});
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = ledger_path, .data = text }) catch {};
    }

    fn stoppedProgram(self: *Server) ?*Program {
        const p: *Program = if (self.prog) |*p| p else return null;
        return if (p.state == .stopped) p else null;
    }

    fn frameIndex(p: *const Program, frame_id: ?i64) ?usize {
        const id = frame_id orelse return p.frames.items.len - 1;
        if (id < 1 or id > p.frames.items.len) return null;
        return @intCast(id - 1);
    }

    fn resume_(self: *Server, mode: program.Mode) !void {
        try self.event("continued", .{ .threadId = 1, .allThreadsContinued = true });
        try self.runAndReport(mode);
    }

    fn runAndReport(self: *Server, mode: program.Mode) !void {
        const outcome = try self.prog.?.run(mode);
        try self.report(outcome);
    }

    /// Output first, then what happened.
    fn report(self: *Server, outcome: program.Outcome) !void {
        const p = &self.prog.?;
        for (p.takeOutput()) |o| try self.event("output", .{ .category = o.category, .output = o.text });
        switch (outcome) {
            .stopped => |reason| try self.event("stopped", .{
                .reason = @tagName(reason),
                .threadId = 1,
                .allThreadsStopped = true,
                .text = if (reason == .exception) p.last_throw else null,
            }),
            .sleeping => {},
            .exited => |code| try self.endProgram(code),
        }
    }

    /// `exited` (when the program ran to an exit code) then `terminated`, once.
    fn endProgram(self: *Server, code: ?i64) !void {
        if (self.terminated) return;
        self.terminated = true;
        if (self.prog) |*p| p.state = .exited;
        if (code) |c| try self.event("exited", .{ .exitCode = c });
        try self.event("terminated", .{});
    }
};

// ─── JSON helpers ───

fn getField(v: Value, key: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn getStr(v: Value, key: []const u8) ?[]const u8 {
    return asStr(getField(v, key) orelse return null);
}

fn asStr(v: Value) ?[]const u8 {
    return switch (v) {
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

fn getArr(v: Value, key: []const u8) ?[]const Value {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .array => |a| a.items,
        else => null,
    };
}

fn getObj(v: Value, key: []const u8) ?Value {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .object => f,
        else => null,
    };
}

// ─── framing ───

pub const FrameError = error{ Closed, BadFrame } || Allocator.Error;

/// `Content-Length: N\r\n\r\n` then N bytes; other headers are skipped.
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
    if (n > 64 * 1024 * 1024) return error.BadFrame;
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
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--version")) {
            var buf: [128]u8 = undefined;
            var w: Io.File.Writer = .initStreaming(.stdout(), io, &buf);
            try w.interface.print("mnml-fake-dap {s}\n", .{version});
            try w.interface.flush();
            return 0;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            var buf: [512]u8 = undefined;
            var w: Io.File.Writer = .initStreaming(.stdout(), io, &buf);
            try w.interface.writeAll("mnml-fake-dap: a deterministic Debug Adapter over stdio (see tools/fake_dap/README.md)\n");
            try w.interface.flush();
            return 0;
        }
    }
    var in_buf: [64 * 1024]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &in_buf);
    var writer = Io.File.stdout().writerStreaming(io, &out_buf);
    var server = Server.init(gpa, io, &writer.interface);
    defer server.deinit();
    while (!server.done) {
        const body = readFrame(gpa, &reader.interface) catch |err| switch (err) {
            error.Closed, error.BadFrame => break,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer gpa.free(body);
        server.handle(body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => break, // the pipe is gone
        };
    }
    return 0;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test {
    _ = program;
}

/// A server on a growable buffer, plus the frames it produced so far.
const Harness = struct {
    aw: Io.Writer.Allocating,
    server: Server,
    parsed: std.ArrayList(std.json.Parsed(Value)) = .empty,
    /// How many bytes of `aw` have been split into frames.
    consumed: usize = 0,
    next_seq: i64 = 1,

    fn init(h: *Harness) void {
        h.* = .{ .aw = .init(t.allocator), .server = undefined };
        h.server = Server.init(t.allocator, t.io, &h.aw.writer);
    }

    fn deinit(h: *Harness) void {
        for (h.parsed.items) |*p| p.deinit();
        h.parsed.deinit(t.allocator);
        h.server.deinit();
        h.aw.deinit();
    }

    /// Send one request; returns the frames it produced, in order.
    fn send(h: *Harness, command: []const u8, args_json: []const u8) ![]const Value {
        const body = try std.fmt.allocPrint(t.allocator, "{{\"seq\":{d},\"type\":\"request\",\"command\":\"{s}\",\"arguments\":{s}}}", .{ h.next_seq, command, args_json });
        defer t.allocator.free(body);
        h.next_seq += 1;
        const before = h.parsed.items.len;
        try h.server.handle(body);
        try h.drain();
        const out = try t.allocator.alloc(Value, h.parsed.items.len - before);
        for (h.parsed.items[before..], 0..) |p, i| out[i] = p.value;
        return out;
    }

    fn drain(h: *Harness) !void {
        const all = h.aw.written();
        while (h.consumed < all.len) {
            const rest = all[h.consumed..];
            const hdr_end = std.mem.indexOf(u8, rest, "\r\n\r\n") orelse return error.BadFrame;
            const hdr = rest[0..hdr_end];
            const colon = std.mem.indexOfScalar(u8, hdr, ':') orelse return error.BadFrame;
            const n = try std.fmt.parseInt(usize, std.mem.trim(u8, hdr[colon + 1 ..], " "), 10);
            const body = rest[hdr_end + 4 .. hdr_end + 4 + n];
            try h.parsed.append(t.allocator, try std.json.parseFromSlice(Value, t.allocator, body, .{}));
            h.consumed += hdr_end + 4 + n;
        }
    }
};

fn expectResponse(v: Value, command: []const u8, success: bool) !void {
    try t.expectEqualStrings("response", getStr(v, "type").?);
    try t.expectEqualStrings(command, getStr(v, "command").?);
    try t.expectEqual(success, v.object.get("success").?.bool);
}

fn expectEvent(v: Value, name: []const u8) !Value {
    try t.expectEqualStrings("event", getStr(v, "type").?);
    try t.expectEqualStrings(name, getStr(v, "event").?);
    return getField(v, "body") orelse Value.null;
}

/// The program every server test launches, written into a temp dir.
const sample =
    \\let x = 1
    \\let p = struct{a=1,b="two"}
    \\print "hello"
    \\x = x + 1
    \\fn f
    \\  let y = 10
    \\  x = x * y
    \\end
    \\call f
    \\print x
    \\throw "boom"
    \\print "unreachable"
    \\
;

const TmpProgram = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init(src: []const u8) !TmpProgram {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(t.io, .{ .sub_path = "prog.dbg", .data = src });
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = buf[0..try tmp.dir.realPath(t.io, &buf)];
        const path = try std.fs.path.join(t.allocator, &.{ dir, "prog.dbg" });
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *TmpProgram) void {
        t.allocator.free(self.path);
        self.tmp.cleanup();
    }

    /// `"<path>"` with backslashes escaped for a JSON literal.
    fn json(self: *const TmpProgram, a: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.append(a, '"');
        for (self.path) |c| {
            if (c == '\\' or c == '"') try out.append(a, '\\');
            try out.append(a, c);
        }
        try out.append(a, '"');
        return out.toOwnedSlice(a);
    }
};

test "framing: readFrame skips other headers and takes exactly Content-Length bytes" {
    const text = "Content-Type: application/json\r\nContent-Length: 5\r\n\r\nhelloContent-Length: 2\r\n\r\nokX";
    var r: Io.Reader = .fixed(text);
    const a = try readFrame(t.allocator, &r);
    defer t.allocator.free(a);
    try t.expectEqualStrings("hello", a);
    const b = try readFrame(t.allocator, &r);
    defer t.allocator.free(b);
    try t.expectEqualStrings("ok", b);
    try t.expectError(error.Closed, readFrame(t.allocator, &r));
    var bad: Io.Reader = .fixed("Content-Length: x\r\n\r\n");
    try t.expectError(error.BadFrame, readFrame(t.allocator, &bad));
}

test "initialize: capabilities and the two filters, then a telemetry output event (no `initialized` yet — that follows `launch`); an unknown request fails without a crash" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const out = try h.send("initialize", "{\"clientID\":\"mnml\"}");
    defer t.allocator.free(out);
    try t.expectEqual(@as(usize, 2), out.len);
    try expectResponse(out[0], "initialize", true);
    const tele = try expectEvent(out[1], "output");
    try t.expectEqualStrings("telemetry", getStr(tele, "category").?);
    try t.expectEqualStrings("fake-dap-telemetry", getStr(tele, "output").?);
    const caps = getField(out[0], "body").?;
    try t.expect(caps.object.get("supportsConditionalBreakpoints").?.bool);
    try t.expect(caps.object.get("supportsHitConditionalBreakpoints").?.bool);
    try t.expect(caps.object.get("supportsSetVariable").?.bool);
    try t.expect(caps.object.get("supportsEvaluateForHovers").?.bool);
    try t.expect(caps.object.get("supportsTerminateRequest").?.bool);
    try t.expect(!caps.object.get("supportsStepBack").?.bool);
    const fl = getArr(caps, "exceptionBreakpointFilters").?;
    try t.expectEqual(@as(usize, 2), fl.len);
    try t.expectEqualStrings("error", getStr(fl[0], "filter").?);
    try t.expect(!fl[0].object.get("default").?.bool);
    try t.expectEqualStrings("uncaught", getStr(fl[1], "filter").?);
    try t.expect(fl[1].object.get("default").?.bool);
    try t.expectEqual(@as(i64, 1), getInt(out[0], "seq").?);
    try t.expectEqual(@as(i64, 1), getInt(out[0], "request_seq").?);
    const bogus = try h.send("frobnicate", "{}");
    defer t.allocator.free(bogus);
    try t.expectEqual(@as(usize, 1), bogus.len);
    try expectResponse(bogus[0], "frobnicate", false);
    try t.expectEqualStrings("unsupported request: frobnicate", getStr(bogus[0], "message").?);
    const not_json = "this is not json";
    try h.server.handle(not_json);
    try h.drain();
    try t.expectEqual(@as(usize, 3), h.parsed.items.len);
    // `arguments` as a list — the shape a client's empty tuple once took
    // on the wire — is refused as debugpy refuses it, not answered.
    const listed = try h.send("configurationDone", "[]");
    defer t.allocator.free(listed);
    try expectResponse(listed[0], "configurationDone", false);
    try t.expectEqualStrings("configurationDone: `arguments` must be an object, not array", getStr(listed[0], "message").?);
}

test "the session: breakpoints before launch verify against the file, launch + configurationDone run to the stop, inspection, steps, evaluate, setVariable, exception, exit" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    var tp = try TmpProgram.init(sample);
    defer tp.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const pj = try tp.json(a);

    t.allocator.free(try h.send("initialize", "{}"));
    // Breakpoints arrive before launch (as mnml sends them): line 4 is a
    // statement, line 5 (`fn f`) is not, line 40 does not exist.
    const bp = try h.send("setBreakpoints", try std.fmt.allocPrint(a, "{{\"source\":{{\"path\":{s}}},\"breakpoints\":[{{\"line\":4}},{{\"line\":5}},{{\"line\":40}}],\"lines\":[4,5,40]}}", .{pj}));
    defer t.allocator.free(bp);
    try expectResponse(bp[0], "setBreakpoints", true);
    const verified = getArr(getField(bp[0], "body").?, "breakpoints").?;
    try t.expectEqual(@as(usize, 3), verified.len);
    try t.expect(verified[0].object.get("verified").?.bool);
    try t.expect(!verified[1].object.get("verified").?.bool);
    try t.expect(!verified[2].object.get("verified").?.bool);
    try t.expectEqual(@as(i64, 4), getInt(verified[0], "line").?);
    t.allocator.free(try h.send("setExceptionBreakpoints", "{\"filters\":[\"uncaught\"]}"));
    const launch = try h.send("launch", try std.fmt.allocPrint(a, "{{\"program\":{s},\"cwd\":\"/\"}}", .{pj}));
    defer t.allocator.free(launch);
    // The reply, then `initialized` — only now, as lldb-dap and debugpy have it.
    try t.expectEqual(@as(usize, 2), launch.len);
    try expectResponse(launch[0], "launch", true);
    _ = try expectEvent(launch[1], "initialized");

    // configurationDone starts the run: `hello` is printed, then the stop at 4.
    const go = try h.send("configurationDone", "{}");
    defer t.allocator.free(go);
    try t.expectEqual(@as(usize, 3), go.len);
    try expectResponse(go[0], "configurationDone", true);
    const outb = try expectEvent(go[1], "output");
    try t.expectEqualStrings("stdout", getStr(outb, "category").?);
    try t.expectEqualStrings("hello\n", getStr(outb, "output").?);
    const st = try expectEvent(go[2], "stopped");
    try t.expectEqualStrings("breakpoint", getStr(st, "reason").?);
    try t.expectEqual(@as(i64, 1), getInt(st, "threadId").?);
    try t.expect(st.object.get("allThreadsStopped").?.bool);
    try t.expect(st.object.get("text") == null);

    // threads / stackTrace / scopes / variables.
    const th = try h.send("threads", "{}");
    defer t.allocator.free(th);
    const threads = getArr(getField(th[0], "body").?, "threads").?;
    try t.expectEqual(@as(usize, 1), threads.len);
    try t.expectEqualStrings("main", getStr(threads[0], "name").?);
    const stk = try h.send("stackTrace", "{\"threadId\":1,\"startFrame\":0,\"levels\":64}");
    defer t.allocator.free(stk);
    const frames = getArr(getField(stk[0], "body").?, "stackFrames").?;
    try t.expectEqual(@as(usize, 1), frames.len);
    try t.expectEqual(@as(i64, 1), getInt(frames[0], "id").?);
    try t.expectEqualStrings("main", getStr(frames[0], "name").?);
    try t.expectEqual(@as(i64, 4), getInt(frames[0], "line").?);
    try t.expectEqualStrings(tp.path, getStr(getObj(frames[0], "source").?, "path").?);
    try t.expectEqualStrings("prog.dbg", getStr(getObj(frames[0], "source").?, "name").?);
    const sc = try h.send("scopes", "{\"frameId\":1}");
    defer t.allocator.free(sc);
    const scopes = getArr(getField(sc[0], "body").?, "scopes").?;
    try t.expectEqualStrings("Locals", getStr(scopes[0], "name").?);
    try t.expectEqualStrings("Globals", getStr(scopes[1], "name").?);
    const locals_ref = getInt(scopes[0], "variablesReference").?;
    try t.expectEqual(@as(i64, 1), locals_ref);
    const vars = try h.send("variables", "{\"variablesReference\":1}");
    defer t.allocator.free(vars);
    const list = getArr(getField(vars[0], "body").?, "variables").?;
    try t.expectEqual(@as(usize, 2), list.len);
    try t.expectEqualStrings("x", getStr(list[0], "name").?);
    try t.expectEqualStrings("1", getStr(list[0], "value").?);
    try t.expectEqualStrings("int", getStr(list[0], "type").?);
    try t.expectEqual(@as(i64, 0), getInt(list[0], "variablesReference").?);
    try t.expectEqualStrings("p", getStr(list[1], "name").?);
    try t.expectEqualStrings("{a=1, b=\"two\"}", getStr(list[1], "value").?);
    try t.expectEqualStrings("struct", getStr(list[1], "type").?);
    const pref = getInt(list[1], "variablesReference").?;
    try t.expectEqual(@as(i64, 1000), pref);
    const kids = try h.send("variables", "{\"variablesReference\":1000}");
    defer t.allocator.free(kids);
    const klist = getArr(getField(kids[0], "body").?, "variables").?;
    try t.expectEqual(@as(usize, 2), klist.len);
    try t.expectEqualStrings("b", getStr(klist[1], "name").?);
    try t.expectEqualStrings("\"two\"", getStr(klist[1], "value").?);
    try t.expectEqualStrings("string", getStr(klist[1], "type").?);
    const nope = try h.send("variables", "{\"variablesReference\":77}");
    defer t.allocator.free(nope);
    try expectResponse(nope[0], "variables", false);

    // evaluate in the three contexts; a bad expression fails cleanly.
    const ev = try h.send("evaluate", "{\"expression\":\"x + 41\",\"context\":\"watch\",\"frameId\":1}");
    defer t.allocator.free(ev);
    try expectResponse(ev[0], "evaluate", true);
    try t.expectEqualStrings("42", getStr(getField(ev[0], "body").?, "result").?);
    try t.expectEqualStrings("int", getStr(getField(ev[0], "body").?, "type").?);
    const evp = try h.send("evaluate", "{\"expression\":\"p\",\"context\":\"repl\"}");
    defer t.allocator.free(evp);
    try t.expectEqual(@as(i64, 1001), getInt(getField(evp[0], "body").?, "variablesReference").?);
    const evh = try h.send("evaluate", "{\"expression\":\"p.b\",\"context\":\"hover\"}");
    defer t.allocator.free(evh);
    try t.expectEqualStrings("\"two\"", getStr(getField(evh[0], "body").?, "result").?);
    const bad = try h.send("evaluate", "{\"expression\":\"nope\",\"context\":\"repl\"}");
    defer t.allocator.free(bad);
    try expectResponse(bad[0], "evaluate", false);
    try t.expectEqualStrings("no such variable", getStr(bad[0], "message").?);

    // setVariable on Locals, then on the struct's field.
    const sv = try h.send("setVariable", "{\"variablesReference\":1,\"name\":\"x\",\"value\":\"x + 4\"}");
    defer t.allocator.free(sv);
    try expectResponse(sv[0], "setVariable", true);
    try t.expectEqualStrings("5", getStr(getField(sv[0], "body").?, "value").?);
    const svf = try h.send("setVariable", "{\"variablesReference\":1000,\"name\":\"a\",\"value\":\"9\"}");
    defer t.allocator.free(svf);
    try t.expectEqualStrings("9", getStr(getField(svf[0], "body").?, "value").?);
    const svbad = try h.send("setVariable", "{\"variablesReference\":1,\"name\":\"zz\",\"value\":\"1\"}");
    defer t.allocator.free(svbad);
    try expectResponse(svbad[0], "setVariable", false);

    // next: response, continued, stopped(step) at line 9 (`fn` is skipped).
    const nx = try h.send("next", "{\"threadId\":1}");
    defer t.allocator.free(nx);
    try t.expectEqual(@as(usize, 3), nx.len);
    try expectResponse(nx[0], "next", true);
    const cont = try expectEvent(nx[1], "continued");
    try t.expect(cont.object.get("allThreadsContinued").?.bool);
    try t.expectEqualStrings("step", getStr(try expectEvent(nx[2], "stopped"), "reason").?);
    const stk2 = try h.send("stackTrace", "{\"threadId\":1}");
    defer t.allocator.free(stk2);
    try t.expectEqual(@as(i64, 9), getInt(getArr(getField(stk2[0], "body").?, "stackFrames").?[0], "line").?);
    // The old struct reference is gone after a resume.
    const gone = try h.send("variables", "{\"variablesReference\":1000}");
    defer t.allocator.free(gone);
    try expectResponse(gone[0], "variables", false);

    // stepIn: two frames, the callee on top with id 2.
    t.allocator.free(try h.send("stepIn", "{\"threadId\":1}"));
    const stk3 = try h.send("stackTrace", "{\"threadId\":1}");
    defer t.allocator.free(stk3);
    const fr3 = getArr(getField(stk3[0], "body").?, "stackFrames").?;
    try t.expectEqual(@as(usize, 2), fr3.len);
    try t.expectEqual(@as(i64, 2), getInt(fr3[0], "id").?);
    try t.expectEqualStrings("f", getStr(fr3[0], "name").?);
    try t.expectEqual(@as(i64, 6), getInt(fr3[0], "line").?);
    try t.expectEqualStrings("main", getStr(fr3[1], "name").?);
    try t.expectEqual(@as(i64, 9), getInt(fr3[1], "line").?);
    const sc2 = try h.send("scopes", "{\"frameId\":2}");
    defer t.allocator.free(sc2);
    const scopes2 = getArr(getField(sc2[0], "body").?, "scopes").?;
    try t.expectEqual(@as(i64, 3), getInt(scopes2[0], "variablesReference").?);
    try t.expectEqual(@as(i64, 4), getInt(scopes2[1], "variablesReference").?);
    const glob = try h.send("variables", "{\"variablesReference\":4}");
    defer t.allocator.free(glob);
    try t.expectEqualStrings("x", getStr(getArr(getField(glob[0], "body").?, "variables").?[0], "name").?);
    // Locals of the callee are empty before `let y` runs; one after `next`.
    const loc0 = try h.send("variables", "{\"variablesReference\":3}");
    defer t.allocator.free(loc0);
    try t.expectEqual(@as(usize, 0), getArr(getField(loc0[0], "body").?, "variables").?.len);
    t.allocator.free(try h.send("next", "{\"threadId\":1}"));
    const loc1 = try h.send("variables", "{\"variablesReference\":3}");
    defer t.allocator.free(loc1);
    try t.expectEqualStrings("10", getStr(getArr(getField(loc1[0], "body").?, "variables").?[0], "value").?);
    // stepOut: back in main, after the call, x = 60 (5 + 1, times y).
    t.allocator.free(try h.send("stepOut", "{\"threadId\":1}"));
    const stk4 = try h.send("stackTrace", "{\"threadId\":1}");
    defer t.allocator.free(stk4);
    const fr4 = getArr(getField(stk4[0], "body").?, "stackFrames").?;
    try t.expectEqual(@as(usize, 1), fr4.len);
    try t.expectEqual(@as(i64, 10), getInt(fr4[0], "line").?);
    const evx = try h.send("evaluate", "{\"expression\":\"x\",\"context\":\"watch\"}");
    defer t.allocator.free(evx);
    try t.expectEqualStrings("60", getStr(getField(evx[0], "body").?, "result").?);

    // continue: `print x` output, then the uncaught throw stops with its text.
    const c1 = try h.send("continue", "{\"threadId\":1}");
    defer t.allocator.free(c1);
    try t.expectEqual(@as(usize, 5), c1.len);
    try expectResponse(c1[0], "continue", true);
    _ = try expectEvent(c1[1], "continued");
    try t.expectEqualStrings("60\n", getStr(try expectEvent(c1[2], "output"), "output").?);
    const eo = try expectEvent(c1[3], "output");
    try t.expectEqualStrings("stderr", getStr(eo, "category").?);
    try t.expectEqualStrings("throw: boom\n", getStr(eo, "output").?);
    const ex = try expectEvent(c1[4], "stopped");
    try t.expectEqualStrings("exception", getStr(ex, "reason").?);
    try t.expectEqualStrings("boom", getStr(ex, "text").?);
    // pause while stopped is a failure, not a crash.
    const pz = try h.send("pause", "{\"threadId\":1}");
    defer t.allocator.free(pz);
    try expectResponse(pz[0], "pause", false);
    // continue again: the exception is uncaught → exited(1) + terminated.
    const c2 = try h.send("continue", "{\"threadId\":1}");
    defer t.allocator.free(c2);
    try t.expectEqual(@as(usize, 5), c2.len);
    try t.expectEqualStrings("uncaught: boom\n", getStr(try expectEvent(c2[2], "output"), "output").?);
    try t.expectEqual(@as(i64, 1), getInt(try expectEvent(c2[3], "exited"), "exitCode").?);
    _ = try expectEvent(c2[4], "terminated");
    // After the end, inspection fails and disconnect ends the loop without a second `terminated`.
    const late = try h.send("stackTrace", "{\"threadId\":1}");
    defer t.allocator.free(late);
    try expectResponse(late[0], "stackTrace", false);
    const dc = try h.send("disconnect", "{\"terminateDebuggee\":true}");
    defer t.allocator.free(dc);
    try t.expectEqual(@as(usize, 1), dc.len);
    try t.expect(h.server.done);
    // Every frame carried a strictly increasing seq.
    var last: i64 = 0;
    for (h.parsed.items) |p| {
        const s = getInt(p.value, "seq").?;
        try t.expect(s > last);
        last = s;
    }
}

test "sleep runs until pause; terminate ends a running program; a missing program fails launch" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    var tp = try TmpProgram.init("let n = 7\nsleep\nprint n\n");
    defer tp.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const pj = try tp.json(a);
    t.allocator.free(try h.send("initialize", "{}"));
    const missing = try h.send("launch", "{\"program\":\"/nonexistent/none.dbg\"}");
    defer t.allocator.free(missing);
    try expectResponse(missing[0], "launch", false);
    try t.expect(std.mem.startsWith(u8, getStr(missing[0], "message").?, "cannot read /nonexistent/none.dbg"));
    t.allocator.free(try h.send("launch", try std.fmt.allocPrint(a, "{{\"program\":{s}}}", .{pj})));
    const go = try h.send("configurationDone", "{}");
    defer t.allocator.free(go);
    try t.expectEqual(@as(usize, 1), go.len); // running (sleeping): no stop yet
    const pz = try h.send("pause", "{\"threadId\":1}");
    defer t.allocator.free(pz);
    try t.expectEqual(@as(usize, 2), pz.len);
    try expectResponse(pz[0], "pause", true);
    try t.expectEqualStrings("pause", getStr(try expectEvent(pz[1], "stopped"), "reason").?);
    const stk = try h.send("stackTrace", "{\"threadId\":1}");
    defer t.allocator.free(stk);
    try t.expectEqual(@as(i64, 2), getInt(getArr(getField(stk[0], "body").?, "stackFrames").?[0], "line").?);
    const term = try h.send("terminate", "{}");
    defer t.allocator.free(term);
    try t.expectEqual(@as(usize, 2), term.len);
    try expectResponse(term[0], "terminate", true);
    _ = try expectEvent(term[1], "terminated");
    const nx = try h.send("next", "{\"threadId\":1}");
    defer t.allocator.free(nx);
    try expectResponse(nx[0], "next", false);
}

test "attach: the program runs as a launch would; the ledger says detached after disconnect{terminateDebuggee:false}, killed after terminate" {
    var tp = try TmpProgram.init("let n = 7\nprint n\nsleep\n");
    defer tp.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const pj = try tp.json(a);
    const ledger_path = try std.fmt.allocPrint(a, "{s}.debuggee", .{tp.path});
    const Ledger = struct {
        fn read(alloc_: Allocator, path: []const u8) ![]u8 {
            return Io.Dir.cwd().readFileAlloc(t.io, path, alloc_, .limited(64));
        }
    };
    {
        var h: Harness = undefined;
        h.init();
        defer h.deinit();
        t.allocator.free(try h.send("initialize", "{}"));
        const no_program = try h.send("attach", "{\"request\":\"attach\"}");
        defer t.allocator.free(no_program);
        try expectResponse(no_program[0], "attach", false);
        const at = try h.send("attach", try std.fmt.allocPrint(a, "{{\"request\":\"attach\",\"program\":{s}}}", .{pj}));
        defer t.allocator.free(at);
        try t.expectEqual(@as(usize, 2), at.len);
        try expectResponse(at[0], "attach", true);
        _ = try expectEvent(at[1], "initialized");
        try t.expectEqualStrings("attached\n", try Ledger.read(a, ledger_path));
        const go = try h.send("configurationDone", "{}");
        defer t.allocator.free(go);
        try t.expectEqualStrings("7\n", getStr(try expectEvent(go[1], "output"), "output").?);
        // Detach: the process outlives the session.
        const dc = try h.send("disconnect", "{\"terminateDebuggee\":false}");
        defer t.allocator.free(dc);
        try expectResponse(dc[0], "disconnect", true);
        try t.expect(h.server.done);
        try t.expectEqualStrings("detached\n", try Ledger.read(a, ledger_path));
    }
    {
        var h: Harness = undefined;
        h.init();
        defer h.deinit();
        t.allocator.free(try h.send("initialize", "{}"));
        t.allocator.free(try h.send("attach", try std.fmt.allocPrint(a, "{{\"request\":\"attach\",\"program\":{s}}}", .{pj})));
        t.allocator.free(try h.send("configurationDone", "{}"));
        t.allocator.free(try h.send("terminate", "{}"));
        try t.expectEqualStrings("killed\n", try Ledger.read(a, ledger_path));
    }
}

test "breakpoints for another file are unverified and not kept; conditions and hit counts reach the program" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    var tp = try TmpProgram.init("let i = 0\nfn loop\n  i = i + 1\nend\ncall loop\ncall loop\ncall loop\ncall loop\nprint i\n");
    defer tp.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const pj = try tp.json(a);
    t.allocator.free(try h.send("initialize", "{}"));
    t.allocator.free(try h.send("launch", try std.fmt.allocPrint(a, "{{\"program\":{s}}}", .{pj})));
    const other = try h.send("setBreakpoints", "{\"source\":{\"path\":\"/elsewhere/other.dbg\"},\"breakpoints\":[{\"line\":1}]}");
    defer t.allocator.free(other);
    try t.expect(!getArr(getField(other[0], "body").?, "breakpoints").?[0].object.get("verified").?.bool);
    const set = try h.send("setBreakpoints", try std.fmt.allocPrint(a, "{{\"source\":{{\"path\":{s}}},\"breakpoints\":[{{\"line\":3,\"condition\":\"i >= 1\",\"hitCondition\":\"% 2\"}}]}}", .{pj}));
    defer t.allocator.free(set);
    try t.expect(getArr(getField(set[0], "body").?, "breakpoints").?[0].object.get("verified").?.bool);
    // The condition holds from the 2nd call on; the hit count fires on
    // the 2nd matching hit: the 3rd call, i == 2.
    const go = try h.send("configurationDone", "{}");
    defer t.allocator.free(go);
    try t.expectEqualStrings("breakpoint", getStr(try expectEvent(go[1], "stopped"), "reason").?);
    const ev = try h.send("evaluate", "{\"expression\":\"i\",\"context\":\"repl\"}");
    defer t.allocator.free(ev);
    try t.expectEqualStrings("2", getStr(getField(ev[0], "body").?, "result").?);
    const c = try h.send("continue", "{\"threadId\":1}");
    defer t.allocator.free(c);
    try t.expectEqualStrings("4\n", getStr(try expectEvent(c[2], "output"), "output").?);
    try t.expectEqual(@as(i64, 0), getInt(try expectEvent(c[3], "exited"), "exitCode").?);
}
