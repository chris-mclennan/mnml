//! The Zig version seam: every std or language spelling that differs
//! between the Zig release this tree builds with and the next one, behind
//! one name each, so moving the toolchain edits this file and not its
//! callers. The app reaches it as `@import("mnml_sdk").zig_compat`, the
//! SDK and the integrations through the SDK. Nothing here is mnml's own
//! behaviour; each name does what the std spelling it replaces did.
//!
//! This copy is written for Zig 0.16.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// This build is unoptimised (`-Doptimize=Debug`).
pub const is_debug = builtin.mode == .Debug;

// ── reflection ──────────────────────────────────────────────────────────

/// One field of a struct or a union, the same shape whichever release
/// reflects it.
pub const Field = struct {
    name: [:0]const u8,
    type: type,
    is_comptime: bool = false,
    default_value_ptr: ?*const anyopaque = null,

    /// The field's default value, null when it has none.
    pub inline fn defaultValue(comptime f: Field) ?f.type {
        const dp: *const f.type = @ptrCast(@alignCast(f.default_value_ptr orelse return null));
        return dp.*;
    }
};

/// One named value of an enum.
pub const EnumField = struct {
    name: [:0]const u8,
    value: comptime_int,
};

/// The fields of struct `T`, in declaration order.
pub inline fn structFields(comptime T: type) []const Field {
    return comptime blk: {
        const info = @typeInfo(T).@"struct";
        var out: [info.fields.len]Field = undefined;
        for (&out, info.fields) |*o, f| {
            o.* = .{ .name = f.name, .type = f.type, .is_comptime = f.is_comptime, .default_value_ptr = f.default_value_ptr };
        }
        const final = out;
        break :blk &final;
    };
}

/// The fields of union `T`, in declaration order.
pub inline fn unionFields(comptime T: type) []const Field {
    return comptime blk: {
        const info = @typeInfo(T).@"union";
        var out: [info.fields.len]Field = undefined;
        for (&out, info.fields) |*o, f| o.* = .{ .name = f.name, .type = f.type };
        const final = out;
        break :blk &final;
    };
}

/// The fields of `T`, a struct or a union.
pub inline fn fields(comptime T: type) []const Field {
    return switch (@typeInfo(T)) {
        .@"struct" => structFields(T),
        .@"union" => unionFields(T),
        else => @compileError("fields: expected a struct or a union, got " ++ @typeName(T)),
    };
}

/// The named values of enum `E`, in declaration order.
pub inline fn enumFields(comptime E: type) []const EnumField {
    return comptime blk: {
        const info = @typeInfo(E).@"enum";
        var out: [info.fields.len]EnumField = undefined;
        for (&out, info.fields) |*o, f| o.* = .{ .name = f.name, .value = f.value };
        const final = out;
        break :blk &final;
    };
}

/// The parameter types of function type `F`, null for an `anytype` one.
pub inline fn fnParamTypes(comptime F: type) []const ?type {
    return comptime blk: {
        const params = @typeInfo(F).@"fn".params;
        var out: [params.len]?type = undefined;
        for (&out, params) |*o, p| o.* = p.type;
        const final = out;
        break :blk &final;
    };
}

/// The per-field attributes `@Struct` takes.
pub const StructFieldAttributes = std.builtin.Type.StructField.Attributes;

// ── syntax ──────────────────────────────────────────────────────────────

/// `repeat("ab", 3)` is `"ababab"`, built at compile time: what `"ab" ** 3`
/// spelled before Zig 0.17 removed array multiplication. The result has the
/// literal's own type, so it concatenates with `++` and coerces to
/// `[]const u8` as the literal did. A repeated non-text value is an
/// `@splat` instead.
pub fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n:0]u8 {
    return comptime blk: {
        @setEvalBranchQuota(1000 + 10 * n);
        var buf: [s.len * n:0]u8 = undefined;
        for (0..n) |i| @memcpy(buf[i * s.len ..][0..s.len], s);
        const final = buf;
        break :blk &final;
    };
}

// ── net ─────────────────────────────────────────────────────────────────

/// What `uriHost` fails with.
pub const UriHostError = std.Uri.GetHostError;

/// The host `uri` names, decoded into `buffer`.
pub fn uriHost(uri: std.Uri, buffer: *[std.Io.net.HostName.max_len]u8) UriHostError!std.Io.net.HostName {
    return uri.getHost(buffer);
}

// ── ZON ─────────────────────────────────────────────────────────────────

/// ZON `src` as a syntax tree, its syntax errors recorded in it.
pub fn parseZonAst(gpa: Allocator, src: [:0]const u8) Allocator.Error!std.zig.Ast {
    return std.zig.Ast.parse(gpa, src, .zon);
}

pub const ZonOptions = struct {
    ignore_unknown_fields: bool = false,
};

/// `x.get(zoir)` for a Zoir node, string or message handle: what it names
/// in that tree.
pub inline fn zoirGet(x: anytype, zoir: *const std.zig.Zoir) @TypeOf(x.get(zoir.*)) {
    return x.get(zoir.*);
}

/// The syntax node a Zoir node came from.
pub inline fn zoirAstNode(node: std.zig.Zoir.Node.Index, zoir: *const std.zig.Zoir) std.zig.Ast.Node.Index {
    return node.getAstNode(zoir.*);
}

/// ZON `src` parsed as a `T`, every allocation — the result's included — on
/// `arena`, so nothing is freed field by field. On `error.ParseZon`, `why`
/// (when given) is the diagnostic: one `line:col: error: message` line per
/// problem, each note under it, as std renders it.
pub fn zonParse(comptime T: type, arena: Allocator, src: [:0]const u8, why: ?*[]const u8, options: ZonOptions) error{ OutOfMemory, ParseZon }!T {
    var diag: std.zon.parse.Diagnostics = .{};
    return std.zon.parse.fromSliceAlloc(T, arena, src, &diag, .{
        .ignore_unknown_fields = options.ignore_unknown_fields,
        .free_on_error = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            if (why) |w| w.* = std.fmt.allocPrint(arena, "{f}", .{diag}) catch "parse error";
            return error.ParseZon;
        },
    };
}

/// Where a ZON value failed to fit its type: 1-based line and column.
pub const ZonProblem = struct { line: u32, column: u32, message: []const u8 };

/// The ZON value at `node` of an already-parsed tree, as a `T`, on `arena`.
/// On `error.ParseZon`, `problem` holds the first problem when std named
/// one (a value of the wrong type) and stays null when it did not.
pub fn zonParseNode(comptime T: type, arena: Allocator, ast: *const std.zig.Ast, zoir: *const std.zig.Zoir, node: std.zig.Zoir.Node.Index, problem: *?ZonProblem) error{ OutOfMemory, ParseZon }!T {
    // `diag` borrows the tree and its message lives on the arena, so it
    // is not deinit'd.
    var diag: std.zon.parse.Diagnostics = .{};
    return std.zon.parse.fromZoirNodeAlloc(T, arena, ast.*, zoir.*, node, &diag, .{ .free_on_error = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            problem.* = if (diag.type_check) |tc| p: {
                const loc = ast.tokenLocation(0, tc.token);
                break :p .{ .line = @intCast(loc.line + 1), .column = @intCast(loc.column + 1 + tc.offset), .message = tc.message };
            } else null;
            return error.ParseZon;
        },
    };
}

test repeat {
    try std.testing.expectEqualStrings("ababab", repeat("ab", 3));
    try std.testing.expectEqualStrings("", repeat("ab", 0));
    try std.testing.expectEqualStrings("x\u{e9}\u{e9}", "x" ++ repeat("\u{e9}", 2));
    const long = repeat(" ", 200);
    try std.testing.expectEqual(@as(usize, 200), long.len);
    try std.testing.expectEqual(@as(u8, 0), long[long.len]);
}

test structFields {
    const S = struct { a: u8 = 7, b: []const u8 };
    const fs = structFields(S);
    try std.testing.expectEqual(@as(usize, 2), fs.len);
    try std.testing.expectEqualStrings("a", fs[0].name);
    try std.testing.expect(fs[1].type == []const u8);
    try std.testing.expectEqual(@as(?u8, 7), comptime fs[0].defaultValue());
    try std.testing.expectEqual(@as(?[]const u8, null), comptime fs[1].defaultValue());
}

test enumFields {
    const E = enum(u8) { x = 3, y = 9 };
    const fs = enumFields(E);
    try std.testing.expectEqualStrings("y", fs[1].name);
    try std.testing.expectEqual(9, fs[1].value);
}

test zonParse {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const P = struct { x: u32, name: []const u8 = "" };
    const p = try zonParse(P, a, ".{ .x = 4, .name = \"hi\" }", null, .{});
    try std.testing.expectEqual(@as(u32, 4), p.x);
    var why: []const u8 = "";
    try std.testing.expectError(error.ParseZon, zonParse(P, a, ".{ .x = \"no\" }", &why, .{}));
    try std.testing.expect(std.mem.startsWith(u8, why, "1:"));
    try std.testing.expect(std.mem.indexOf(u8, why, "error: ") != null);
    try std.testing.expectError(error.ParseZon, zonParse(P, a, ".{ .x = 1, .z = 2 }", null, .{}));
    _ = try zonParse(P, a, ".{ .x = 1, .z = 2 }", null, .{ .ignore_unknown_fields = true });
}
