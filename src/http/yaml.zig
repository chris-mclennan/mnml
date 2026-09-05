//! A YAML reader for OpenAPI specs — the subset those files use, into
//! `std.json.Value`: block mappings and sequences by indentation,
//! plain / 'single' / "double" scalars, `|` and `>` block scalars,
//! one-line flow `[a, b]` / `{k: v}`, `#` comments, a leading `---`.
//! Not read: anchors / aliases, tags, multi-document files (the first
//! document wins), complex keys. A spec that needs those is better
//! served as JSON (`mnml-zig discover` tries JSON first).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Error = error{ BadIndent, BadScalar, Unexpected } || Allocator.Error;

const Line = struct { indent: usize, text: []const u8 };

pub fn parse(arena: Allocator, src: []const u8) Error!Value {
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    var seen_doc = false;
    while (it.next()) |raw| {
        const no_cr = std.mem.trimEnd(u8, raw, "\r");
        const stripped = stripComment(no_cr);
        const trimmed = std.mem.trimEnd(u8, stripped, " \t");
        if (std.mem.trim(u8, trimmed, " \t").len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "---")) {
            if (seen_doc) break;
            seen_doc = true;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "...")) break;
        if (std.mem.startsWith(u8, trimmed, "%")) continue;
        var indent: usize = 0;
        while (indent < trimmed.len and trimmed[indent] == ' ') indent += 1;
        try lines.append(arena, .{ .indent = indent, .text = trimmed[indent..] });
    }
    if (lines.items.len == 0) return .null;
    var p: Parser = .{ .arena = arena, .lines = lines.items, .raw = src };
    return p.block(lines.items[0].indent);
}

/// Drop a ` #…` comment that is not inside quotes.
fn stripComment(line: []const u8) []const u8 {
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote) |q| {
            if (c == '\\' and q == '"') {
                i += 1;
                continue;
            }
            if (c == q) quote = null;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c == '#' and (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t')) return line[0..i];
    }
    return line;
}

const Parser = struct {
    arena: Allocator,
    lines: []const Line,
    raw: []const u8,
    pos: usize = 0,

    fn peek(self: *Parser) ?Line {
        return if (self.pos < self.lines.len) self.lines[self.pos] else null;
    }

    /// A mapping or a sequence whose entries sit at `indent`.
    fn block(self: *Parser, indent: usize) Error!Value {
        const first = self.peek() orelse return .null;
        if (isSeqItem(first.text)) return self.sequence(indent);
        return self.mapping(indent);
    }

    fn isSeqItem(text: []const u8) bool {
        return text.len > 0 and text[0] == '-' and (text.len == 1 or text[1] == ' ');
    }

    fn sequence(self: *Parser, indent: usize) Error!Value {
        var arr: std.json.Array = .init(self.arena);
        while (self.peek()) |line| {
            if (line.indent != indent or !isSeqItem(line.text)) break;
            const rest = std.mem.trimStart(u8, line.text[1..], " ");
            if (rest.len == 0) {
                self.pos += 1;
                const next = self.peek() orelse {
                    try arr.append(.null);
                    break;
                };
                try arr.append(if (next.indent > indent) try self.block(next.indent) else .null);
                continue;
            }
            // `- key: value` starts a mapping whose keys sit two columns in.
            if (looksLikeMapEntry(rest)) {
                const inner_indent = indent + (line.text.len - rest.len);
                // Rewrite the line in place as a mapping entry at the deeper indent.
                const rewritten: Line = .{ .indent = inner_indent, .text = rest };
                const saved = self.lines;
                var copy = try self.arena.dupe(Line, self.lines);
                copy[self.pos] = rewritten;
                self.lines = copy;
                const v = try self.mapping(inner_indent);
                // The mapping consumed its lines from the copy; keep the copy.
                _ = saved;
                try arr.append(v);
                continue;
            }
            self.pos += 1;
            try arr.append(try self.scalarOrBlock(rest, indent));
        }
        return .{ .array = arr };
    }

    fn looksLikeMapEntry(text: []const u8) bool {
        if (text.len == 0 or text[0] == '[' or text[0] == '{' or text[0] == '"' or text[0] == '\'') {
            if (text.len > 0 and (text[0] == '"' or text[0] == '\'')) {
                // "quoted key": value
                const q = text[0];
                const close = std.mem.indexOfScalarPos(u8, text, 1, q) orelse return false;
                const after = std.mem.trimStart(u8, text[close + 1 ..], " ");
                return after.len > 0 and after[0] == ':' and (after.len == 1 or after[1] == ' ');
            }
            return false;
        }
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == ':' and (i + 1 == text.len or text[i + 1] == ' ')) return true;
            if (text[i] == ' ' and i + 1 < text.len and text[i + 1] == '#') return false;
        }
        return false;
    }

    fn mapping(self: *Parser, indent: usize) Error!Value {
        var obj: std.json.ObjectMap = .empty;
        while (self.peek()) |line| {
            if (line.indent < indent) break;
            if (line.indent > indent) return error.BadIndent;
            if (isSeqItem(line.text)) break;
            const split = try splitKey(self.arena, line.text);
            const key = split.key;
            const rest = std.mem.trimStart(u8, split.rest, " ");
            self.pos += 1;
            var value: Value = .null;
            if (rest.len == 0) {
                if (self.peek()) |next| {
                    if (next.indent > indent) {
                        value = try self.block(next.indent);
                    } else if (next.indent == indent and isSeqItem(next.text)) {
                        // A sequence may sit at the parent key's indent.
                        value = try self.sequence(indent);
                    }
                }
            } else value = try self.scalarOrBlock(rest, indent);
            try obj.put(self.arena, key, value);
        }
        return .{ .object = obj };
    }

    const Split = struct { key: []const u8, rest: []const u8 };

    fn splitKey(arena: Allocator, text: []const u8) Error!Split {
        if (text.len > 0 and (text[0] == '"' or text[0] == '\'')) {
            const q = text[0];
            const close = std.mem.indexOfScalarPos(u8, text, 1, q) orelse return error.BadScalar;
            const key = try unquote(arena, text[0 .. close + 1]);
            const after = std.mem.trimStart(u8, text[close + 1 ..], " ");
            if (after.len == 0 or after[0] != ':') return error.Unexpected;
            return .{ .key = key, .rest = after[1..] };
        }
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == ':' and (i + 1 == text.len or text[i + 1] == ' ')) {
                return .{ .key = std.mem.trimEnd(u8, text[0..i], " "), .rest = text[i + 1 ..] };
            }
        }
        return error.Unexpected;
    }

    /// The value after `key:` / `- `: a block scalar marker, a flow
    /// collection, or a scalar.
    fn scalarOrBlock(self: *Parser, rest: []const u8, indent: usize) Error!Value {
        if (rest[0] == '|' or rest[0] == '>') return self.blockScalar(rest[0] == '|', indent);
        if (rest[0] == '[' or rest[0] == '{') {
            var pos: usize = 0;
            return flow(self.arena, rest, &pos);
        }
        return scalar(self.arena, rest);
    }

    /// Lines deeper than `indent`, joined with newlines (`|`) or spaces (`>`).
    fn blockScalar(self: *Parser, literal: bool, indent: usize) Error!Value {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var block_indent: ?usize = null;
        while (self.peek()) |line| {
            if (line.indent <= indent) break;
            if (block_indent == null) block_indent = line.indent;
            self.pos += 1;
            const extra = line.indent - block_indent.?;
            if (out.items.len > 0) try out.append(self.arena, if (literal) '\n' else ' ');
            var pad: usize = 0;
            while (pad < extra) : (pad += 1) try out.append(self.arena, ' ');
            try out.appendSlice(self.arena, line.text);
        }
        return .{ .string = out.items };
    }
};

/// A scalar: quoted, or plain (`true`/`false`/`null`/`~`/numbers/text).
pub fn scalar(arena: Allocator, text_in: []const u8) Error!Value {
    const text = std.mem.trim(u8, text_in, " \t");
    if (text.len == 0) return .null;
    if (text[0] == '"' or text[0] == '\'') return .{ .string = try unquote(arena, text) };
    if (std.mem.eql(u8, text, "~") or std.mem.eql(u8, text, "null") or std.mem.eql(u8, text, "Null") or std.mem.eql(u8, text, "NULL")) return .null;
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "True") or std.mem.eql(u8, text, "TRUE")) return .{ .bool = true };
    if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "False") or std.mem.eql(u8, text, "FALSE")) return .{ .bool = false };
    if (std.fmt.parseInt(i64, text, 10)) |i| return .{ .integer = i } else |_| {}
    if (looksNumeric(text)) {
        if (std.fmt.parseFloat(f64, text)) |f| return .{ .float = f } else |_| {}
    }
    return .{ .string = text };
}

fn looksNumeric(t: []const u8) bool {
    var digits = false;
    for (t, 0..) |c, i| {
        if (std.ascii.isDigit(c)) {
            digits = true;
        } else if (c == '.' or c == 'e' or c == 'E' or ((c == '-' or c == '+') and (i == 0 or t[i - 1] == 'e' or t[i - 1] == 'E'))) {} else return false;
    }
    return digits;
}

fn unquote(arena: Allocator, text: []const u8) Error![]const u8 {
    if (text.len < 2) return error.BadScalar;
    const q = text[0];
    const body = text[1 .. text.len - 1];
    if (q == '\'') {
        // '' is the only escape.
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            if (body[i] == '\'' and i + 1 < body.len and body[i + 1] == '\'') {
                try out.append(arena, '\'');
                i += 1;
            } else try out.append(arena, body[i]);
        }
        return out.items;
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c != '\\' or i + 1 >= body.len) {
            try out.append(arena, c);
            continue;
        }
        i += 1;
        switch (body[i]) {
            'n' => try out.append(arena, '\n'),
            't' => try out.append(arena, '\t'),
            'r' => try out.append(arena, '\r'),
            '"' => try out.append(arena, '"'),
            '\\' => try out.append(arena, '\\'),
            '/' => try out.append(arena, '/'),
            'u' => {
                if (i + 4 >= body.len) return error.BadScalar;
                const cp = std.fmt.parseInt(u21, body[i + 1 .. i + 5], 16) catch return error.BadScalar;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch return error.BadScalar;
                try out.appendSlice(arena, buf[0..n]);
                i += 4;
            },
            else => |o| {
                try out.append(arena, '\\');
                try out.append(arena, o);
            },
        }
    }
    return out.items;
}

/// `[a, b, {k: v}]` / `{k: v, j: [1]}` from `text[pos.*..]`.
fn flow(arena: Allocator, text: []const u8, pos: *usize) Error!Value {
    skipSpaces(text, pos);
    if (pos.* >= text.len) return error.Unexpected;
    const open = text[pos.*];
    if (open == '[') {
        pos.* += 1;
        var arr: std.json.Array = .init(arena);
        while (true) {
            skipSpaces(text, pos);
            if (pos.* >= text.len) return error.Unexpected;
            if (text[pos.*] == ']') {
                pos.* += 1;
                break;
            }
            try arr.append(try flowValue(arena, text, pos));
            skipSpaces(text, pos);
            if (pos.* < text.len and text[pos.*] == ',') pos.* += 1;
        }
        return .{ .array = arr };
    }
    if (open == '{') {
        pos.* += 1;
        var obj: std.json.ObjectMap = .empty;
        while (true) {
            skipSpaces(text, pos);
            if (pos.* >= text.len) return error.Unexpected;
            if (text[pos.*] == '}') {
                pos.* += 1;
                break;
            }
            const key_v = try flowValue(arena, text, pos);
            const key = switch (key_v) {
                .string => |s| s,
                else => try std.json.Stringify.valueAlloc(arena, key_v, .{}),
            };
            skipSpaces(text, pos);
            if (pos.* < text.len and text[pos.*] == ':') pos.* += 1;
            try obj.put(arena, key, try flowValue(arena, text, pos));
            skipSpaces(text, pos);
            if (pos.* < text.len and text[pos.*] == ',') pos.* += 1;
        }
        return .{ .object = obj };
    }
    return flowValue(arena, text, pos);
}

fn flowValue(arena: Allocator, text: []const u8, pos: *usize) Error!Value {
    skipSpaces(text, pos);
    if (pos.* >= text.len) return .null;
    const c = text[pos.*];
    if (c == '[' or c == '{') return flow(arena, text, pos);
    if (c == '"' or c == '\'') {
        var i = pos.* + 1;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\\' and c == '"') {
                i += 1;
                continue;
            }
            if (text[i] == c) break;
        }
        if (i >= text.len) return error.BadScalar;
        const s = text[pos.* .. i + 1];
        pos.* = i + 1;
        return .{ .string = try unquote(arena, s) };
    }
    var end = pos.*;
    while (end < text.len and text[end] != ',' and text[end] != ']' and text[end] != '}' and !(text[end] == ':' and (end + 1 >= text.len or text[end + 1] == ' '))) end += 1;
    const s = text[pos.*..end];
    pos.* = end;
    return scalar(arena, s);
}

fn skipSpaces(text: []const u8, pos: *usize) void {
    while (pos.* < text.len and (text[pos.*] == ' ' or text[pos.*] == '\t')) pos.* += 1;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "an OpenAPI-shaped document: nested maps, sequences, quoted keys, flow, block scalars, comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\# petstore
        \\openapi: 3.0.0
        \\info:
        \\  title: Pets  # inline comment
        \\  description: |
        \\    Two lines
        \\      indented more
        \\  version: '1.0'
        \\servers:
        \\  - url: https://api.example.com/v1
        \\paths:
        \\  /pets/{id}:
        \\    get:
        \\      operationId: getPet
        \\      tags: [pets, "read"]
        \\      parameters:
        \\        - name: id
        \\          in: path
        \\          required: true
        \\          schema: {type: integer, default: 7}
        \\      responses:
        \\        '200':
        \\          description: ok
        \\    post:
        \\      requestBody:
        \\        content:
        \\          application/json:
        \\            example:
        \\              name: "Rex\n"
        \\              tags:
        \\              - a
        \\              - b
        \\              weight: 4.5
        \\              alive: true
        \\              owner: ~
    ;
    const v = try parse(a, src);
    try testing.expectEqualStrings("3.0.0", v.object.get("openapi").?.string);
    const info = v.object.get("info").?.object;
    try testing.expectEqualStrings("Pets", info.get("title").?.string);
    try testing.expectEqualStrings("Two lines\n  indented more", info.get("description").?.string);
    try testing.expectEqualStrings("1.0", info.get("version").?.string);
    try testing.expectEqualStrings("https://api.example.com/v1", v.object.get("servers").?.array.items[0].object.get("url").?.string);
    const get = v.object.get("paths").?.object.get("/pets/{id}").?.object.get("get").?.object;
    try testing.expectEqualStrings("getPet", get.get("operationId").?.string);
    const tags = get.get("tags").?.array;
    try testing.expectEqual(@as(usize, 2), tags.items.len);
    try testing.expectEqualStrings("read", tags.items[1].string);
    const param = get.get("parameters").?.array.items[0].object;
    try testing.expect(param.get("required").?.bool);
    try testing.expectEqual(@as(i64, 7), param.get("schema").?.object.get("default").?.integer);
    try testing.expectEqualStrings("ok", get.get("responses").?.object.get("200").?.object.get("description").?.string);
    const ex = v.object.get("paths").?.object.get("/pets/{id}").?.object.get("post").?.object.get("requestBody").?.object.get("content").?.object.get("application/json").?.object.get("example").?.object;
    try testing.expectEqualStrings("Rex\n", ex.get("name").?.string);
    try testing.expectEqual(@as(usize, 2), ex.get("tags").?.array.items.len);
    try testing.expectEqual(@as(f64, 4.5), ex.get("weight").?.float);
    try testing.expect(ex.get("alive").?.bool);
    try testing.expect(ex.get("owner").? == .null);
}

test "scalars and edge shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("it's", (try scalar(a, "'it''s'")).string);
    try testing.expectEqual(@as(i64, -3), (try scalar(a, "-3")).integer);
    try testing.expectEqualStrings("http://x/y", (try scalar(a, "http://x/y")).string);
    const seq_of_maps = try parse(a, "- a: 1\n  b: 2\n- a: 3\n");
    try testing.expectEqual(@as(usize, 2), seq_of_maps.array.items.len);
    try testing.expectEqual(@as(i64, 2), seq_of_maps.array.items[0].object.get("b").?.integer);
    const folded = try parse(a, "k: >\n  one\n  two\nj: 1\n");
    try testing.expectEqualStrings("one two", folded.object.get("k").?.string);
    try testing.expectEqual(@as(i64, 1), folded.object.get("j").?.integer);
    const empty = try parse(a, "---\n# nothing\n");
    try testing.expect(empty == .null);
    try testing.expectError(error.BadIndent, parse(a, "a: 1\n  b: 2\n   c: 3\n"));
}
