//! The Debug Adapter Protocol's nouns as mnml-zig keeps them: what a
//! session snapshot holds after a stop (frames, scopes, threads, the
//! variables cache), what the app owns across sessions (breakpoints,
//! watches), and what the REPL / debug panes render.
//!
//! Ownership is spelled by the type (D1): `[]u8` fields are gpa-owned
//! and freed by the holder's `deinit`; `[]const u8` fields borrow from a
//! session's snapshot arena and go when the next stop replaces it.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A breakpoint on a 0-based line of one file. The app keeps them per
/// absolute path so they outlive the buffer showing the file.
pub const Breakpoint = struct {
    line: u32,
    /// DAP `condition` — stop only when it is true. Owned.
    condition: ?[]u8 = null,
    /// DAP `hitCondition` — `>= 5`, `% 10`. Owned.
    hit_condition: ?[]u8 = null,
    /// DAP `logMessage` — a logpoint: the adapter prints it instead of
    /// stopping. Owned.
    log_message: ?[]u8 = null,
    /// A disabled breakpoint stays in the list (its condition kept) and
    /// is left out of what the adapter is sent.
    enabled: bool = true,
    /// The adapter's `verified` from the last `setBreakpoints` reply;
    /// null until one lands (or while disabled).
    verified: ?bool = null,

    pub fn deinit(self: *Breakpoint, gpa: Allocator) void {
        if (self.condition) |c| gpa.free(c);
        if (self.hit_condition) |h| gpa.free(h);
        if (self.log_message) |l| gpa.free(l);
        self.* = undefined;
    }

    /// The gutter's word for it: a plain stop, a conditional one (a
    /// condition or a hit count), a logpoint.
    pub fn kind(self: *const Breakpoint) enum { plain, conditional, log } {
        if (self.log_message != null) return .log;
        if (self.condition != null or self.hit_condition != null) return .conditional;
        return .plain;
    }
};

pub const FileBreakpoints = std.ArrayListUnmanaged(Breakpoint);

/// A frame of the stopped thread's stack (snapshot-borrowed).
pub const StackFrame = struct {
    id: i64,
    name: []const u8,
    /// Absolute path when the adapter named one.
    source: ?[]const u8,
    /// 1-based, as the wire has it (`linesStartAt1`).
    line: u32,
    column: u32,
};

pub const Scope = struct {
    name: []const u8,
    variables_reference: i64,
    expensive: bool,
};

pub const Thread = struct {
    id: i64,
    name: []const u8,
};

/// One exception-breakpoint filter the adapter advertised. Owned by the
/// session (they arrive once, with `initialize`'s reply).
pub const ExceptionFilter = struct {
    filter: []u8,
    label: []u8,
    default: bool,

    pub fn deinit(self: *ExceptionFilter, gpa: Allocator) void {
        gpa.free(self.filter);
        gpa.free(self.label);
    }
};

/// A variable under a scope or a composite parent; borrows the session's
/// variables arena (reset when the program resumes — references go
/// stale across a continue).
pub const Variable = struct {
    name: []const u8,
    value: []const u8,
    ty: ?[]const u8,
    /// Non-zero: composite; its children are another `variables` request.
    variables_reference: i64,
};

/// The flattened variables tree the debug pane paints: scope headers
/// and the expanded rows under them. Built on the frame arena.
pub const VarRow = struct {
    depth: u8,
    is_scope: bool,
    /// `name: type` for a variable, the scope's name for a scope.
    label: []const u8,
    name: []const u8,
    value: []const u8,
    var_ref: i64,
    expanded: bool,
    expandable: bool,
    /// The reference `setVariable` addresses; 0 for a scope row.
    parent_ref: i64,
};

/// One line the debuggee (or the adapter) printed. Owned.
pub const OutputLine = struct {
    category: []u8,
    text: []u8,

    pub fn deinit(self: *OutputLine, gpa: Allocator) void {
        gpa.free(self.category);
        gpa.free(self.text);
    }
};

/// A watch's last evaluation. Owned.
pub const WatchResult = struct {
    value: []u8,
    ty: ?[]u8,
    err: ?[]u8,

    pub fn deinit(self: *WatchResult, gpa: Allocator) void {
        gpa.free(self.value);
        if (self.ty) |t| gpa.free(t);
        if (self.err) |e| gpa.free(e);
    }
};

/// One row of the REPL's history: the expression and what came back.
/// Owned by the REPL pane.
pub const ReplEntry = struct {
    expression: []u8,
    value: []u8 = &.{},
    ty: ?[]u8 = null,
    err: ?[]u8 = null,
    /// Waiting on the adapter; paints `(evaluating…)`.
    pending: bool = false,
    /// Non-zero: the result is composite and `o` expands it.
    variables_ref: i64 = 0,
    expanded: bool = false,

    pub fn deinit(self: *ReplEntry, gpa: Allocator) void {
        gpa.free(self.expression);
        gpa.free(self.value);
        if (self.ty) |t| gpa.free(t);
        if (self.err) |e| gpa.free(e);
    }

    /// Replace the result fields (the expression stays).
    pub fn setResult(self: *ReplEntry, gpa: Allocator, value: []const u8, ty: ?[]const u8, err: ?[]const u8, variables_ref: i64) Allocator.Error!void {
        const v = try gpa.dupe(u8, value);
        errdefer gpa.free(v);
        const t: ?[]u8 = if (ty) |x| try gpa.dupe(u8, x) else null;
        errdefer if (t) |x| gpa.free(x);
        const e: ?[]u8 = if (err) |x| try gpa.dupe(u8, x) else null;
        gpa.free(self.value);
        if (self.ty) |x| gpa.free(x);
        if (self.err) |x| gpa.free(x);
        self.value = v;
        self.ty = t;
        self.err = e;
        self.variables_ref = variables_ref;
        self.pending = false;
    }
};

/// Why the debuggee stopped. Owned by the session.
pub const Stopped = struct {
    thread_id: i64,
    reason: []u8,
    /// DAP: the full reason, shown as-is — an exception's message.
    description: ?[]u8,
    /// DAP: "additional information … e.g. the exception name" —
    /// `ZeroDivisionError`, `ValueError`; what a reader looks for first.
    text: ?[]u8,
    /// What the toast and the status row say, built once by `init`:
    /// `text: description`, either alone, else the reason.
    label_text: []u8,

    pub fn init(gpa: Allocator, thread_id: i64, reason: []const u8, description: ?[]const u8, text: ?[]const u8) Allocator.Error!Stopped {
        const r = try gpa.dupe(u8, reason);
        errdefer gpa.free(r);
        const d: ?[]u8 = if (description) |x| (if (x.len > 0) try gpa.dupe(u8, x) else null) else null;
        errdefer if (d) |x| gpa.free(x);
        const t: ?[]u8 = if (text) |x| (if (x.len > 0) try gpa.dupe(u8, x) else null) else null;
        errdefer if (t) |x| gpa.free(x);
        const l: []u8 = if (t != null and d != null and !std.mem.eql(u8, t.?, d.?))
            try std.fmt.allocPrint(gpa, "{s}: {s}", .{ t.?, d.? })
        else
            try gpa.dupe(u8, t orelse d orelse reason);
        return .{ .thread_id = thread_id, .reason = r, .description = d, .text = t, .label_text = l };
    }

    pub fn deinit(self: *Stopped, gpa: Allocator) void {
        gpa.free(self.reason);
        if (self.description) |d| gpa.free(d);
        if (self.text) |t| gpa.free(t);
        gpa.free(self.label_text);
    }

    pub fn label(self: *const Stopped) []const u8 {
        return self.label_text;
    }
};

test "Stopped.label: the exception's type with its message, either alone, else the reason" {
    const gpa = std.testing.allocator;
    var both = try Stopped.init(gpa, 1, "exception", "division by zero", "ZeroDivisionError");
    defer both.deinit(gpa);
    try std.testing.expectEqualStrings("ZeroDivisionError: division by zero", both.label());
    var text_only = try Stopped.init(gpa, 1, "exception", null, "SystemExit");
    defer text_only.deinit(gpa);
    try std.testing.expectEqualStrings("SystemExit", text_only.label());
    var desc_only = try Stopped.init(gpa, 1, "breakpoint", "breakpoint 1.1", null);
    defer desc_only.deinit(gpa);
    try std.testing.expectEqualStrings("breakpoint 1.1", desc_only.label());
    var bare = try Stopped.init(gpa, 1, "step", "", "");
    defer bare.deinit(gpa);
    try std.testing.expectEqualStrings("step", bare.label());
    // The same word twice is said once.
    var same = try Stopped.init(gpa, 1, "exception", "boom", "boom");
    defer same.deinit(gpa);
    try std.testing.expectEqualStrings("boom", same.label());
}

test "ReplEntry.setResult replaces every result field and clears pending" {
    const gpa = std.testing.allocator;
    var e: ReplEntry = .{ .expression = try gpa.dupe(u8, "x"), .pending = true };
    defer e.deinit(gpa);
    try e.setResult(gpa, "42", "i32", null, 0);
    try std.testing.expectEqualStrings("42", e.value);
    try std.testing.expectEqualStrings("i32", e.ty.?);
    try std.testing.expect(!e.pending);
    try e.setResult(gpa, "", null, "no such variable", 0);
    try std.testing.expectEqualStrings("no such variable", e.err.?);
    try std.testing.expect(e.ty == null);
}
