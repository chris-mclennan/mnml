//! How the browser pane writes a CDP `RemoteObject` and a console call,
//! the way DevTools' console does: strings bare at the top level and
//! quoted inside an object, an object or array from its `preview`
//! (`{a: 1, b: Object, s: "str"}`, `[1, 2, 3]`), the rest from their
//! `description` / `unserializableValue`; and the format specifiers of
//! a first string argument applied (`%s %d %i %f %o %O %c %%`), `%c`'s
//! CSS dropped rather than printed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

fn field(v: Value, name: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(name);
}

fn fieldStr(v: Value, name: []const u8) ?[]const u8 {
    const x = field(v, name) orelse return null;
    return if (x == .string) x.string else null;
}

/// One remote object as text. `quoted`: a string is written in double
/// quotes (inside a preview); a top-level console argument is not.
pub fn objectText(arena: Allocator, v: Value, quoted: bool) Allocator.Error![]const u8 {
    if (v != .object) return std.json.Stringify.valueAlloc(arena, v, .{});
    const ty = fieldStr(v, "type") orelse "";
    if (fieldStr(v, "unserializableValue")) |u| return u;
    if (std.mem.eql(u8, ty, "undefined")) return "undefined";
    if (std.mem.eql(u8, ty, "string")) {
        const s = fieldStr(v, "value") orelse "";
        return if (quoted) std.fmt.allocPrint(arena, "\"{s}\"", .{s}) else s;
    }
    if (fieldStr(v, "subtype")) |st| if (std.mem.eql(u8, st, "null")) return "null";
    if (field(v, "preview")) |pv| if (pv == .object) return previewText(arena, pv, fieldStr(v, "description"));
    if (field(v, "value")) |val| return switch (val) {
        .string => |s| if (quoted) std.fmt.allocPrint(arena, "\"{s}\"", .{s}) else s,
        .object, .array => if (fieldStr(v, "description")) |d| d else std.json.Stringify.valueAlloc(arena, val, .{}),
        else => std.json.Stringify.valueAlloc(arena, val, .{}),
    };
    if (fieldStr(v, "description")) |d| return d;
    return if (ty.len > 0) ty else "?";
}

/// An `ObjectPreview`: `[1, 2]` for an array, `{k: v, …}` for an
/// object, prefixed with its class when that says more than `Object`.
pub fn previewText(arena: Allocator, pv: Value, description: ?[]const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const subtype = fieldStr(pv, "subtype") orelse "";
    const is_array = std.mem.eql(u8, subtype, "array") or std.mem.eql(u8, subtype, "typedarray");
    const desc = description orelse fieldStr(pv, "description") orelse "";
    if (is_array) {
        // `Array(3)` says the length the preview may have cut.
        if (desc.len > 0 and !std.mem.startsWith(u8, desc, "Array(")) {
            try out.appendSlice(arena, desc);
            try out.append(arena, ' ');
        }
        try out.append(arena, '[');
    } else {
        if (desc.len > 0 and !std.mem.eql(u8, desc, "Object")) {
            try out.appendSlice(arena, desc);
            try out.append(arena, ' ');
        }
        try out.append(arena, '{');
    }
    var n: usize = 0;
    if (field(pv, "properties")) |props| if (props == .array) for (props.array.items) |prop| {
        if (n > 0) try out.appendSlice(arena, ", ");
        n += 1;
        const name = fieldStr(prop, "name") orelse "?";
        if (!is_array) {
            try out.appendSlice(arena, name);
            try out.appendSlice(arena, ": ");
        }
        const pty = fieldStr(prop, "type") orelse "";
        const val = fieldStr(prop, "value") orelse pty;
        if (std.mem.eql(u8, pty, "string")) {
            try out.append(arena, '"');
            try out.appendSlice(arena, val);
            try out.append(arena, '"');
        } else try out.appendSlice(arena, val);
    };
    const overflow = if (field(pv, "overflow")) |o| o == .bool and o.bool else false;
    if (overflow) try out.appendSlice(arena, if (n > 0) ", …" else "…");
    try out.append(arena, if (is_array) ']' else '}');
    return out.items;
}

/// A console call's text from its `args`: the first string's format
/// specifiers applied, the rest joined by spaces.
pub fn formatArgs(arena: Allocator, args: []const Value) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var next: usize = 0;
    if (args.len > 0 and args[0] == .object and std.mem.eql(u8, fieldStr(args[0], "type") orelse "", "string")) {
        const fmt = fieldStr(args[0], "value") orelse "";
        next = 1;
        var i: usize = 0;
        while (i < fmt.len) : (i += 1) {
            if (fmt[i] != '%' or i + 1 >= fmt.len) {
                try out.append(arena, fmt[i]);
                continue;
            }
            const spec = fmt[i + 1];
            switch (spec) {
                '%' => {
                    try out.append(arena, '%');
                    i += 1;
                },
                's', 'd', 'i', 'f', 'o', 'O', 'c' => {
                    i += 1;
                    if (next >= args.len) {
                        // Nothing left to substitute: DevTools keeps the text.
                        try out.append(arena, '%');
                        try out.append(arena, spec);
                        continue;
                    }
                    const arg = args[next];
                    next += 1;
                    switch (spec) {
                        'c' => {},
                        'd', 'i' => try out.appendSlice(arena, try numberText(arena, arg, true)),
                        'f' => try out.appendSlice(arena, try numberText(arena, arg, false)),
                        else => try out.appendSlice(arena, try objectText(arena, arg, spec != 's')),
                    }
                },
                else => try out.append(arena, '%'),
            }
        }
    }
    for (args[next..]) |a| {
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, try objectText(arena, a, false));
    }
    return out.items;
}

fn numberText(arena: Allocator, v: Value, integer: bool) Allocator.Error![]const u8 {
    const val = field(v, "value") orelse return "NaN";
    const f: f64 = switch (val) {
        .integer => |x| @floatFromInt(x),
        .float => |x| x,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return "NaN",
        .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch return "NaN",
        else => return "NaN",
    };
    if (integer) return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(@trunc(f)))});
    return std.fmt.allocPrint(arena, "{d}", .{f});
}

/// The label a console call's `type` gets: the call the developer wrote
/// (`console.warn`), not Chrome's enum (`warning`).
pub fn callName(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "warning")) return "warn";
    if (std.mem.eql(u8, kind, "startGroup")) return "group";
    if (std.mem.eql(u8, kind, "startGroupCollapsed")) return "groupCollapsed";
    if (std.mem.eql(u8, kind, "endGroup")) return "groupEnd";
    return kind;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn parse(arena: Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{});
}

test "objects and arrays come from their preview, strings bare at the top and quoted inside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const obj = try parse(a,
        \\{"type":"object","className":"Object","description":"Object","preview":{"type":"object","description":"Object","overflow":false,
        \\ "properties":[{"name":"a","type":"number","value":"1"},{"name":"b","type":"object","value":"Object"},{"name":"s","type":"string","value":"str"}]}}
    );
    try testing.expectEqualStrings("{a: 1, b: Object, s: \"str\"}", try objectText(a, obj, false));
    const arr = try parse(a,
        \\{"type":"object","subtype":"array","description":"Array(3)","preview":{"type":"object","subtype":"array","description":"Array(3)","overflow":false,
        \\ "properties":[{"name":"0","type":"number","value":"1"},{"name":"1","type":"number","value":"2"},{"name":"2","type":"number","value":"3"}]}}
    );
    try testing.expectEqualStrings("[1, 2, 3]", try objectText(a, arr, false));
    const cut = try parse(a,
        \\{"type":"object","className":"Foo","description":"Foo","preview":{"type":"object","description":"Foo","overflow":true,"properties":[{"name":"x","type":"number","value":"1"}]}}
    );
    try testing.expectEqualStrings("Foo {x: 1, …}", try objectText(a, cut, false));
    try testing.expectEqualStrings("hi", try objectText(a, try parse(a, "{\"type\":\"string\",\"value\":\"hi\"}"), false));
    try testing.expectEqualStrings("\"hi\"", try objectText(a, try parse(a, "{\"type\":\"string\",\"value\":\"hi\"}"), true));
    try testing.expectEqualStrings("undefined", try objectText(a, try parse(a, "{\"type\":\"undefined\"}"), false));
    try testing.expectEqualStrings("null", try objectText(a, try parse(a, "{\"type\":\"object\",\"subtype\":\"null\",\"value\":null}"), false));
    try testing.expectEqualStrings("NaN", try objectText(a, try parse(a, "{\"type\":\"number\",\"unserializableValue\":\"NaN\",\"description\":\"NaN\"}"), false));
    try testing.expectEqualStrings("() => 1", try objectText(a, try parse(a, "{\"type\":\"function\",\"className\":\"Function\",\"description\":\"() => 1\"}"), false));
    try testing.expectEqualStrings("Symbol(s)", try objectText(a, try parse(a, "{\"type\":\"symbol\",\"description\":\"Symbol(s)\"}"), false));
}

test "format specifiers: %s %d %i %f %%, %c's CSS dropped, extra args appended, a lone % kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rate = try parse(a, "[{\"type\":\"string\",\"value\":\"%s is %d%%\"},{\"type\":\"string\",\"value\":\"rate\"},{\"type\":\"number\",\"value\":5}]");
    try testing.expectEqualStrings("rate is 5%", try formatArgs(a, rate.array.items));
    const styled = try parse(a, "[{\"type\":\"string\",\"value\":\"%cstyled\"},{\"type\":\"string\",\"value\":\"color:red\"}]");
    try testing.expectEqualStrings("styled", try formatArgs(a, styled.array.items));
    const mixed = try parse(a, "[{\"type\":\"string\",\"value\":\"info line\"},{\"type\":\"number\",\"value\":42},{\"type\":\"boolean\",\"value\":true},{\"type\":\"object\",\"subtype\":\"null\",\"value\":null},{\"type\":\"undefined\"}]");
    try testing.expectEqualStrings("info line 42 true null undefined", try formatArgs(a, mixed.array.items));
    const floats = try parse(a, "[{\"type\":\"string\",\"value\":\"%i / %f / 100%\"},{\"type\":\"number\",\"value\":3.7},{\"type\":\"number\",\"value\":2.5}]");
    try testing.expectEqualStrings("3 / 2.5 / 100%", try formatArgs(a, floats.array.items));
    const short = try parse(a, "[{\"type\":\"string\",\"value\":\"%s and %s\"},{\"type\":\"string\",\"value\":\"one\"}]");
    try testing.expectEqualStrings("one and %s", try formatArgs(a, short.array.items));
    const obj_first = try parse(a, "[{\"type\":\"number\",\"value\":1},{\"type\":\"string\",\"value\":\"%s\"}]");
    try testing.expectEqualStrings("1 %s", try formatArgs(a, obj_first.array.items));
    try testing.expectEqualStrings("warn", callName("warning"));
    try testing.expectEqualStrings("log", callName("log"));
}
