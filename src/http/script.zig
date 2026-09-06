//! Request directives: the `# @…` comment lines inside a request block
//! that run around a send. Three families:
//!
//!   # @set-header Authorization = Bearer {{TOKEN}}   pre-request
//!   # @set-var REQUEST_ID = {{$uuid}}                (also @set-env)
//!   # @set-cookie session = abc
//!   # @assert status == 200                          post-request
//!   # @assert header.Content-Type contains json
//!   # @assert header.X-Trace ~ /^[a-f0-9]+$/
//!   # @assert body.user.id is number                 (also `json $.user.id`)
//!   # @assert body contains hello
//!   # @capture USER_ID = body.user.id                post-request
//!   # @capture TRACE = header X-Request-Id
//!
//! `parse` reads a block's text into a `Script` (every slice on the
//! caller's arena; a line it cannot read is skipped, never fatal).
//! `applyPre` writes the pre-request directives into a `Request` and an
//! `EnvSet` before expansion, so a `@set-var` value is visible to the
//! `{{VAR}}`s that follow. `runAsserts` / `runCaptures` read a finished
//! response. `matchRegex` is the small matcher behind `~`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const parse_mod = @import("parse.zig");
const env_mod = @import("env.zig");

pub const Header = parse_mod.Header;

/// Where an assertion or capture reads from.
pub const Source = union(enum) {
    status,
    body,
    /// A JSON path into the body (`user.id`, `$.items[0].name`).
    body_path: []const u8,
    /// A response header, matched case-insensitively.
    header: []const u8,
};

pub const Op = enum { eq, ne, lt, le, gt, ge, contains, matches, is_type };

pub const KV = struct { name: []const u8, value: []const u8 };

pub const Pre = union(enum) { set_header: KV, set_var: KV, set_cookie: KV };

pub const Assert = struct {
    source: Source,
    op: Op,
    value: []const u8,
    /// The directive text after `@assert `, for the Tests row.
    label: []const u8,
};

pub const Capture = struct { name: []const u8, source: Source };

pub const Script = struct {
    pre: []const Pre = &.{},
    asserts: []const Assert = &.{},
    captures: []const Capture = &.{},

    pub fn isEmpty(s: Script) bool {
        return s.pre.len == 0 and s.asserts.len == 0 and s.captures.len == 0;
    }
};

/// The `@…` text of a directive line, or null for any other line.
fn directiveOf(raw: []const u8) ?[]const u8 {
    var t = std.mem.trim(u8, raw, " \t\r");
    if (std.mem.startsWith(u8, t, "//")) {
        t = t[2..];
    } else if (t.len > 0 and t[0] == '#') {
        t = t[1..];
    } else return null;
    t = std.mem.trimStart(u8, t, " \t");
    if (t.len < 2 or t[0] != '@') return null;
    return t;
}

pub fn hasDirectives(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| if (directiveOf(l) != null) return true;
    return false;
}

/// The raw `# @…` lines of `block_text`, trimmed, in order.
pub fn directiveLines(arena: Allocator, block_text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, block_text, '\n');
    while (lines.next()) |l| {
        if (directiveOf(l) == null) continue;
        try out.append(arena, std.mem.trim(u8, l, " \t\r"));
    }
    return out.items;
}

/// Surrounding `"…"` / `'…'` stripped.
fn unquote(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len >= 2 and ((t[0] == '"' and t[t.len - 1] == '"') or (t[0] == '\'' and t[t.len - 1] == '\''))) return t[1 .. t.len - 1];
    return t;
}

/// `Name = value` / `Name: value` split at whichever separator comes
/// first. Null without a separator or with an empty name.
fn splitKv(text: []const u8, seps: []const u8) ?KV {
    var best: ?usize = null;
    for (seps) |sep| if (std.mem.indexOfScalar(u8, text, sep)) |i| {
        if (best == null or i < best.?) best = i;
    };
    const i = best orelse return null;
    const name = std.mem.trim(u8, text[0..i], " \t");
    if (name.len == 0) return null;
    return .{ .name = name, .value = std.mem.trim(u8, text[i + 1 ..], " \t") };
}

/// `status` / `body` / `body.<path>` / `json <path>` / `header.<Name>` /
/// `header <Name>`. Returns the source and the text after it.
fn parseSource(text: []const u8) ?struct { source: Source, rest: []const u8 } {
    const t = std.mem.trimStart(u8, text, " \t");
    const sp = std.mem.indexOfAny(u8, t, " \t") orelse t.len;
    const word = t[0..sp];
    const rest = t[sp..];
    if (std.mem.eql(u8, word, "status")) return .{ .source = .status, .rest = rest };
    if (std.mem.eql(u8, word, "body")) return .{ .source = .body, .rest = rest };
    if (std.mem.startsWith(u8, word, "body.")) {
        const path = word["body.".len..];
        if (path.len == 0) return null;
        return .{ .source = .{ .body_path = path }, .rest = rest };
    }
    if (std.mem.startsWith(u8, word, "header.")) {
        const name = word["header.".len..];
        if (name.len == 0) return null;
        return .{ .source = .{ .header = name }, .rest = rest };
    }
    if (std.mem.eql(u8, word, "json") or std.mem.eql(u8, word, "header")) {
        const r = std.mem.trimStart(u8, rest, " \t");
        const sp2 = std.mem.indexOfAny(u8, r, " \t") orelse r.len;
        const arg = r[0..sp2];
        if (arg.len == 0) return null;
        return .{ .source = if (word[0] == 'j') .{ .body_path = arg } else .{ .header = arg }, .rest = r[sp2..] };
    }
    return null;
}

fn parseOp(word: []const u8) ?Op {
    const table = .{
        .{ "==", Op.eq },     .{ "!=", Op.ne },           .{ "<=", Op.le },      .{ ">=", Op.ge },
        .{ "<", Op.lt },      .{ ">", Op.gt },            .{ "=", Op.eq },       .{ "contains", Op.contains },
        .{ "~", Op.matches }, .{ "matches", Op.matches }, .{ "is", Op.is_type },
    };
    inline for (table) |e| if (std.mem.eql(u8, word, e[0])) return e[1];
    return null;
}

fn parseAssert(rest: []const u8) ?Assert {
    const src = parseSource(rest) orelse return null;
    const after = std.mem.trimStart(u8, src.rest, " \t");
    const sp = std.mem.indexOfAny(u8, after, " \t") orelse after.len;
    const op = parseOp(after[0..sp]) orelse return null;
    var value = std.mem.trim(u8, after[sp..], " \t");
    if (op == .matches and value.len >= 2 and value[0] == '/' and value[value.len - 1] == '/') {
        value = value[1 .. value.len - 1];
    } else value = unquote(value);
    if (value.len == 0 and op != .matches) return null;
    return .{ .source = src.source, .op = op, .value = value, .label = std.mem.trim(u8, rest, " \t") };
}

fn parseCapture(rest: []const u8) ?Capture {
    const kv = splitKv(rest, "=") orelse return null;
    if (!env_mod.isValidName(kv.name)) return null;
    const src = parseSource(kv.value) orelse return null;
    return .{ .name = kv.name, .source = src.source };
}

/// Every directive of `block_text`; the rest of the block is ignored.
/// Every slice is on `arena`. Lines that do not parse are skipped.
pub fn parse(arena: Allocator, block_text: []const u8) Allocator.Error!Script {
    var pre: std.ArrayListUnmanaged(Pre) = .empty;
    var asserts: std.ArrayListUnmanaged(Assert) = .empty;
    var captures: std.ArrayListUnmanaged(Capture) = .empty;
    var lines = std.mem.splitScalar(u8, block_text, '\n');
    while (lines.next()) |raw| {
        const d = directiveOf(raw) orelse continue;
        const line = try arena.dupe(u8, d);
        const sp = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        const word = line[0..sp];
        const rest = std.mem.trim(u8, line[sp..], " \t");
        if (std.mem.eql(u8, word, "@set-header")) {
            if (splitKv(rest, "=:")) |kv| try pre.append(arena, .{ .set_header = kv });
        } else if (std.mem.eql(u8, word, "@set-var") or std.mem.eql(u8, word, "@set-env")) {
            if (splitKv(rest, "=")) |kv| if (env_mod.isValidName(kv.name)) try pre.append(arena, .{ .set_var = kv });
        } else if (std.mem.eql(u8, word, "@set-cookie")) {
            if (splitKv(rest, "=")) |kv| try pre.append(arena, .{ .set_cookie = kv });
        } else if (std.mem.eql(u8, word, "@assert")) {
            if (parseAssert(rest)) |a| try asserts.append(arena, a);
        } else if (std.mem.eql(u8, word, "@capture")) {
            if (parseCapture(rest)) |c| try captures.append(arena, c);
        }
    }
    return .{ .pre = pre.items, .asserts = asserts.items, .captures = captures.items };
}

// ─── pre-request ────────────────────────────────────────────────────────

/// Write the pre-request directives into `req` and `env`. Values are
/// not expanded here: the caller expands `{{VAR}}` afterwards, so a
/// `@set-var` is visible to the headers and cookies set beside it.
pub fn applyPre(gpa: Allocator, req: *parse_mod.Request, env: *env_mod.EnvSet, s: Script) Allocator.Error!void {
    for (s.pre) |p| switch (p) {
        .set_header => |kv| try req.setHeader(gpa, kv.name, kv.value),
        .set_var => |kv| try env.put(kv.name, kv.value),
        .set_cookie => |kv| {
            const pair = try std.fmt.allocPrint(gpa, "{s}={s}", .{ kv.name, kv.value });
            defer gpa.free(pair);
            if (req.header("cookie")) |old| {
                const joined = try std.mem.concat(gpa, u8, &.{ old, "; ", pair });
                defer gpa.free(joined);
                try req.setHeader(gpa, "Cookie", joined);
            } else try req.setHeader(gpa, "Cookie", pair);
        },
    };
}

// ─── post-request ───────────────────────────────────────────────────────

pub const Result = struct {
    ok: bool,
    label: []const u8,
    /// `got 404` / `header absent` / `nothing at path` / `` on a pass.
    detail: []const u8,
};

pub const Captured = struct {
    name: []const u8,
    /// Null when the source had nothing (a missing header or path).
    value: ?[]const u8,
};

/// The response as the readers see it; the body is parsed as JSON once,
/// the first time a path asks for it.
const Reply = struct {
    arena: Allocator,
    status: u16,
    headers: []const Header,
    body: []const u8,
    json: ?std.json.Value = null,
    json_tried: bool = false,

    fn root(self: *Reply) ?std.json.Value {
        if (!self.json_tried) {
            self.json_tried = true;
            self.json = std.json.parseFromSliceLeaky(std.json.Value, self.arena, self.body, .{}) catch null;
        }
        return self.json;
    }

    const Read = union(enum) { value: []const u8, absent: []const u8 };

    fn read(self: *Reply, src: Source) Allocator.Error!Read {
        switch (src) {
            .status => return .{ .value = try std.fmt.allocPrint(self.arena, "{d}", .{self.status}) },
            .body => return .{ .value = self.body },
            .header => |name| {
                for (self.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return .{ .value = h.value };
                return .{ .absent = "header absent" };
            },
            .body_path => |path| {
                const r = self.root() orelse return .{ .absent = "body is not JSON" };
                const v = (try resolveJsonPath(self.arena, r, path)) orelse return .{ .absent = "nothing at path" };
                return .{ .value = v };
            },
        }
    }
};

fn compare(op: Op, actual: []const u8, expected: []const u8) bool {
    const an = std.fmt.parseFloat(f64, std.mem.trim(u8, actual, " \t")) catch null;
    const en = std.fmt.parseFloat(f64, std.mem.trim(u8, expected, " \t")) catch null;
    if (an != null and en != null) {
        const a = an.?;
        const e = en.?;
        return switch (op) {
            .eq => a == e,
            .ne => a != e,
            .lt => a < e,
            .le => a <= e,
            .gt => a > e,
            .ge => a >= e,
            else => unreachable,
        };
    }
    const ord = std.mem.order(u8, actual, expected);
    return switch (op) {
        .eq => ord == .eq,
        .ne => ord != .eq,
        .lt => ord == .lt,
        .le => ord != .gt,
        .gt => ord == .gt,
        .ge => ord != .lt,
        else => unreachable,
    };
}

/// One `Result` per assertion, in order. Everything on `arena`.
pub fn runAsserts(arena: Allocator, s: Script, status: u16, headers: []const Header, body: []const u8) Allocator.Error![]Result {
    var reply: Reply = .{ .arena = arena, .status = status, .headers = headers, .body = body };
    const out = try arena.alloc(Result, s.asserts.len);
    for (s.asserts, 0..) |a, i| {
        out[i] = .{ .ok = false, .label = a.label, .detail = "" };
        if (a.op == .is_type) {
            const path = switch (a.source) {
                .body_path => |p| p,
                else => {
                    out[i].detail = "is: needs a body path";
                    continue;
                },
            };
            const r = reply.root() orelse {
                out[i].detail = "body is not JSON";
                continue;
            };
            const ty = jsonTypeName(r, path) orelse {
                out[i].detail = "nothing at path";
                continue;
            };
            out[i].ok = std.mem.eql(u8, ty, a.value);
            if (!out[i].ok) out[i].detail = try std.fmt.allocPrint(arena, "got {s}", .{ty});
            continue;
        }
        const actual = switch (try reply.read(a.source)) {
            .value => |v| v,
            .absent => |why| {
                out[i].detail = why;
                continue;
            },
        };
        out[i].ok = switch (a.op) {
            .contains => std.mem.indexOf(u8, actual, a.value) != null,
            .matches => matchRegex(a.value, actual),
            .is_type => unreachable,
            else => compare(a.op, actual, a.value),
        };
        if (!out[i].ok) {
            const shown = if (actual.len > 60) try std.fmt.allocPrint(arena, "{s}…", .{actual[0..58]}) else actual;
            out[i].detail = try std.fmt.allocPrint(arena, "got {s}", .{std.mem.sliceTo(shown, '\n')});
        }
    }
    return out;
}

/// One `Captured` per capture, in order. Everything on `arena`.
pub fn runCaptures(arena: Allocator, s: Script, status: u16, headers: []const Header, body: []const u8) Allocator.Error![]Captured {
    var reply: Reply = .{ .arena = arena, .status = status, .headers = headers, .body = body };
    const out = try arena.alloc(Captured, s.captures.len);
    for (s.captures, 0..) |c, i| {
        out[i] = .{ .name = c.name, .value = switch (try reply.read(c.source)) {
            .value => |v| v,
            .absent => null,
        } };
    }
    return out;
}

// ─── JSON paths ─────────────────────────────────────────────────────────

/// Walk `$.a.b[0]` / `.a.b` / `a.b` into `root`.
fn walkJsonPath(root: std.json.Value, path_in: []const u8) ?std.json.Value {
    var path = path_in;
    if (std.mem.startsWith(u8, path, "$")) path = path[1..];
    var cur = root;
    var it = std.mem.tokenizeScalar(u8, path, '.');
    while (it.next()) |seg_full| {
        var seg = seg_full;
        while (seg.len > 0) {
            const br = std.mem.indexOfScalar(u8, seg, '[');
            const key = if (br) |b| seg[0..b] else seg;
            if (key.len > 0) {
                if (cur != .object) return null;
                cur = cur.object.get(key) orelse return null;
            }
            if (br == null) break;
            const close = std.mem.indexOfScalarPos(u8, seg, br.?, ']') orelse return null;
            const idx = std.fmt.parseInt(usize, seg[br.? + 1 .. close], 10) catch return null;
            if (cur != .array or idx >= cur.array.items.len) return null;
            cur = cur.array.items[idx];
            seg = seg[close + 1 ..];
        }
    }
    return cur;
}

/// The value at `path`: scalars as text, containers re-serialised.
/// Null when the path finds nothing.
pub fn resolveJsonPath(arena: Allocator, root: std.json.Value, path: []const u8) Allocator.Error!?[]const u8 {
    const cur = walkJsonPath(root, path) orelse return null;
    return switch (cur) {
        .string => |s| s,
        .null => "null",
        .bool => |b| if (b) "true" else "false",
        .integer, .float, .number_string, .array, .object => try std.json.Stringify.valueAlloc(arena, cur, .{}),
    };
}

/// `number` / `string` / `bool` / `null` / `array` / `object` for `is`.
pub fn jsonTypeName(root: std.json.Value, path: []const u8) ?[]const u8 {
    const cur = walkJsonPath(root, path) orelse return null;
    return switch (cur) {
        .string => "string",
        .null => "null",
        .bool => "bool",
        .integer, .float, .number_string => "number",
        .array => "array",
        .object => "object",
    };
}

// ─── the matcher behind `~` ─────────────────────────────────────────────

/// One pattern element: what it matches and how many pattern bytes it
/// took. A class keeps its bracket contents by range.
const Atom = struct {
    kind: union(enum) { any, char: u8, digit, word, space, class: struct { start: usize, end: usize, negate: bool } },
    len: usize,
};

fn atomAt(pat: []const u8, i: usize) ?Atom {
    if (i >= pat.len) return null;
    switch (pat[i]) {
        '.' => return .{ .kind = .any, .len = 1 },
        '\\' => {
            if (i + 1 >= pat.len) return .{ .kind = .{ .char = '\\' }, .len = 1 };
            return .{ .kind = switch (pat[i + 1]) {
                'd' => .digit,
                'w' => .word,
                's' => .space,
                else => |c| .{ .char = c },
            }, .len = 2 };
        },
        '[' => {
            var j = i + 1;
            const negate = j < pat.len and pat[j] == '^';
            if (negate) j += 1;
            const start = j;
            // A `]` right after the opener is a literal.
            if (j < pat.len and pat[j] == ']') j += 1;
            while (j < pat.len and pat[j] != ']') : (j += 1) if (pat[j] == '\\') {
                j += 1;
            };
            if (j >= pat.len) return .{ .kind = .{ .char = '[' }, .len = 1 };
            return .{ .kind = .{ .class = .{ .start = start, .end = j, .negate = negate } }, .len = j + 1 - i };
        },
        '*', '+', '?' => return .{ .kind = .{ .char = pat[i] }, .len = 1 },
        else => |c| return .{ .kind = .{ .char = c }, .len = 1 },
    }
}

fn classHas(pat: []const u8, start: usize, end: usize, c: u8) bool {
    var i = start;
    while (i < end) : (i += 1) {
        var lo = pat[i];
        if (lo == '\\' and i + 1 < end) {
            i += 1;
            switch (pat[i]) {
                'd' => if (std.ascii.isDigit(c)) return true,
                'w' => if (std.ascii.isAlphanumeric(c) or c == '_') return true,
                's' => if (std.ascii.isWhitespace(c)) return true,
                else => {},
            }
            lo = pat[i];
        }
        if (i + 2 < end and pat[i + 1] == '-') {
            const hi = pat[i + 2];
            if (c >= lo and c <= hi) return true;
            i += 2;
        } else if (c == lo) return true;
    }
    return false;
}

fn atomMatches(pat: []const u8, a: Atom, c: u8) bool {
    return switch (a.kind) {
        .any => c != '\n',
        .char => |ch| c == ch,
        .digit => std.ascii.isDigit(c),
        .word => std.ascii.isAlphanumeric(c) or c == '_',
        .space => std.ascii.isWhitespace(c),
        .class => |cl| classHas(pat, cl.start, cl.end, c) != cl.negate,
    };
}

/// `pat` against the start of `text`. Recurses once per pattern atom;
/// a quantifier loops over the text instead of recursing per byte.
fn matchHere(pat: []const u8, text: []const u8) bool {
    if (pat.len == 0) return true;
    if (pat.len == 1 and pat[0] == '$') return text.len == 0;
    const a = atomAt(pat, 0) orelse return false;
    var rest = pat[a.len..];
    var quant: u8 = 0;
    if (rest.len > 0 and (rest[0] == '*' or rest[0] == '+' or rest[0] == '?')) {
        quant = rest[0];
        rest = rest[1..];
    }
    switch (quant) {
        0 => return text.len > 0 and atomMatches(pat, a, text[0]) and matchHere(rest, text[1..]),
        '?' => {
            if (text.len > 0 and atomMatches(pat, a, text[0]) and matchHere(rest, text[1..])) return true;
            return matchHere(rest, text);
        },
        else => {
            var n: usize = 0;
            while (n < text.len and atomMatches(pat, a, text[n])) : (n += 1) {}
            const min: usize = if (quant == '+') 1 else 0;
            var k = n;
            while (k >= min) : (k -= 1) {
                if (matchHere(rest, text[k..])) return true;
                if (k == 0) break;
            }
            return false;
        },
    }
}

fn matchOne(pat: []const u8, text: []const u8) bool {
    if (pat.len > 0 and pat[0] == '^') return matchHere(pat[1..], text);
    var i: usize = 0;
    while (i <= text.len) : (i += 1) if (matchHere(pat, text[i..])) return true;
    return false;
}

/// True when `pattern` matches anywhere in `text` (`^` / `$` anchor).
/// Literals, `.`, `*` `+` `?`, `[abc]` `[^a-z]`, `\d` `\w` `\s`, escaped
/// metacharacters, and `|` between top-level alternatives.
pub fn matchRegex(pattern: []const u8, text: []const u8) bool {
    var start: usize = 0;
    var i: usize = 0;
    var depth: usize = 0;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '\\' => i += 1,
            '[' => depth += 1,
            ']' => depth -|= 1,
            '|' => if (depth == 0) {
                if (matchOne(pattern[start..i], text)) return true;
                start = i + 1;
            },
            else => {},
        }
    }
    return matchOne(pattern[start..], text);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const block =
    \\# List users
    \\# @set-header Authorization = Bearer {{TOKEN}}
    \\// @set-header X-Trace: abc
    \\# @set-var REQ = {{$uuid}}
    \\# @set-env LEGACY = 1
    \\# @set-cookie session = s1
    \\# @set-cookie theme=dark
    \\# @assert status == 200
    \\# @assert header.Content-Type contains json
    \\# @assert header.X-Trace ~ /^[a-f0-9]+$/
    \\# @assert body.user.id is number
    \\# @assert json $.user.name == "Alice"
    \\# @assert body contains hello
    \\# @assert status < 500
    \\# @capture USER_ID = body.user.id
    \\# @capture NAME = json $.user.name
    \\# @capture TRACE = header X-Request-Id
    \\# @capture CODE = status
    \\# @capture RAW = body
    \\# @assert wat
    \\# @capture = nope
    \\# @capture bad-name = status
    \\# not a directive
    \\GET https://x/users
    \\
;

test "parse: every directive form, the Rust spellings, and malformed lines skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try parse(arena.allocator(), block);
    try testing.expect(!s.isEmpty());
    try testing.expectEqual(@as(usize, 6), s.pre.len);
    try testing.expectEqualStrings("Authorization", s.pre[0].set_header.name);
    try testing.expectEqualStrings("Bearer {{TOKEN}}", s.pre[0].set_header.value);
    try testing.expectEqualStrings("X-Trace", s.pre[1].set_header.name);
    try testing.expectEqualStrings("abc", s.pre[1].set_header.value);
    try testing.expectEqualStrings("REQ", s.pre[2].set_var.name);
    try testing.expectEqualStrings("LEGACY", s.pre[3].set_var.name);
    try testing.expectEqualStrings("session", s.pre[4].set_cookie.name);
    try testing.expectEqualStrings("s1", s.pre[4].set_cookie.value);
    try testing.expectEqualStrings("theme", s.pre[5].set_cookie.name);
    try testing.expectEqualStrings("dark", s.pre[5].set_cookie.value);

    try testing.expectEqual(@as(usize, 7), s.asserts.len);
    try testing.expect(s.asserts[0].source == .status and s.asserts[0].op == .eq);
    try testing.expectEqualStrings("200", s.asserts[0].value);
    try testing.expectEqualStrings("status == 200", s.asserts[0].label);
    try testing.expectEqualStrings("Content-Type", s.asserts[1].source.header);
    try testing.expect(s.asserts[1].op == .contains);
    try testing.expect(s.asserts[2].op == .matches);
    try testing.expectEqualStrings("^[a-f0-9]+$", s.asserts[2].value);
    try testing.expectEqualStrings("user.id", s.asserts[3].source.body_path);
    try testing.expect(s.asserts[3].op == .is_type);
    try testing.expectEqualStrings("number", s.asserts[3].value);
    try testing.expectEqualStrings("$.user.name", s.asserts[4].source.body_path);
    try testing.expectEqualStrings("Alice", s.asserts[4].value);
    try testing.expect(s.asserts[5].source == .body and s.asserts[5].op == .contains);
    try testing.expect(s.asserts[6].op == .lt);

    try testing.expectEqual(@as(usize, 5), s.captures.len);
    try testing.expectEqualStrings("USER_ID", s.captures[0].name);
    try testing.expectEqualStrings("user.id", s.captures[0].source.body_path);
    try testing.expectEqualStrings("$.user.name", s.captures[1].source.body_path);
    try testing.expectEqualStrings("X-Request-Id", s.captures[2].source.header);
    try testing.expect(s.captures[3].source == .status);
    try testing.expect(s.captures[4].source == .body);

    try testing.expect(hasDirectives(block));
    try testing.expect(!hasDirectives("# plain\nGET https://x\n"));
    const lines = try directiveLines(arena.allocator(), block);
    try testing.expectEqual(@as(usize, 21), lines.len);
    try testing.expectEqualStrings("# @set-header Authorization = Bearer {{TOKEN}}", lines[0]);
    const empty = try parse(arena.allocator(), "GET https://x\n");
    try testing.expect(empty.isEmpty());
}

fn hdr(name: []const u8, value: []const u8) Header {
    return .{ .name = @constCast(name), .value = @constCast(value) };
}

test "runAsserts: pass and fail per source, with a detail on the failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const headers = [_]Header{ hdr("Content-Type", "application/json; charset=utf-8"), hdr("x-trace", "deadbeef") };
    const body = "{\"user\":{\"id\":42,\"name\":\"Alice\",\"tags\":[\"a\",\"b\"]},\"msg\":\"hello there\"}";
    const passing = try parse(a,
        \\# @assert status == 200
        \\# @assert status < 300
        \\# @assert header.content-type contains json
        \\# @assert header.X-Trace ~ /^[a-f0-9]+$/
        \\# @assert body contains hello
        \\# @assert body.user.id == 42
        \\# @assert json $.user.name == "Alice"
        \\# @assert body.user.id is number
        \\# @assert body.user.tags is array
        \\# @assert body.user.tags[1] == b
        \\# @assert body.user.id >= 42
        \\# @assert body.user.name != Bob
    );
    const ok = try runAsserts(a, passing, 200, &headers, body);
    try testing.expectEqual(@as(usize, 12), ok.len);
    for (ok) |r| {
        if (!r.ok) std.debug.print("unexpected failure: {s} ({s})\n", .{ r.label, r.detail });
        try testing.expect(r.ok);
        try testing.expectEqualStrings("", r.detail);
    }
    const failing = try parse(a,
        \\# @assert status == 200
        \\# @assert header.content-type contains xml
        \\# @assert header.X-Trace ~ /^\d+$/
        \\# @assert header.Missing == 1
        \\# @assert body contains goodbye
        \\# @assert body.user.id == 7
        \\# @assert body.user.id is string
        \\# @assert body.nope == 1
        \\# @assert status is number
    );
    const bad = try runAsserts(a, failing, 404, &headers, body);
    try testing.expectEqual(@as(usize, 9), bad.len);
    for (bad) |r| try testing.expect(!r.ok);
    try testing.expectEqualStrings("status == 200", bad[0].label);
    try testing.expectEqualStrings("got 404", bad[0].detail);
    try testing.expectEqualStrings("got application/json; charset=utf-8", bad[1].detail);
    try testing.expectEqualStrings("got deadbeef", bad[2].detail);
    try testing.expectEqualStrings("header absent", bad[3].detail);
    try testing.expect(std.mem.startsWith(u8, bad[4].detail, "got {\"user\""));
    try testing.expectEqualStrings("got 42", bad[5].detail);
    try testing.expectEqualStrings("got number", bad[6].detail);
    try testing.expectEqualStrings("nothing at path", bad[7].detail);
    try testing.expectEqualStrings("is: needs a body path", bad[8].detail);
    // A non-JSON body says so instead of failing silently.
    const not_json = try runAsserts(a, try parse(a, "# @assert body.x == 1\n"), 200, &headers, "<html>");
    try testing.expectEqualStrings("body is not JSON", not_json[0].detail);
}

test "runCaptures: body path, header, status, body, and a missing path is null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const headers = [_]Header{hdr("X-Request-Id", "req-9")};
    const body = "{\"id\":7,\"user\":{\"name\":\"Bo\"},\"list\":[1,2]}";
    const s = try parse(a,
        \\# @capture ID = body.id
        \\# @capture NAME = json $.user.name
        \\# @capture TRACE = header X-Request-Id
        \\# @capture CODE = status
        \\# @capture RAW = body
        \\# @capture LIST = body.list
        \\# @capture GONE = body.nope.x
        \\# @capture NOHDR = header.Absent
    );
    const got = try runCaptures(a, s, 201, &headers, body);
    try testing.expectEqual(@as(usize, 8), got.len);
    try testing.expectEqualStrings("ID", got[0].name);
    try testing.expectEqualStrings("7", got[0].value.?);
    try testing.expectEqualStrings("Bo", got[1].value.?);
    try testing.expectEqualStrings("req-9", got[2].value.?);
    try testing.expectEqualStrings("201", got[3].value.?);
    try testing.expectEqualStrings(body, got[4].value.?);
    try testing.expectEqualStrings("[1,2]", got[5].value.?);
    try testing.expect(got[6].value == null);
    try testing.expect(got[7].value == null);
}

test "applyPre: a header, a var, and two cookies joined into one Cookie header" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const s = try parse(arena.allocator(),
        \\# @set-header Authorization = Bearer {{TOKEN}}
        \\# @set-var TOKEN = abc
        \\# @set-cookie session = s1
        \\# @set-cookie theme=dark
    );
    var req = try parse_mod.Request.init(gpa);
    defer req.deinit(gpa);
    try req.addHeader(gpa, "Authorization", "old");
    var env = env_mod.EnvSet.empty(gpa);
    defer env.deinit();
    try applyPre(gpa, &req, &env, s);
    try testing.expectEqualStrings("Bearer {{TOKEN}}", req.header("authorization").?);
    try testing.expectEqual(@as(usize, 2), req.headers.items.len);
    try testing.expectEqualStrings("abc", env.get("TOKEN").?);
    try testing.expectEqualStrings("session=s1; theme=dark", req.header("cookie").?);
}

test "matchRegex: anchors, quantifiers, classes, escapes, alternation" {
    try testing.expect(matchRegex("^v\\d+\\.\\d+$", "v1.22"));
    try testing.expect(!matchRegex("^v\\d+\\.\\d+$", "v1.22.3"));
    try testing.expect(!matchRegex("^v\\d+\\.\\d+$", "xv1.2"));
    try testing.expect(matchRegex("json", "application/json; charset=utf-8"));
    try testing.expect(matchRegex("^[a-f0-9]+$", "deadbeef"));
    try testing.expect(!matchRegex("^[a-f0-9]+$", "deadbeefz"));
    try testing.expect(matchRegex("[^0-9]", "ab1"));
    try testing.expect(!matchRegex("^[^0-9]+$", "ab1"));
    try testing.expect(matchRegex("a.*z", "a lot of text z"));
    try testing.expect(matchRegex("^a.*z$", "az"));
    try testing.expect(!matchRegex("^a.+z$", "az"));
    try testing.expect(matchRegex("colou?r", "color") and matchRegex("colou?r", "colour"));
    try testing.expect(matchRegex("cat|dog", "hotdog"));
    try testing.expect(!matchRegex("cat|dog", "bird"));
    try testing.expect(matchRegex("^(x)$", "(x)")); // parens are literal
    try testing.expect(matchRegex("\\(x\\)", "a (x) b"));
    try testing.expect(matchRegex("\\w+@\\w+\\.com", "mail bob@example.com now"));
    try testing.expect(matchRegex("a\\s+b", "a   b"));
    try testing.expect(matchRegex("[a|b]", "|"));
    try testing.expect(matchRegex("", "anything"));
    try testing.expect(matchRegex("^$", ""));
    try testing.expect(matchRegex("x*", ""));
}

test "resolveJsonPath and jsonTypeName walk objects and arrays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"a\":{\"b\":[{\"c\":1.5},{\"c\":null}]},\"ok\":true}", .{});
    try testing.expectEqualStrings("1.5", (try resolveJsonPath(a, root, "$.a.b[0].c")).?);
    try testing.expectEqualStrings("null", (try resolveJsonPath(a, root, ".a.b[1].c")).?);
    try testing.expectEqualStrings("true", (try resolveJsonPath(a, root, "ok")).?);
    try testing.expectEqualStrings("[{\"c\":1.5},{\"c\":null}]", (try resolveJsonPath(a, root, "a.b")).?);
    try testing.expect((try resolveJsonPath(a, root, "a.b[5]")) == null);
    try testing.expect((try resolveJsonPath(a, root, "a.z")) == null);
    try testing.expectEqualStrings("number", jsonTypeName(root, "a.b[0].c").?);
    try testing.expectEqualStrings("null", jsonTypeName(root, "a.b[1].c").?);
    try testing.expectEqualStrings("bool", jsonTypeName(root, "ok").?);
    try testing.expectEqualStrings("array", jsonTypeName(root, "a.b").?);
    try testing.expectEqualStrings("object", jsonTypeName(root, "a").?);
    try testing.expect(jsonTypeName(root, "nope") == null);
}

/// True for a `# @…` / `// @…` line — a directive wherever it sits in
/// a block, never a body byte.
pub fn isDirectiveLine(raw: []const u8) bool {
    return directiveOf(raw) != null;
}
