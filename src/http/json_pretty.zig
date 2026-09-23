//! A JSON re-indenter that never re-prints a value. `std.json`'s
//! parse-then-stringify goes through `f64` for every number (`5.0` →
//! `5`, `1.10` → `1.1`, `1E5` → `100000`, the tail of a long decimal
//! gone) and re-escapes strings; a pretty-printer only has to move
//! whitespace. `pretty` checks the text is JSON, then copies every
//! string, number and literal token byte for byte and lays the
//! structure out two spaces deep — `{}` / `[]` stay compact.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `text` re-indented, owned; null when it is not one JSON value.
pub fn pretty(alloc: Allocator, text: []const u8) Allocator.Error!?[]u8 {
    const valid = std.json.validate(alloc, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (!valid) return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var depth: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            ' ', '\t', '\r', '\n' => i += 1,
            '"' => {
                const end = stringEnd(text, i);
                try out.appendSlice(alloc, text[i..end]);
                i = end;
            },
            '{', '[' => {
                const close: u8 = if (c == '{') '}' else ']';
                const next = skipWs(text, i + 1);
                if (next < text.len and text[next] == close) {
                    try out.append(alloc, c);
                    try out.append(alloc, close);
                    i = next + 1;
                    continue;
                }
                try out.append(alloc, c);
                depth += 1;
                try newline(alloc, &out, depth);
                i += 1;
            },
            '}', ']' => {
                depth -|= 1;
                try newline(alloc, &out, depth);
                try out.append(alloc, c);
                i += 1;
            },
            ',' => {
                try out.append(alloc, ',');
                try newline(alloc, &out, depth);
                i += 1;
            },
            ':' => {
                try out.appendSlice(alloc, ": ");
                i += 1;
            },
            else => {
                // A number or a literal: up to the next delimiter, as written.
                var end = i;
                while (end < text.len and std.mem.indexOfScalar(u8, " \t\r\n,:]}", text[end]) == null) end += 1;
                try out.appendSlice(alloc, text[i..end]);
                i = end;
            },
        }
    }
    return try out.toOwnedSlice(alloc);
}

fn newline(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), depth: usize) Allocator.Error!void {
    try out.append(alloc, '\n');
    try out.appendNTimes(alloc, ' ', depth * 2);
}

fn skipWs(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and std.mem.indexOfScalar(u8, " \t\r\n", text[i]) != null) i += 1;
    return i;
}

/// The index just past the string starting at `start` (its `"`).
fn stringEnd(text: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
            continue;
        }
        if (text[i] == '"') return i + 1;
    }
    return text.len;
}

const testing = std.testing;

test "pretty: numbers and strings keep their bytes; the structure is two-space indented" {
    const out = (try pretty(testing.allocator, "{\"f\": 5.0, \"price\": 1.10, \"exp\": 1E5, \"pi\": 3.141592653589793238, \"s\": \"a\\\"b, c: {d}\", \"e\": {}, \"l\": [1, [], null, true]}")).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\{
        \\  "f": 5.0,
        \\  "price": 1.10,
        \\  "exp": 1E5,
        \\  "pi": 3.141592653589793238,
        \\  "s": "a\"b, c: {d}",
        \\  "e": {},
        \\  "l": [
        \\    1,
        \\    [],
        \\    null,
        \\    true
        \\  ]
        \\}
    , out);
    // Already pretty: unchanged.
    const again = (try pretty(testing.allocator, out)).?;
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(out, again);
    // An escape stays as written, not decoded and re-encoded.
    const esc = (try pretty(testing.allocator, "[\"\\u00e9\"]")).?;
    defer testing.allocator.free(esc);
    try testing.expectEqualStrings("[\n  \"\\u00e9\"\n]", esc);
    try testing.expect((try pretty(testing.allocator, "{\"a\": 1,")) == null);
    try testing.expect((try pretty(testing.allocator, "not json")) == null);
    const scalar = (try pretty(testing.allocator, " 10.50 ")).?;
    defer testing.allocator.free(scalar);
    try testing.expectEqualStrings("10.50", scalar);
}
