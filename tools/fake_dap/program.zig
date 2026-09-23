//! The tiny line-oriented language `mnml-fake-dap` "runs", and the
//! debugger model over it: frames, variables, breakpoints (with
//! conditions and hit counts), stepping, exceptions, output.
//!
//! Every line is one statement (blank lines and `#` comments are not
//! statements: steps skip them and a breakpoint on one is unverified).
//! A breakpoint on a line stops before it runs; `next` runs one line;
//! `stepIn` on a `call` lands on the function's first line; `stepOut`
//! returns to the line after the `call`. Nothing here reads a clock,
//! the environment, or randomness: the same program and the same
//! requests give the same events, byte for byte.
//!
//! Ownership: one arena for the whole program — the parsed source, the
//! frames, every value a run or a `setVariable` makes. `deinit` frees
//! it; nothing is freed piecemeal. The server keeps the arena alive for
//! the session and starts a fresh `Program` per `launch`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Field = struct { name: []const u8, value: Scalar };

/// What a struct field holds (structs do not nest).
pub const Scalar = union(enum) {
    int: i64,
    str: []const u8,

    fn toValue(self: Scalar) Value {
        return switch (self) {
            .int => |i| .{ .int = i },
            .str => |s| .{ .str = s },
        };
    }
};

pub const Value = union(enum) {
    int: i64,
    str: []const u8,
    strct: []Field,

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .int => "int",
            .str => "string",
            .strct => "struct",
        };
    }

    /// How the debugger shows it: `42`, `"hi"`, `{a=1, b="x"}`.
    pub fn render(self: Value, arena: Allocator) Allocator.Error![]const u8 {
        switch (self) {
            .int => |i| return std.fmt.allocPrint(arena, "{d}", .{i}),
            .str => |s| return std.fmt.allocPrint(arena, "\"{s}\"", .{s}),
            .strct => |fields| {
                var out: std.ArrayList(u8) = .empty;
                try out.append(arena, '{');
                for (fields, 0..) |f, i| {
                    if (i > 0) try out.appendSlice(arena, ", ");
                    try out.appendSlice(arena, f.name);
                    try out.append(arena, '=');
                    try out.appendSlice(arena, try f.value.toValue().render(arena));
                }
                try out.append(arena, '}');
                return out.toOwnedSlice(arena);
            },
        }
    }

    /// What `print` writes: strings bare, the rest as rendered.
    fn printed(self: Value, arena: Allocator) Allocator.Error![]const u8 {
        return switch (self) {
            .str => |s| s,
            else => self.render(arena),
        };
    }

    fn truthy(self: Value) bool {
        return switch (self) {
            .int => |i| i != 0,
            .str => |s| s.len > 0,
            .strct => true,
        };
    }
};

pub const Var = struct { name: []const u8, value: Value };

pub const Frame = struct {
    name: []const u8,
    /// The 0-based index of the line this frame is at: the statement
    /// about to run for the top frame, the `call` line for a caller.
    pc: usize,
    vars: std.ArrayList(Var) = .empty,
};

pub const Stmt = union(enum) {
    /// A blank or `#` line: not a statement.
    blank,
    let: struct { name: []const u8, value: Value },
    assign: struct { name: []const u8, expr: []const u8 },
    print: []const u8,
    call: []const u8,
    /// `fn <name>`; `end_index` is the line of its `end`.
    fn_def: struct { name: []const u8, end_index: usize },
    end,
    throw: []const u8,
    sleep,
    exit: i64,
    /// A line that did not parse; running it is an error stop.
    bad: []const u8,
};

pub const Breakpoint = struct {
    /// 1-based, as on the wire.
    line: u32,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,
    hits: u32 = 0,
    verified: bool = false,
};

pub const Reason = enum { breakpoint, step, exception, pause };

pub const Outcome = union(enum) {
    stopped: Reason,
    /// A `sleep` line is running; `pause` ends it.
    sleeping,
    exited: i64,
};

pub const Mode = enum { @"continue", next, step_in, step_out };

pub const Output = struct { category: []const u8, text: []const u8 };

pub const EvalError = error{ NoSuchVariable, NoSuchField, NotAStruct, TypeMismatch, DivisionByZero, Syntax } || Allocator.Error;

pub const Program = struct {
    arena_state: std.heap.ArenaAllocator,
    /// The program's lines, one `Stmt` each.
    stmts: []Stmt = &.{},
    /// The function table: name → the line after `fn`, and its `end`.
    fns: std.ArrayList(FnEntry) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    breakpoints: std.ArrayList(Breakpoint) = .empty,
    /// `error` stops on every throw; `uncaught` (the default) only on a
    /// throw that reaches the top level.
    stop_on_error: bool = false,
    stop_on_uncaught: bool = true,
    /// Output produced since the last drain, in order.
    pending_output: std.ArrayList(Output) = .empty,
    /// The struct refs handed out since the last resume: index + 1000.
    struct_refs: std.ArrayList(StructRef) = .empty,
    state: enum { not_started, stopped, sleeping, exited } = .not_started,
    /// A `stepOut` from main stopped in the runtime's `start` frame —
    /// the one a debugger shows after main returns (lldb's dyld`start),
    /// which has no file; any resume from there is the exit.
    in_runtime: bool = false,
    /// Set by a stop at a `throw`: the resume unwinds it first.
    pending_throw: bool = false,
    /// The line a `pause` interrupted: its `sleep` is done.
    sleep_done: ?usize = null,
    /// A stop was just reported at this line: its breakpoint does not
    /// fire again on resume.
    resume_line: ?usize = null,
    /// The last exception's message, for `stopped.description`.
    last_throw: []const u8 = "",
    /// Its type, for `stopped.text`: `Throw` for a `throw` line,
    /// `Error` for a runtime error.
    last_throw_type: []const u8 = "",

    const FnEntry = struct { name: []const u8, body: usize, end_index: usize };
    pub const StructRef = struct { frame: usize, name: []const u8 };

    pub const scope_base: i64 = 1;
    pub const struct_base: i64 = 1000;

    pub fn init(gpa: Allocator) Program {
        return .{ .arena_state = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Program) void {
        self.arena_state.deinit();
        self.* = undefined;
    }

    pub fn arena(self: *Program) Allocator {
        return self.arena_state.allocator();
    }

    // ─── parsing ───

    /// Parse `src` into statements; the main frame is placed at the
    /// first statement. A second `load` replaces everything.
    pub fn load(self: *Program, src_in: []const u8) Allocator.Error!void {
        const a = self.arena();
        const src = try a.dupe(u8, src_in);
        var stmts: std.ArrayList(Stmt) = .empty;
        var lines = std.mem.splitScalar(u8, src, '\n');
        while (lines.next()) |raw| try stmts.append(a, try parseLine(a, std.mem.trimEnd(u8, raw, "\r")));
        // A trailing newline leaves one empty "line" past the end.
        if (stmts.items.len > 0 and std.mem.endsWith(u8, src, "\n")) _ = stmts.pop();
        self.stmts = try stmts.toOwnedSlice(a);
        // Pair every `fn` with its `end` (no nesting).
        self.fns = .empty;
        var i: usize = 0;
        while (i < self.stmts.len) : (i += 1) {
            switch (self.stmts[i]) {
                .fn_def => |*f| {
                    var j = i + 1;
                    while (j < self.stmts.len and self.stmts[j] != .end) : (j += 1) {}
                    f.end_index = j;
                    try self.fns.append(a, .{ .name = f.name, .body = i + 1, .end_index = j });
                    i = j;
                },
                else => {},
            }
        }
        self.frames = .empty;
        try self.frames.append(a, .{ .name = "main", .pc = 0 });
        self.state = .not_started;
        self.pending_throw = false;
        self.sleep_done = null;
        self.resume_line = null;
        self.struct_refs = .empty;
        self.pending_output = .empty;
    }

    fn parseLine(a: Allocator, raw: []const u8) Allocator.Error!Stmt {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#') return .blank;
        const kw, const rest = split1(line);
        if (std.mem.eql(u8, kw, "let")) {
            const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return .{ .bad = "let needs `let <name> = <value>`" };
            const name = std.mem.trim(u8, rest[0..eq], " \t");
            if (!isIdent(name)) return .{ .bad = "let: bad name" };
            const lit = std.mem.trim(u8, rest[eq + 1 ..], " \t");
            const value = parseLiteral(a, lit) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .bad = "let: expected an int, a \"string\" or struct{a=1,b=2}" },
            };
            return .{ .let = .{ .name = name, .value = value } };
        }
        if (std.mem.eql(u8, kw, "print")) return .{ .print = rest };
        if (std.mem.eql(u8, kw, "call")) return if (isIdent(rest)) .{ .call = rest } else .{ .bad = "call: bad name" };
        if (std.mem.eql(u8, kw, "fn")) return if (isIdent(rest)) .{ .fn_def = .{ .name = rest, .end_index = 0 } } else .{ .bad = "fn: bad name" };
        if (std.mem.eql(u8, kw, "end")) return .end;
        if (std.mem.eql(u8, kw, "throw")) return .{ .throw = unquote(rest) };
        if (std.mem.eql(u8, kw, "sleep")) return .sleep;
        if (std.mem.eql(u8, kw, "exit")) return .{ .exit = std.fmt.parseInt(i64, rest, 10) catch return .{ .bad = "exit needs a code" } };
        // `name = expr`
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            const name = std.mem.trim(u8, line[0..eq], " \t");
            if (isIdent(name) and eq + 1 < line.len and line[eq + 1] != '=') {
                return .{ .assign = .{ .name = name, .expr = std.mem.trim(u8, line[eq + 1 ..], " \t") } };
            }
        }
        return .{ .bad = "unknown statement" };
    }

    /// `42`, `"text"`, `struct{a=1,b="x"}`.
    fn parseLiteral(a: Allocator, lit: []const u8) EvalError!Value {
        if (lit.len == 0) return error.Syntax;
        if (lit[0] == '"') {
            if (lit.len < 2 or lit[lit.len - 1] != '"') return error.Syntax;
            return .{ .str = lit[1 .. lit.len - 1] };
        }
        if (std.mem.startsWith(u8, lit, "struct{") and lit[lit.len - 1] == '}') {
            var fields: std.ArrayList(Field) = .empty;
            var it = std.mem.splitScalar(u8, lit["struct{".len .. lit.len - 1], ',');
            while (it.next()) |part| {
                const p = std.mem.trim(u8, part, " \t");
                if (p.len == 0) continue;
                const eq = std.mem.indexOfScalar(u8, p, '=') orelse return error.Syntax;
                const name = std.mem.trim(u8, p[0..eq], " \t");
                if (!isIdent(name)) return error.Syntax;
                const v = try parseLiteral(a, std.mem.trim(u8, p[eq + 1 ..], " \t"));
                const scalar: Scalar = switch (v) {
                    .int => |i| .{ .int = i },
                    .str => |s| .{ .str = s },
                    .strct => return error.Syntax,
                };
                try fields.append(a, .{ .name = name, .value = scalar });
            }
            return .{ .strct = try fields.toOwnedSlice(a) };
        }
        return .{ .int = std.fmt.parseInt(i64, lit, 10) catch return error.Syntax };
    }

    // ─── breakpoints ───

    /// Replace the list; hit counts start over. Each entry's `verified`
    /// says whether the line is a statement.
    pub fn setBreakpoints(self: *Program, list: []const Breakpoint) Allocator.Error![]const Breakpoint {
        const a = self.arena();
        self.breakpoints = .empty;
        for (list) |b| {
            var bp = b;
            bp.hits = 0;
            bp.verified = self.isStatementLine(bp.line);
            if (bp.condition) |c| bp.condition = try a.dupe(u8, c);
            if (bp.hit_condition) |h| bp.hit_condition = try a.dupe(u8, h);
            try self.breakpoints.append(a, bp);
        }
        return self.breakpoints.items;
    }

    fn isStatementLine(self: *const Program, line1: u32) bool {
        if (line1 == 0 or line1 > self.stmts.len) return false;
        return switch (self.stmts[line1 - 1]) {
            .blank, .fn_def => false,
            else => true,
        };
    }

    pub fn setExceptionFilters(self: *Program, filters: []const []const u8) void {
        self.stop_on_error = false;
        self.stop_on_uncaught = false;
        for (filters) |f| {
            if (std.mem.eql(u8, f, "error")) self.stop_on_error = true;
            if (std.mem.eql(u8, f, "uncaught")) self.stop_on_uncaught = true;
        }
    }

    // ─── running ───

    pub fn depth(self: *const Program) usize {
        return self.frames.items.len;
    }

    fn top(self: *Program) *Frame {
        return &self.frames.items[self.frames.items.len - 1];
    }

    /// Run from the current position in `mode` until something stops
    /// the program. `not_started` runs from the first statement (a
    /// breakpoint there fires).
    pub fn run(self: *Program, mode: Mode) Allocator.Error!Outcome {
        const a = self.arena();
        if (self.state == .exited) return .{ .exited = 0 };
        if (self.in_runtime) return self.finish(0);
        const start_depth = self.depth();
        var executed: usize = 0;
        self.struct_refs = .empty;
        if (self.pending_throw) {
            self.pending_throw = false;
            if (try self.unwind()) |code| return self.finish(code);
            executed = 1; // the throw counted as the line that ran
        }
        while (true) {
            const f = self.top();
            if (f.pc >= self.stmts.len) {
                if (self.frames.items.len > 1) {
                    _ = self.frames.pop();
                    self.top().pc += 1;
                    continue;
                }
                // Stepping out of main: the caller is the runtime.
                if (mode == .step_out) {
                    self.in_runtime = true;
                    self.state = .stopped;
                    return .{ .stopped = .step };
                }
                return self.finish(0);
            }
            const stmt = self.stmts[f.pc];
            switch (stmt) {
                .blank => {
                    f.pc += 1;
                    continue;
                },
                .fn_def => |d| {
                    f.pc = d.end_index + 1;
                    continue;
                },
                else => {},
            }
            // Before the statement runs: a breakpoint, then a step stop.
            if (self.resume_line != f.pc) {
                if (try self.breakpointHit(f.pc)) return self.stop(.breakpoint);
            }
            self.resume_line = null;
            if (executed > 0) {
                const d = self.depth();
                const stop_now = switch (mode) {
                    .@"continue" => false,
                    .step_in => true,
                    .next => d <= start_depth,
                    .step_out => d < start_depth,
                };
                if (stop_now) return self.stop(.step);
            }
            // Run it.
            executed += 1;
            switch (stmt) {
                .let => |l| {
                    try self.define(f, l.name, l.value);
                    f.pc += 1;
                },
                .assign => |as| {
                    const v = self.evaluate(as.expr, self.frames.items.len - 1) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return self.runtimeError(f.pc, "cannot evaluate `{s}`: {s}", .{ as.expr, errName(err) }),
                    };
                    self.assignIn(f, as.name, v) catch {
                        // An unknown name on the left defines it here.
                        try self.define(f, as.name, v);
                    };
                    f.pc += 1;
                },
                .print => |expr| {
                    const v = self.evaluate(expr, self.frames.items.len - 1) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return self.runtimeError(f.pc, "cannot print `{s}`: {s}", .{ expr, errName(err) }),
                    };
                    try self.pending_output.append(a, .{ .category = "stdout", .text = try std.fmt.allocPrint(a, "{s}\n", .{try v.printed(a)}) });
                    f.pc += 1;
                },
                .call => |name| {
                    const entry = self.findFn(name) orelse return self.runtimeError(f.pc, "no such function `{s}`", .{name});
                    try self.frames.append(a, .{ .name = name, .pc = entry.body });
                },
                .end => {
                    if (self.frames.items.len > 1) {
                        _ = self.frames.pop();
                        self.top().pc += 1;
                    } else f.pc += 1;
                },
                .throw => |msg| {
                    self.last_throw = msg;
                    self.last_throw_type = "Throw";
                    try self.pending_output.append(a, .{ .category = "stderr", .text = try std.fmt.allocPrint(a, "throw: {s}\n", .{msg}) });
                    const uncaught = self.frames.items.len == 1;
                    if (self.stop_on_error or (uncaught and self.stop_on_uncaught)) {
                        self.pending_throw = true;
                        return self.stop(.exception);
                    }
                    if (try self.unwind()) |code| return self.finish(code);
                },
                .sleep => {
                    if (self.sleep_done == f.pc) {
                        self.sleep_done = null;
                        f.pc += 1;
                    } else {
                        self.state = .sleeping;
                        return .sleeping;
                    }
                },
                .exit => |code| return self.finish(code),
                .bad => |why| return self.runtimeError(f.pc, "line {d}: {s}", .{ f.pc + 1, why }),
                .blank, .fn_def => unreachable,
            }
        }
    }

    /// The exception leaves its frame (the caller continues after the
    /// `call`) or, at the top level, ends the program with code 1.
    fn unwind(self: *Program) Allocator.Error!?i64 {
        if (self.frames.items.len > 1) {
            _ = self.frames.pop();
            self.top().pc += 1;
            return null;
        }
        try self.pending_output.append(self.arena(), .{ .category = "stderr", .text = try std.fmt.allocPrint(self.arena(), "uncaught: {s}\n", .{self.last_throw}) });
        return 1;
    }

    fn runtimeError(self: *Program, pc: usize, comptime fmt: []const u8, args: anytype) Allocator.Error!Outcome {
        const a = self.arena();
        const msg = try std.fmt.allocPrint(a, fmt, args);
        self.last_throw = msg;
        self.last_throw_type = "Error";
        try self.pending_output.append(a, .{ .category = "stderr", .text = try std.fmt.allocPrint(a, "error: {s}\n", .{msg}) });
        _ = pc;
        self.pending_throw = true;
        return self.stop(.exception);
    }

    fn stop(self: *Program, reason: Reason) Outcome {
        self.state = .stopped;
        self.resume_line = self.top().pc;
        return .{ .stopped = reason };
    }

    fn finish(self: *Program, code: i64) Outcome {
        self.state = .exited;
        return .{ .exited = code };
    }

    /// `pause` while a `sleep` runs: the stop is on the sleep line, and
    /// the sleep is over.
    pub fn pause(self: *Program) ?Outcome {
        if (self.state != .sleeping) return null;
        self.sleep_done = self.top().pc;
        self.state = .stopped;
        self.resume_line = self.top().pc;
        return .{ .stopped = .pause };
    }

    fn breakpointHit(self: *Program, pc: usize) Allocator.Error!bool {
        const line1: u32 = @intCast(pc + 1);
        for (self.breakpoints.items) |*bp| {
            if (bp.line != line1 or !bp.verified) continue;
            if (bp.condition) |c| {
                const v = self.evaluate(c, self.frames.items.len - 1) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => blk: {
                        try self.pending_output.append(self.arena(), .{ .category = "stderr", .text = try std.fmt.allocPrint(self.arena(), "condition `{s}`: {s}\n", .{ c, errName(err) }) });
                        break :blk Value{ .int = 1 };
                    },
                };
                if (!v.truthy()) continue;
            }
            bp.hits += 1;
            if (bp.hit_condition) |h| if (!hitMatches(h, bp.hits)) continue;
            return true;
        }
        return false;
    }

    /// `5`, `== 5`, `>= 5`, `> 5`, `< 5`, `<= 5`, `% 5`. Unparseable
    /// conditions match every hit.
    pub fn hitMatches(cond_in: []const u8, hits: u32) bool {
        const cond = std.mem.trim(u8, cond_in, " \t");
        const Op = enum { eq, ge, gt, lt, le, mod };
        var op: Op = .eq;
        var rest = cond;
        if (std.mem.startsWith(u8, cond, "==")) {
            rest = cond[2..];
        } else if (std.mem.startsWith(u8, cond, ">=")) {
            op = .ge;
            rest = cond[2..];
        } else if (std.mem.startsWith(u8, cond, "<=")) {
            op = .le;
            rest = cond[2..];
        } else if (std.mem.startsWith(u8, cond, ">")) {
            op = .gt;
            rest = cond[1..];
        } else if (std.mem.startsWith(u8, cond, "<")) {
            op = .lt;
            rest = cond[1..];
        } else if (std.mem.startsWith(u8, cond, "%")) {
            op = .mod;
            rest = cond[1..];
        }
        const n = std.fmt.parseInt(u32, std.mem.trim(u8, rest, " \t"), 10) catch return true;
        return switch (op) {
            .eq => hits == n,
            .ge => hits >= n,
            .gt => hits > n,
            .lt => hits < n,
            .le => hits <= n,
            .mod => n != 0 and hits % n == 0,
        };
    }

    // ─── variables ───

    fn findFn(self: *const Program, name: []const u8) ?FnEntry {
        for (self.fns.items) |f| if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }

    fn define(self: *Program, f: *Frame, name: []const u8, value: Value) Allocator.Error!void {
        for (f.vars.items) |*v| if (std.mem.eql(u8, v.name, name)) {
            v.value = value;
            return;
        };
        try f.vars.append(self.arena(), .{ .name = name, .value = value });
    }

    /// Assign to the nearest frame that has `name`: this one, then main.
    fn assignIn(self: *Program, f: *Frame, name: []const u8, value: Value) error{NoSuchVariable}!void {
        for (f.vars.items) |*v| if (std.mem.eql(u8, v.name, name)) {
            v.value = value;
            return;
        };
        const main_frame = &self.frames.items[0];
        for (main_frame.vars.items) |*v| if (std.mem.eql(u8, v.name, name)) {
            v.value = value;
            return;
        };
        return error.NoSuchVariable;
    }

    /// `name` as seen from frame `frame`: its own vars, then main's.
    pub fn lookup(self: *const Program, frame: usize, name: []const u8) ?Value {
        if (frame < self.frames.items.len) {
            for (self.frames.items[frame].vars.items) |v| if (std.mem.eql(u8, v.name, name)) return v.value;
        }
        for (self.frames.items[0].vars.items) |v| if (std.mem.eql(u8, v.name, name)) return v.value;
        return null;
    }

    /// The variables a scope reference names: the frame's own for
    /// Locals, main's for Globals. Null for a reference that is not a
    /// scope.
    pub fn scopeVars(self: *Program, ref: i64) ?*std.ArrayList(Var) {
        if (ref < scope_base or ref >= struct_base) return null;
        const k: usize = @intCast(ref - scope_base);
        const frame = k / 2;
        if (frame >= self.frames.items.len) return null;
        return if (k % 2 == 0) &self.frames.items[frame].vars else &self.frames.items[0].vars;
    }

    pub fn localsRef(frame: usize) i64 {
        return scope_base + @as(i64, @intCast(frame * 2));
    }

    pub fn globalsRef(frame: usize) i64 {
        return scope_base + @as(i64, @intCast(frame * 2)) + 1;
    }

    /// A reference for a struct variable, valid until the next resume.
    pub fn structRef(self: *Program, frame: usize, name: []const u8) Allocator.Error!i64 {
        try self.struct_refs.append(self.arena(), .{ .frame = frame, .name = name });
        return struct_base + @as(i64, @intCast(self.struct_refs.items.len - 1));
    }

    pub fn structOf(self: *const Program, ref: i64) ?StructRef {
        if (ref < struct_base) return null;
        const k: usize = @intCast(ref - struct_base);
        if (k >= self.struct_refs.items.len) return null;
        return self.struct_refs.items[k];
    }

    /// `setVariable` on a scope: `value` is an expression in that frame.
    pub fn setVar(self: *Program, ref: i64, name: []const u8, value_text: []const u8) EvalError!Value {
        if (self.scopeVars(ref)) |vars| {
            const frame: usize = @intCast(@divFloor(ref - scope_base, 2));
            const v = try self.evaluate(value_text, frame);
            for (vars.items) |*existing| if (std.mem.eql(u8, existing.name, name)) {
                existing.value = v;
                return v;
            };
            return error.NoSuchVariable;
        }
        const sr = self.structOf(ref) orelse return error.NoSuchVariable;
        const holder = self.lookup(sr.frame, sr.name) orelse return error.NoSuchVariable;
        const fields = switch (holder) {
            .strct => |f| f,
            else => return error.NotAStruct,
        };
        const v = try self.evaluate(value_text, sr.frame);
        for (fields) |*f| if (std.mem.eql(u8, f.name, name)) {
            f.value = switch (v) {
                .int => |i| .{ .int = i },
                .str => |s| .{ .str = s },
                .strct => return error.TypeMismatch,
            };
            return v;
        };
        return error.NoSuchField;
    }

    /// A console line `name = expr` (lldb's `x = 41`): the value goes
    /// to the nearest `name` — this frame, then main — or defines it
    /// here, and comes back as the result.
    pub fn assign(self: *Program, frame: usize, name: []const u8, expr: []const u8) EvalError!Value {
        const v = try self.evaluate(expr, frame);
        const f = &self.frames.items[@min(frame, self.frames.items.len - 1)];
        self.assignIn(f, name, v) catch try self.define(f, name, v);
        return v;
    }

    // ─── expressions ───

    /// Evaluate `expr` as seen from frame `frame`. Ints, names, `a.b`,
    /// `"strings"`, `struct{…}`, `+ - * /`, `== != < <= > >=`, parens.
    pub fn evaluate(self: *Program, expr: []const u8, frame: usize) EvalError!Value {
        var p: Parser = .{ .prog = self, .src = expr, .frame = frame };
        const v = try p.comparison();
        p.skipWs();
        if (p.i != p.src.len) return error.Syntax;
        return v;
    }

    const Parser = struct {
        prog: *Program,
        src: []const u8,
        frame: usize,
        i: usize = 0,

        fn skipWs(p: *Parser) void {
            while (p.i < p.src.len and (p.src[p.i] == ' ' or p.src[p.i] == '\t')) p.i += 1;
        }

        fn peek(p: *Parser, s: []const u8) bool {
            p.skipWs();
            return std.mem.startsWith(u8, p.src[p.i..], s);
        }

        fn comparison(p: *Parser) EvalError!Value {
            const lhs = try p.additive();
            const ops = [_][]const u8{ "==", "!=", "<=", ">=", "<", ">" };
            for (ops) |op| if (p.peek(op)) {
                p.i += op.len;
                const rhs = try p.additive();
                return .{ .int = if (try compare(op, lhs, rhs)) 1 else 0 };
            };
            return lhs;
        }

        fn compare(op: []const u8, lhs: Value, rhs: Value) EvalError!bool {
            if (lhs == .str and rhs == .str) {
                const eq = std.mem.eql(u8, lhs.str, rhs.str);
                if (std.mem.eql(u8, op, "==")) return eq;
                if (std.mem.eql(u8, op, "!=")) return !eq;
                return error.TypeMismatch;
            }
            if (lhs != .int or rhs != .int) return error.TypeMismatch;
            const a = lhs.int;
            const b = rhs.int;
            if (std.mem.eql(u8, op, "==")) return a == b;
            if (std.mem.eql(u8, op, "!=")) return a != b;
            if (std.mem.eql(u8, op, "<=")) return a <= b;
            if (std.mem.eql(u8, op, ">=")) return a >= b;
            if (std.mem.eql(u8, op, "<")) return a < b;
            return a > b;
        }

        fn additive(p: *Parser) EvalError!Value {
            var lhs = try p.term();
            while (true) {
                // Temporaries: `lhs = .{ .int = f(lhs) }` would write the
                // tag before reading the operand (result-location aliasing).
                if (p.peek("+")) {
                    p.i += 1;
                    const a = try intOf(lhs);
                    const b = try intOf(try p.term());
                    lhs = .{ .int = a +% b };
                } else if (p.peek("-")) {
                    p.i += 1;
                    const a = try intOf(lhs);
                    const b = try intOf(try p.term());
                    lhs = .{ .int = a -% b };
                } else return lhs;
            }
        }

        fn term(p: *Parser) EvalError!Value {
            var lhs = try p.atom();
            while (true) {
                if (p.peek("*")) {
                    p.i += 1;
                    const a = try intOf(lhs);
                    const b = try intOf(try p.atom());
                    lhs = .{ .int = a *% b };
                } else if (p.peek("/")) {
                    p.i += 1;
                    const a = try intOf(lhs);
                    const d = try intOf(try p.atom());
                    if (d == 0) return error.DivisionByZero;
                    lhs = .{ .int = @divTrunc(a, d) };
                } else return lhs;
            }
        }

        fn intOf(v: Value) EvalError!i64 {
            return switch (v) {
                .int => |i| i,
                else => error.TypeMismatch,
            };
        }

        fn atom(p: *Parser) EvalError!Value {
            p.skipWs();
            if (p.i >= p.src.len) return error.Syntax;
            const c = p.src[p.i];
            if (c == '(') {
                p.i += 1;
                const v = try p.comparison();
                if (!p.peek(")")) return error.Syntax;
                p.i += 1;
                return v;
            }
            if (c == '"') {
                const close = std.mem.indexOfScalarPos(u8, p.src, p.i + 1, '"') orelse return error.Syntax;
                const s = p.src[p.i + 1 .. close];
                p.i = close + 1;
                return .{ .str = s };
            }
            if (c == '-' or std.ascii.isDigit(c)) {
                var j = p.i + 1;
                while (j < p.src.len and std.ascii.isDigit(p.src[j])) j += 1;
                const n = std.fmt.parseInt(i64, p.src[p.i..j], 10) catch return error.Syntax;
                p.i = j;
                return .{ .int = n };
            }
            if (std.mem.startsWith(u8, p.src[p.i..], "struct{")) {
                const close = std.mem.indexOfScalarPos(u8, p.src, p.i, '}') orelse return error.Syntax;
                const v = try parseLiteral(p.prog.arena(), p.src[p.i .. close + 1]);
                p.i = close + 1;
                return v;
            }
            if (isIdentStart(c)) {
                var j = p.i + 1;
                while (j < p.src.len and isIdentChar(p.src[j])) j += 1;
                const name = p.src[p.i..j];
                p.i = j;
                var v = p.prog.lookup(p.frame, name) orelse return error.NoSuchVariable;
                while (p.i < p.src.len and p.src[p.i] == '.') {
                    var k = p.i + 1;
                    while (k < p.src.len and isIdentChar(p.src[k])) k += 1;
                    const field = p.src[p.i + 1 .. k];
                    p.i = k;
                    const fields = switch (v) {
                        .strct => |f| f,
                        else => return error.NotAStruct,
                    };
                    v = for (fields) |f| {
                        if (std.mem.eql(u8, f.name, field)) break f.value.toValue();
                    } else return error.NoSuchField;
                }
                return v;
            }
            return error.Syntax;
        }
    };

    /// Drain the output produced since the last call.
    pub fn takeOutput(self: *Program) []const Output {
        const items = self.pending_output.items;
        self.pending_output = .empty;
        return items;
    }
};

pub fn errName(err: anyerror) []const u8 {
    return switch (err) {
        error.NoSuchVariable => "no such variable",
        error.NoSuchField => "no such field",
        error.NotAStruct => "not a struct",
        error.TypeMismatch => "type mismatch",
        error.DivisionByZero => "division by zero",
        error.Syntax => "syntax error",
        else => @errorName(err),
    };
}

fn split1(s: []const u8) struct { []const u8, []const u8 } {
    const i = std.mem.indexOfAny(u8, s, " \t") orelse return .{ s, "" };
    return .{ s[0..i], std.mem.trim(u8, s[i..], " \t") };
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn isIdent(s: []const u8) bool {
    if (s.len == 0 or !isIdentStart(s[0])) return false;
    for (s) |c| if (!isIdentChar(c)) return false;
    return true;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

const sample =
    \\let x = 1
    \\let s = "hi"
    \\let p = struct{a=1,b="two"}
    \\x = x + 1
    \\print "hello"
    \\print x
    \\fn f
    \\  let y = 10
    \\  x = x * y
    \\end
    \\call f
    \\print p.b
    \\exit 3
;

fn lineOf(p: *Program) usize {
    return p.frames.items[p.frames.items.len - 1].pc + 1;
}

test "parse: every line is a statement; fn bodies are paired with their end" {
    var p = Program.init(t.allocator);
    defer p.deinit();
    try p.load(sample ++ "\n");
    try t.expectEqual(@as(usize, 13), p.stmts.len);
    try t.expectEqualStrings("x", p.stmts[0].let.name);
    try t.expectEqual(@as(i64, 1), p.stmts[0].let.value.int);
    try t.expectEqualStrings("hi", p.stmts[1].let.value.str);
    try t.expectEqualStrings("two", p.stmts[2].let.value.strct[1].value.str);
    try t.expectEqualStrings("x + 1", p.stmts[3].assign.expr);
    try t.expectEqual(@as(usize, 9), p.stmts[6].fn_def.end_index);
    try t.expectEqual(@as(i64, 3), p.stmts[12].exit);
    try t.expect(p.stmts[9] == .end);
    try t.expect(p.isStatementLine(4));
    try t.expect(!p.isStatementLine(7)); // `fn f`
    try t.expect(!p.isStatementLine(14));
}

test "continue without breakpoints runs to exit; output is in order" {
    var p = Program.init(t.allocator);
    defer p.deinit();
    try p.load(sample);
    const out = try p.run(.@"continue");
    try t.expectEqual(@as(i64, 3), out.exited);
    const lines = p.takeOutput();
    try t.expectEqual(@as(usize, 3), lines.len);
    try t.expectEqualStrings("hello\n", lines[0].text);
    try t.expectEqualStrings("2\n", lines[1].text);
    try t.expectEqualStrings("two\n", lines[2].text);
    try t.expectEqualStrings("stdout", lines[0].category);
    try t.expectEqual(@as(i64, 20), p.lookup(0, "x").?.int);
}

test "a breakpoint stops before its line; the same line does not re-fire on resume" {
    var p = Program.init(t.allocator);
    defer p.deinit();
    try p.load(sample);
    const bps = try p.setBreakpoints(&.{ .{ .line = 4 }, .{ .line = 7 }, .{ .line = 99 } });
    try t.expect(bps[0].verified and !bps[1].verified and !bps[2].verified);
    try t.expectEqual(Reason.breakpoint, (try p.run(.@"continue")).stopped);
    try t.expectEqual(@as(usize, 4), lineOf(&p));
    try t.expectEqual(@as(i64, 1), p.lookup(0, "x").?.int);
    try t.expectEqual(@as(i64, 3), (try p.run(.@"continue")).exited);
}

test "conditions skip a breakpoint until true; hit conditions count hits" {
    var p = Program.init(t.allocator);
    defer p.deinit();
    try p.load("let i = 0\nfn loop\n  i = i + 1\nend\ncall loop\ncall loop\ncall loop\ncall loop\ncall loop\nprint i\n");
    _ = try p.setBreakpoints(&.{.{ .line = 3, .condition = "i == 2" }});
    try t.expectEqual(Reason.breakpoint, (try p.run(.@"continue")).stopped);
    try t.expectEqual(@as(i64, 2), p.lookup(1, "i").?.int);
    try t.expectEqual(@as(usize, 2), p.depth());
    try t.expectEqual(@as(i64, 0), (try p.run(.@"continue")).exited);
    // Hit count: `% 2` fires on the 2nd and 4th hit.
    try p.load("let i = 0\nfn loop\n  i = i + 1\nend\ncall loop\ncall loop\ncall loop\ncall loop\ncall loop\nprint i\n");
    _ = try p.setBreakpoints(&.{.{ .line = 3, .hit_condition = "% 2" }});
    try t.expectEqual(Reason.breakpoint, (try p.run(.@"continue")).stopped);
    try t.expectEqual(@as(i64, 1), p.lookup(0, "i").?.int);
    try t.expectEqual(Reason.breakpoint, (try p.run(.@"continue")).stopped);
    try t.expectEqual(@as(i64, 3), p.lookup(0, "i").?.int);
    try t.expectEqual(@as(i64, 0), (try p.run(.@"continue")).exited);
    try t.expect(Program.hitMatches(">= 3", 3) and !Program.hitMatches(">= 3", 2));
    try t.expect(Program.hitMatches("4", 4) and !Program.hitMatches("== 4", 5));
    try t.expect(Program.hitMatches("< 2", 1) and Program.hitMatches("bogus", 7));
}

test "next steps over a call, stepIn enters it, stepOut returns after the call" {
    var p = Program.init(t.allocator);
    defer p.deinit();
    try p.load(sample);
    _ = try p.setBreakpoints(&.{.{ .line = 11 }});
    try t.expectEqual(Reason.breakpoint, (try p.run(.@"continue")).stopped);
    try t.expectEqual(@as(usize, 11), lineOf(&p));
    // stepIn: the function's first line, two frames deep.
    try t.expectEqual(Reason.step, (try p.run(.step_in)).stopped);
    try t.expectEqual(@as(usize, 8), lineOf(&p));
    try t.expectEqual(@as(usize, 2), p.depth());
    try t.expectEqualStrings("f", p.frames.items[1].name);
    try t.expectEqual(@as(usize, 10), p.frames.items[0].pc); // the caller sits on `call f`
    // next inside: one line.
    try t.expectEqual(Reason.step, (try p.run(.next)).stopped);
    try t.expectEqual(@as(usize, 9), lineOf(&p));
    try t.expectEqual(@as(i64, 10), p.lookup(1, "y").?.int);
    // stepOut: back in main, after the call.
    try t.expectEqual(Reason.step, (try p.run(.step_out)).stopped);
    try t.expectEqual(@as(usize, 12), lineOf(&p));
    try t.expectEqual(@as(usize, 1), p.depth());
    try t.expectEqual(@as(i64, 20), p.lookup(0, "x").?.int);
    // next over `print p.b` then `exit`.
    try t.expectEqual(Reason.step, (try p.run(.next)).stopped);
    try t.expectEqual(@as(usize, 13), lineOf(&p));
    try t.expectEqual(@as(i64, 3), (try p.run(.next)).exited);
    // A fresh program: next over the call runs the whole body.
    try p.load(sample);
    _ = try p.setBreakpoints(&.{.{ .line = 11 }});
    _ = try p.run(.@"continue");
    try t.expectEqual(Reason.step, (try p.run(.next)).stopped);
    try t.expectEqual(@as(usize, 12), lineOf(&p));
    try t.expectEqual(@as(i64, 20), p.lookup(0, "x").?.int);
}

test "throw: uncaught stops by default and ends the program with 1 on resume; in a function it unwinds to the caller" {
    var p = Program.init(t.allocator);
    defer p.deinit();
    try p.load("print \"a\"\nthrow \"boom\"\nprint \"b\"\n");
    const out = try p.run(.@"continue");
    try t.expectEqual(Reason.exception, out.stopped);
    try t.expectEqual(@as(usize, 2), lineOf(&p));
    try t.expectEqualStrings("boom", p.last_throw);
    const lines = p.takeOutput();
    try t.expectEqual(@as(usize, 2), lines.len);
    try t.expectEqualStrings("throw: boom\n", lines[1].text);
    try t.expectEqualStrings("stderr", lines[1].category);
    try t.expectEqual(@as(i64, 1), (try p.run(.@"continue")).exited);
    try t.expectEqualStrings("uncaught: boom\n", p.takeOutput()[0].text);
    // With no filters an uncaught throw just ends the program.
    try p.load("throw \"boom\"\nprint \"b\"\n");
    p.setExceptionFilters(&.{});
    try t.expectEqual(@as(i64, 1), (try p.run(.@"continue")).exited);
    // In a function: caught by the caller — `error` stops on it, `uncaught` does not.
    try p.load("fn f\n  throw \"inner\"\n  print \"never\"\nend\ncall f\nprint \"after\"\n");
    p.setExceptionFilters(&.{"uncaught"});
    try t.expectEqual(@as(i64, 0), (try p.run(.@"continue")).exited);
    const o2 = p.takeOutput();
    try t.expectEqual(@as(usize, 2), o2.len);
    try t.expectEqualStrings("after\n", o2[1].text);
    try p.load("fn f\n  throw \"inner\"\n  print \"never\"\nend\ncall f\nprint \"after\"\n");
    p.setExceptionFilters(&.{ "error", "uncaught" });
    try t.expectEqual(Reason.exception, (try p.run(.@"continue")).stopped);
    try t.expectEqual(@as(usize, 2), lineOf(&p));
    try t.expectEqual(Reason.step, (try p.run(.next)).stopped);
    try t.expectEqual(@as(usize, 6), lineOf(&p));
    try t.expectEqual(@as(usize, 1), p.depth());
}

test "sleep runs until pause; the stop is on the sleep line and next moves past it" {
    var p = Program.init(t.allocator);
    defer p.deinit();
    try p.load("let x = 1\nsleep\nprint x\n");
    try t.expect((try p.run(.@"continue")) == .sleeping);
    try t.expect(p.pause() != null);
    try t.expectEqual(@as(usize, 2), lineOf(&p));
    try t.expect(p.pause() == null);
    try t.expectEqual(Reason.step, (try p.run(.next)).stopped);
    try t.expectEqual(@as(usize, 3), lineOf(&p));
    try t.expectEqual(@as(i64, 0), (try p.run(.@"continue")).exited);
}

test "evaluate: arithmetic, comparison, fields, strings, errors; setVar on a scope and a struct field" {
    var p = Program.init(t.allocator);
    defer p.deinit();
    try p.load(sample);
    _ = try p.setBreakpoints(&.{.{ .line = 12 }});
    _ = try p.run(.@"continue");
    try t.expectEqual(@as(i64, 21), (try p.evaluate("x + 1", 0)).int);
    try t.expectEqual(@as(i64, 1), (try p.evaluate("x > 3", 0)).int);
    try t.expectEqual(@as(i64, 0), (try p.evaluate("x == 3", 0)).int);
    try t.expectEqual(@as(i64, 7), (try p.evaluate("(1 + 2) * 2 + x / 20", 0)).int);
    try t.expectEqualStrings("two", (try p.evaluate("p.b", 0)).str);
    try t.expectEqual(@as(i64, 1), (try p.evaluate("s == \"hi\"", 0)).int);
    try t.expectError(error.NoSuchVariable, p.evaluate("nope", 0));
    try t.expectError(error.NoSuchField, p.evaluate("p.zz", 0));
    try t.expectError(error.NotAStruct, p.evaluate("x.a", 0));
    try t.expectError(error.DivisionByZero, p.evaluate("1 / 0", 0));
    try t.expectError(error.TypeMismatch, p.evaluate("s + 1", 0));
    try t.expectError(error.Syntax, p.evaluate("1 +", 0));
    try t.expectEqualStrings("{a=1, b=\"two\"}", try (try p.evaluate("p", 0)).render(p.arena()));
    // setVar: a scope by reference, then a struct field by its ref.
    const v = try p.setVar(Program.localsRef(0), "x", "x * 2");
    try t.expectEqual(@as(i64, 40), v.int);
    try t.expectEqual(@as(i64, 40), p.lookup(0, "x").?.int);
    try t.expectError(error.NoSuchVariable, p.setVar(Program.localsRef(0), "nope", "1"));
    const ref = try p.structRef(0, "p");
    try t.expectEqual(@as(i64, 1000), ref);
    _ = try p.setVar(ref, "a", "5");
    try t.expectEqual(@as(i64, 5), (try p.evaluate("p.a", 0)).int);
    try t.expectError(error.NoSuchField, p.setVar(ref, "zz", "5"));
    // Globals from inside a function are main's variables.
    try t.expect(p.scopeVars(Program.globalsRef(0)) == &p.frames.items[0].vars);
    try t.expect(p.scopeVars(Program.localsRef(3)) == null);
}

test "a line that does not parse is an error stop when reached, not before" {
    var p = Program.init(t.allocator);
    defer p.deinit();
    try p.load("print \"ok\"\nfrobnicate 12\nprint \"after\"\n");
    try t.expect(p.stmts[1] == .bad);
    try t.expectEqual(Reason.exception, (try p.run(.@"continue")).stopped);
    try t.expectEqual(@as(usize, 2), lineOf(&p));
    const lines = p.takeOutput();
    try t.expectEqualStrings("error: line 2: unknown statement\n", lines[1].text);
    try t.expectEqual(@as(i64, 1), (try p.run(.@"continue")).exited);
}
