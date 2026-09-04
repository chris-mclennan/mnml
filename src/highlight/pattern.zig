//! The small pattern language the highlight queries' `#match?` and
//! `#lua-match?` predicates use. A backtracking matcher over a compiled
//! term list: literals, `.`, anchors, character classes (`[a-z]`,
//! `[^…]`, `\d \w \s` and Lua's `%a %d %l %u %w %s %p %x`), groups with
//! alternation, and the `* + ? {n,m}` quantifiers (Lua's `-` is `*`).
//!
//! It exists so the queries' constant-vs-variable and builtin-vs-user
//! distinctions hold without a regex engine; the patterns in the shipped
//! queries are all anchored, short and run against single identifiers.
//! Anything the language cannot express compiles to `error.Unsupported`
//! and the predicate is treated as false — a missed special case, never
//! a wrong one.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Dialect = enum { regex, lua };

pub const Error = error{Unsupported} || Allocator.Error;

const Class = struct {
    ranges: []const [2]u8,
    negated: bool,

    fn has(c: Class, b: u8) bool {
        var hit = false;
        for (c.ranges) |r| if (b >= r[0] and b <= r[1]) {
            hit = true;
            break;
        };
        return hit != c.negated;
    }
};

const Atom = union(enum) {
    lit: u8,
    any,
    start,
    end,
    word_boundary,
    class: Class,
    group: []const []const Term,
};

const Term = struct { atom: Atom, min: u32, max: u32 };

pub const Pattern = struct {
    arena: std.heap.ArenaAllocator,
    alts: []const []const Term,

    pub fn compile(gpa: Allocator, src: []const u8, dialect: Dialect) Error!Pattern {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        var p: Parser = .{ .src = src, .dialect = dialect, .a = arena.allocator() };
        const alts = try p.alternatives(false);
        if (p.i != src.len) return error.Unsupported;
        return .{ .arena = arena, .alts = alts };
    }

    pub fn deinit(p: *Pattern) void {
        p.arena.deinit();
    }

    /// Unanchored search: does the pattern match anywhere in `text`?
    pub fn matches(p: *const Pattern, text: []const u8) bool {
        var start: usize = 0;
        while (start <= text.len) : (start += 1) {
            if (matchAlts(p.alts, text, start, null)) return true;
            // A pattern anchored at `^` cannot match later; skip the scan.
            if (p.alts.len > 0 and p.alts[0].len > 0 and p.alts[0][0].atom == .start) break;
        }
        return false;
    }
};

// ── matching ──

/// What to match once the current term list is exhausted. `min_pos`
/// refuses an empty group repetition — the one way `(a*)*` could recurse
/// forever.
const Cont = struct {
    terms: []const Term,
    i: usize,
    next: ?*const Cont,
    min_pos: ?usize = null,
};

fn matchAlts(alts: []const []const Term, text: []const u8, pos: usize, k: ?*const Cont) bool {
    for (alts) |seq| if (matchSeq(seq, 0, text, pos, k)) return true;
    return false;
}

fn runCont(k: ?*const Cont, text: []const u8, pos: usize) bool {
    const c = k orelse return true;
    if (c.min_pos) |m| if (pos <= m) return false;
    return matchSeq(c.terms, c.i, text, pos, c.next);
}

fn matchSeq(terms: []const Term, i: usize, text: []const u8, pos: usize, k: ?*const Cont) bool {
    if (i == terms.len) return runCont(k, text, pos);
    const t = terms[i];
    switch (t.atom) {
        .start => return pos == 0 and matchSeq(terms, i + 1, text, pos, k),
        .end => return pos == text.len and matchSeq(terms, i + 1, text, pos, k),
        .word_boundary => {
            const before = pos > 0 and isWord(text[pos - 1]);
            const after = pos < text.len and isWord(text[pos]);
            return before != after and matchSeq(terms, i + 1, text, pos, k);
        },
        .group => |alts| {
            // Greedy: one more repetition first (the rest of the
            // repetitions ride along as a one-term continuation), then
            // the option of stopping here.
            if (t.max > 0) {
                const rep = [1]Term{.{ .atom = t.atom, .min = t.min -| 1, .max = if (t.max == std.math.maxInt(u32)) t.max else t.max - 1 }};
                const after: Cont = .{ .terms = terms, .i = i + 1, .next = k };
                const again: Cont = .{ .terms = &rep, .i = 0, .next = &after, .min_pos = pos };
                if (matchAlts(alts, text, pos, &again)) return true;
            }
            if (t.min == 0) return matchSeq(terms, i + 1, text, pos, k);
            return false;
        },
        else => {
            // Single-byte atoms: take the greedy run, then back off.
            var n: usize = 0;
            while (n < t.max and pos + n < text.len and atomHits(t.atom, text[pos + n])) n += 1;
            if (n < t.min) return false;
            var take = n;
            while (true) {
                if (matchSeq(terms, i + 1, text, pos + take, k)) return true;
                if (take == t.min) return false;
                take -= 1;
            }
        },
    }
}

fn atomHits(a: Atom, b: u8) bool {
    return switch (a) {
        .lit => |c| c == b,
        .any => b != '\n',
        .class => |c| c.has(b),
        else => false,
    };
}

fn isWord(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

// ── parsing ──

const Parser = struct {
    src: []const u8,
    dialect: Dialect,
    a: Allocator,
    i: usize = 0,
    depth: usize = 0,

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.src.len) p.src[p.i] else null;
    }

    fn alternatives(p: *Parser, in_group: bool) Error![]const []const Term {
        var alts: std.ArrayListUnmanaged([]const Term) = .empty;
        while (true) {
            try alts.append(p.a, try p.sequence(in_group));
            if (p.peek() == '|') {
                p.i += 1;
                continue;
            }
            break;
        }
        return alts.items;
    }

    fn sequence(p: *Parser, in_group: bool) Error![]const Term {
        var terms: std.ArrayListUnmanaged(Term) = .empty;
        while (p.peek()) |c| {
            if (c == '|') break;
            if (c == ')') {
                if (!in_group) return error.Unsupported;
                break;
            }
            const a = try p.atom();
            const q = try p.quantifier();
            try terms.append(p.a, .{ .atom = a, .min = q[0], .max = q[1] });
        }
        return terms.items;
    }

    fn atom(p: *Parser) Error!Atom {
        const c = p.src[p.i];
        p.i += 1;
        switch (c) {
            '^' => return .start,
            '$' => return .end,
            '.' => return .any,
            '(' => {
                if (p.dialect == .lua) return error.Unsupported;
                if (std.mem.startsWith(u8, p.src[p.i..], "?:")) p.i += 2 else if (p.peek() == '?') return error.Unsupported;
                p.depth += 1;
                if (p.depth > 16) return error.Unsupported;
                const alts = try p.alternatives(true);
                p.depth -= 1;
                if (p.peek() != ')') return error.Unsupported;
                p.i += 1;
                return .{ .group = alts };
            },
            '[' => return .{ .class = try p.class() },
            '\\' => {
                if (p.dialect == .lua) return .{ .lit = '\\' };
                return p.escape();
            },
            '%' => {
                if (p.dialect == .regex) return .{ .lit = '%' };
                return p.escape();
            },
            '*', '+', '?' => return error.Unsupported,
            else => return .{ .lit = c },
        }
    }

    /// After the escape char: a class shorthand or a literal.
    fn escape(p: *Parser) Error!Atom {
        const c = p.peek() orelse return error.Unsupported;
        p.i += 1;
        if (shorthand(c, p.dialect)) |cls| return .{ .class = cls };
        if (p.dialect == .regex and c == 'b') return .word_boundary;
        if (std.ascii.isAlphanumeric(c)) return error.Unsupported;
        return .{ .lit = c };
    }

    fn class(p: *Parser) Error!Class {
        var negated = false;
        if (p.peek() == '^') {
            negated = true;
            p.i += 1;
        }
        var ranges: std.ArrayListUnmanaged([2]u8) = .empty;
        var first = true;
        while (true) {
            const c = p.peek() orelse return error.Unsupported;
            if (c == ']' and !first) {
                p.i += 1;
                break;
            }
            first = false;
            p.i += 1;
            var lo: u8 = c;
            const esc: u8 = if (p.dialect == .lua) '%' else '\\';
            if (c == esc) {
                const e = p.peek() orelse return error.Unsupported;
                p.i += 1;
                if (shorthand(e, p.dialect)) |cls| {
                    if (cls.negated) return error.Unsupported;
                    try ranges.appendSlice(p.a, cls.ranges);
                    continue;
                }
                lo = e;
            }
            if (p.peek() == '-' and p.i + 1 < p.src.len and p.src[p.i + 1] != ']') {
                p.i += 1;
                const hi = p.src[p.i];
                p.i += 1;
                if (hi < lo) return error.Unsupported;
                try ranges.append(p.a, .{ lo, hi });
            } else {
                try ranges.append(p.a, .{ lo, lo });
            }
        }
        return .{ .ranges = ranges.items, .negated = negated };
    }

    fn quantifier(p: *Parser) Error![2]u32 {
        const c = p.peek() orelse return .{ 1, 1 };
        const q: [2]u32 = switch (c) {
            '*' => .{ 0, std.math.maxInt(u32) },
            '+' => .{ 1, std.math.maxInt(u32) },
            '?' => .{ 0, 1 },
            '-' => if (p.dialect == .lua) .{ 0, std.math.maxInt(u32) } else return .{ 1, 1 },
            '{' => blk: {
                if (p.dialect == .lua) return .{ 1, 1 };
                const close = std.mem.indexOfScalarPos(u8, p.src, p.i, '}') orelse return error.Unsupported;
                const body = p.src[p.i + 1 .. close];
                p.i = close;
                if (std.mem.indexOfScalar(u8, body, ',')) |comma| {
                    const lo = std.fmt.parseInt(u32, body[0..comma], 10) catch return error.Unsupported;
                    const hi_s = body[comma + 1 ..];
                    const hi = if (hi_s.len == 0) std.math.maxInt(u32) else std.fmt.parseInt(u32, hi_s, 10) catch return error.Unsupported;
                    break :blk .{ lo, hi };
                }
                const n = std.fmt.parseInt(u32, body, 10) catch return error.Unsupported;
                break :blk .{ n, n };
            },
            else => return .{ 1, 1 },
        };
        p.i += 1;
        // A lazy marker changes nothing for a yes/no match.
        if (p.dialect == .regex and p.peek() == '?') p.i += 1;
        return q;
    }
};

fn shorthand(c: u8, dialect: Dialect) ?Class {
    const digits = [_][2]u8{.{ '0', '9' }};
    const alpha = [_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' } };
    const alnum = [_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '0', '9' } };
    const word = [_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '0', '9' }, .{ '_', '_' } };
    const space = [_][2]u8{ .{ ' ', ' ' }, .{ '\t', '\r' } };
    const lower = [_][2]u8{.{ 'a', 'z' }};
    const upper = [_][2]u8{.{ 'A', 'Z' }};
    const punct = [_][2]u8{ .{ '!', '/' }, .{ ':', '@' }, .{ '[', '`' }, .{ '{', '~' } };
    const hex = [_][2]u8{ .{ '0', '9' }, .{ 'a', 'f' }, .{ 'A', 'F' } };
    return switch (dialect) {
        .regex => switch (c) {
            'd' => .{ .ranges = &digits, .negated = false },
            'D' => .{ .ranges = &digits, .negated = true },
            'w' => .{ .ranges = &word, .negated = false },
            'W' => .{ .ranges = &word, .negated = true },
            's' => .{ .ranges = &space, .negated = false },
            'S' => .{ .ranges = &space, .negated = true },
            else => null,
        },
        .lua => switch (c) {
            'a' => .{ .ranges = &alpha, .negated = false },
            'A' => .{ .ranges = &alpha, .negated = true },
            'd' => .{ .ranges = &digits, .negated = false },
            'D' => .{ .ranges = &digits, .negated = true },
            'l' => .{ .ranges = &lower, .negated = false },
            'L' => .{ .ranges = &lower, .negated = true },
            'u' => .{ .ranges = &upper, .negated = false },
            'U' => .{ .ranges = &upper, .negated = true },
            'w' => .{ .ranges = &alnum, .negated = false },
            'W' => .{ .ranges = &alnum, .negated = true },
            's' => .{ .ranges = &space, .negated = false },
            'S' => .{ .ranges = &space, .negated = true },
            'p' => .{ .ranges = &punct, .negated = false },
            'P' => .{ .ranges = &punct, .negated = true },
            'x' => .{ .ranges = &hex, .negated = false },
            'X' => .{ .ranges = &hex, .negated = true },
            else => null,
        },
    };
}

// ── tests ──

const testing = std.testing;

fn expectMatch(src: []const u8, dialect: Dialect, text: []const u8, want: bool) !void {
    var p = try Pattern.compile(testing.allocator, src, dialect);
    defer p.deinit();
    try testing.expectEqual(want, p.matches(text));
}

test "the shapes the shipped queries use" {
    try expectMatch("^[A-Z]", .regex, "FOO", true);
    try expectMatch("^[A-Z]", .regex, "foo", false);
    try expectMatch("^[A-Z][A-Z\\d_]+$", .regex, "MAX_LEN2", true);
    try expectMatch("^[A-Z][A-Z\\d_]+$", .regex, "MaxLen", false);
    try expectMatch("^_", .regex, "_x", true);
    try expectMatch("^(true|false)$", .regex, "true", true);
    try expectMatch("^(true|false)$", .regex, "trueish", false);
    try expectMatch("^[a-z]+_t$", .regex, "size_t", true);
    try expectMatch("^\\$", .regex, "$x", true);
    try expectMatch("^(u|i)(8|16|32|64|128|size)$", .regex, "u32", true);
    try expectMatch("^(u|i)(8|16|32|64|128|size)$", .regex, "u33", false);
    try expectMatch("^(#|<|>)", .regex, "<x", true);
    try expectMatch("^[%u_][%u%d_]*$", .lua, "CONST_1", true);
    try expectMatch("^[%u_][%u%d_]*$", .lua, "Const", false);
    try expectMatch("^%d", .lua, "9x", true);
    try expectMatch("^__", .lua, "__init__", true);
    try expectMatch("[.]", .regex, "a.b", true);
    try expectMatch("^(x|y)*z$", .regex, "xyxz", true);
    try expectMatch("^a{2,3}$", .regex, "aaa", true);
    try expectMatch("^a{2,3}$", .regex, "aaaa", false);
    try expectMatch("\\bfoo\\b", .regex, "a foo b", true);
    try expectMatch("\\bfoo\\b", .regex, "afoob", false);
    try expectMatch("^[^a-z]", .regex, "9", true);
    try expectMatch("^[^a-z]", .regex, "q", false);
    try expectMatch("^(?:ab)+$", .regex, "abab", true);
}

test "unsupported syntax is an error, not a wrong answer" {
    try testing.expectError(error.Unsupported, Pattern.compile(testing.allocator, "(?<=a)b", .regex));
    try testing.expectError(error.Unsupported, Pattern.compile(testing.allocator, "a)", .regex));
    try testing.expectError(error.Unsupported, Pattern.compile(testing.allocator, "[abc", .regex));
    try testing.expectError(error.Unsupported, Pattern.compile(testing.allocator, "*a", .regex));
}
