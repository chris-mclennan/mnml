//! Vim pattern syntax → Oniguruma syntax. The find bar, `:s` and the
//! grep filter all take what a vim user types (`\<word\>`, `\v(a|b)+`,
//! `\{2,3}`, `\c`), and Oniguruma has no vim syntax of its own, so this
//! is the one translation, done once per compile into a caller's buffer.
//!
//! What is covered: the four magic modes (`\v` `\m` `\M` `\V`, switchable
//! mid-pattern), the quantifiers (`*` `\+` `\=` `\?` `\{n,m}` and the
//! non-greedy `\{-n,m}`), groups (`\(` `\)` `\%(`), alternation `\|`,
//! the word boundaries `\<` `\>`, the character classes (`\s` `\d` `\w`
//! `\a` `\l` `\u` `\x` `\o` `\h` `\i` `\k` and their negations, `\_s`),
//! collections `[...]`, `\zs` / `\ze`, the lookarounds `\@=` `\@!`
//! `\@<=` `\@<!` `\@>`, backreferences `\1`–`\9`, `\%^` `\%$` `\%d` `\%x`
//! `\%u`, `\n` `\t` `\e` `\r`, and `\c` / `\C` for case. What is not:
//! `\&`, `\%V`, `\%#`, `\%23l` and the other cursor-relative items — they
//! are `error.Unsupported`, and the caller says so.

const std = @import("std");

pub const Error = error{
    /// The translation does not fit the caller's buffer.
    TooLong,
    /// An item vim knows and this translation does not.
    Unsupported,
    /// Malformed: an unclosed group, a `\{` without `}`, a lone `\`.
    Invalid,
};

pub const Result = struct {
    /// The Oniguruma pattern, a prefix of the caller's buffer.
    pattern: []const u8,
    /// `\c` seen (true) / `\C` seen (false) / neither (null).
    ignore_case: ?bool,
};

const Mode = enum { very_magic, magic, nomagic, very_nomagic };

const Writer = struct {
    out: []u8,
    len: usize = 0,
    /// Where the most recent atom started in `out`, for a following
    /// lookaround (`x\@=`) to wrap it.
    last_atom: ?usize = null,
    /// Open groups: where each began.
    groups: [32]usize = undefined,
    depth: usize = 0,
    /// A `\ze` opened a lookahead that closes at the end.
    ze_open: bool = false,

    fn put(w: *Writer, s: []const u8) Error!void {
        if (w.len + s.len > w.out.len) return error.TooLong;
        @memcpy(w.out[w.len .. w.len + s.len], s);
        w.len += s.len;
    }

    fn putByte(w: *Writer, b: u8) Error!void {
        if (w.len >= w.out.len) return error.TooLong;
        w.out[w.len] = b;
        w.len += 1;
    }

    /// Insert `s` at `at`, shifting what follows.
    fn insert(w: *Writer, at: usize, s: []const u8) Error!void {
        if (w.len + s.len > w.out.len) return error.TooLong;
        std.mem.copyBackwards(u8, w.out[at + s.len .. w.len + s.len], w.out[at..w.len]);
        @memcpy(w.out[at .. at + s.len], s);
        w.len += s.len;
    }

    fn atom(w: *Writer) void {
        w.last_atom = w.len;
    }

    /// A literal byte, escaped when Oniguruma would read it otherwise.
    fn literal(w: *Writer, b: u8) Error!void {
        w.atom();
        switch (b) {
            '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '\\', '/', '#', '-', '&', '~' => {
                try w.putByte('\\');
                try w.putByte(b);
            },
            '\n' => try w.put("\\n"),
            '\t' => try w.put("\\t"),
            else => try w.putByte(b),
        }
    }

    /// A literal that must not move `last_atom` (a `\%[...]` piece).
    fn literalNoAtom(w: *Writer, b: u8) Error!void {
        const keep = w.last_atom;
        try w.literal(b);
        w.last_atom = keep;
    }

    /// A literal inside `[...]`, escaped for Oniguruma's class syntax.
    fn literalInClass(w: *Writer, c: u8) Error!void {
        switch (c) {
            '[', ']', '\\', '^', '&', '~' => {
                try w.putByte('\\');
                try w.putByte(c);
            },
            else => try w.putByte(c),
        }
    }
};

/// Translate `pat` into `out`. The result borrows `out`.
pub fn translate(pat: []const u8, out: []u8) Error!Result {
    var w: Writer = .{ .out = out };
    var mode: Mode = .magic;
    var ignore_case: ?bool = null;
    var i: usize = 0;
    // `^` is an anchor only at the start of a branch in magic mode.
    var branch_start = true;
    while (i < pat.len) {
        const c = pat[i];
        const at_branch_start = branch_start;
        branch_start = false;
        if (c == '\\') {
            if (i + 1 >= pat.len) return error.Invalid;
            const e = pat[i + 1];
            i += 2;
            switch (e) {
                'v' => {
                    mode = .very_magic;
                    branch_start = at_branch_start;
                },
                'm' => {
                    mode = .magic;
                    branch_start = at_branch_start;
                },
                'M' => {
                    mode = .nomagic;
                    branch_start = at_branch_start;
                },
                'V' => {
                    mode = .very_nomagic;
                    branch_start = at_branch_start;
                },
                'c' => {
                    ignore_case = true;
                    branch_start = at_branch_start;
                },
                'C' => {
                    ignore_case = false;
                    branch_start = at_branch_start;
                },
                else => {
                    // In very magic the backslash makes a special char
                    // literal; elsewhere it makes a literal char special.
                    const special = switch (mode) {
                        .very_magic => !isVeryMagicPunct(e),
                        else => true,
                    };
                    if (special) {
                        i = try escaped(&w, e, pat, i, mode, &branch_start, at_branch_start);
                    } else try w.literal(e);
                },
            }
            continue;
        }
        i += 1;
        // `^` and `$` are anchors in every mode (at a branch start /
        // end); the rest depends on how magic the mode is.
        const special = c == '^' or c == '$' or switch (mode) {
            .very_magic => isVeryMagicPunct(c),
            .magic => c == '.' or c == '*' or c == '[' or c == '~',
            .nomagic, .very_nomagic => false,
        };
        if (!special) {
            try w.literal(c);
            continue;
        }
        switch (c) {
            '^' => {
                // Magic `^` anchors only at a branch start; very magic always.
                if (mode == .very_magic or at_branch_start) {
                    try w.put("^");
                } else try w.literal('^');
                branch_start = at_branch_start;
            },
            '$' => {
                const at_branch_end = i >= pat.len or (i + 1 < pat.len and pat[i] == '\\' and (pat[i + 1] == '|' or pat[i + 1] == ')' or pat[i + 1] == 'n'));
                if (mode == .very_magic or at_branch_end) {
                    try w.put("$");
                } else try w.literal('$');
            },
            '.' => {
                w.atom();
                try w.put(".");
            },
            '*' => try w.put("*"),
            '[' => i = try collection(&w, pat, i - 1),
            '~' => try w.literal('~'),
            // Very magic only from here.
            '(' => {
                if (w.depth >= w.groups.len) return error.TooLong;
                w.groups[w.depth] = w.len;
                w.depth += 1;
                try w.put("(");
                branch_start = true;
            },
            ')' => try closeGroup(&w),
            '|' => {
                try w.put("|");
                branch_start = true;
            },
            '+' => try w.put("+"),
            '=', '?' => try w.put("?"),
            '{' => i = try brace(&w, pat, i),
            '<' => {
                w.atom();
                try w.put("(?<!\\w)(?=\\w)");
            },
            '>' => {
                w.atom();
                try w.put("(?<=\\w)(?!\\w)");
            },
            '@' => i = try lookaround(&w, pat, i),
            '%' => i = try percent(&w, pat, i, &branch_start),
            else => try w.literal(c),
        }
    }
    if (w.depth != 0) return error.Invalid;
    if (w.ze_open) try w.put(")");
    return .{ .pattern = w.out[0..w.len], .ignore_case = ignore_case };
}

/// Very magic: every ASCII punctuation except `_` is special.
fn isVeryMagicPunct(c: u8) bool {
    return switch (c) {
        '0'...'9', 'a'...'z', 'A'...'Z', '_' => false,
        else => c < 0x80 and !std.ascii.isControl(c) and c != ' ',
    };
}

/// A backslash item that is special in the current mode: `\(`, `\+`,
/// `\<`, the classes, `\zs`… `i` is just past the escaped char.
fn escaped(w: *Writer, e: u8, pat: []const u8, i_in: usize, mode: Mode, branch_start: *bool, at_branch_start: bool) Error!usize {
    var i = i_in;
    switch (e) {
        '(' => {
            if (w.depth >= w.groups.len) return error.TooLong;
            w.groups[w.depth] = w.len;
            w.depth += 1;
            try w.put("(");
            branch_start.* = true;
        },
        ')' => try closeGroup(w),
        '|' => {
            try w.put("|");
            branch_start.* = true;
        },
        '+' => try w.put("+"),
        '=', '?' => try w.put("?"),
        '{' => i = try brace(w, pat, i),
        '<' => {
            w.atom();
            try w.put("(?<!\\w)(?=\\w)");
        },
        '>' => {
            w.atom();
            try w.put("(?<=\\w)(?!\\w)");
        },
        '@' => i = try lookaround(w, pat, i),
        '%' => i = try percent(w, pat, i, branch_start),
        // `\.` `\*` `\[` `\~` are the any-char / star / collection /
        // last-substitute only after `\M` or `\V`; in magic mode the
        // backslash makes them literal.
        '.' => if (mode == .nomagic or mode == .very_nomagic) {
            w.atom();
            try w.put(".");
        } else try w.literal('.'),
        '*' => if (mode == .nomagic or mode == .very_nomagic) try w.put("*") else try w.literal('*'),
        '[' => if (mode == .nomagic or mode == .very_nomagic) {
            i = try collection(w, pat, i - 1);
        } else try w.literal('['),
        '~' => try w.literal('~'),
        // `\^` and `\$` are the literal characters in every mode.
        '^' => {
            try w.literal('^');
            branch_start.* = at_branch_start;
        },
        '$' => try w.literal('$'),
        'z' => {
            if (i >= pat.len) return error.Invalid;
            const z = pat[i];
            i += 1;
            switch (z) {
                's' => try w.put("\\K"),
                'e' => {
                    if (w.ze_open) return error.Invalid;
                    w.ze_open = true;
                    try w.put("(?=");
                },
                else => return error.Unsupported,
            }
        },
        '_' => {
            if (i >= pat.len) return error.Invalid;
            const u = pat[i];
            i += 1;
            w.atom();
            if (u == '.') {
                try w.put("(?m:.)");
            } else if (u == '^') {
                try w.put("^");
            } else if (u == '$') {
                try w.put("$");
            } else if (u == '[') {
                // A collection that also matches a newline.
                i = try collection(w, pat, i - 1);
                // `[...]` was emitted; widen it into `(?:[...]|\n)`.
                const start = w.last_atom.?;
                try w.insert(start, "(?:");
                try w.put("|\\n)");
            } else if (classOf(u, true)) |cls| {
                try w.put(cls);
            } else return error.Unsupported;
        },
        'n' => {
            w.atom();
            try w.put("\\n");
        },
        't' => {
            w.atom();
            try w.put("\\t");
        },
        'e' => {
            w.atom();
            try w.put("\\e");
        },
        'r' => {
            w.atom();
            try w.put("\\r");
        },
        'b' => {
            w.atom();
            try w.put("\\x08");
        },
        '1'...'9' => {
            w.atom();
            try w.put("\\");
            try w.putByte(e);
        },
        '&' => return error.Unsupported,
        else => {
            if (classOf(e, false)) |cls| {
                w.atom();
                try w.put(cls);
            } else {
                // `\x` for a char with no meaning: vim reads it as `x`.
                try w.literal(e);
            }
        },
    }
    return i;
}

fn closeGroup(w: *Writer) Error!void {
    if (w.depth == 0) return error.Invalid;
    w.depth -= 1;
    try w.put(")");
    w.last_atom = w.groups[w.depth];
}

/// Vim's one-letter classes. `with_newline` is the `\_x` form.
fn classOf(c: u8, with_newline: bool) ?[]const u8 {
    if (with_newline) {
        return switch (c) {
            's' => "[ \\t\\n]",
            'S' => "[^ \\t]",
            'd' => "[0-9\\n]",
            'D' => "[^0-9]",
            'w' => "[0-9A-Za-z_\\n]",
            'W' => "[^0-9A-Za-z_]",
            'a' => "[A-Za-z\\n]",
            'A' => "[^A-Za-z]",
            'l' => "[a-z\\n]",
            'L' => "[^a-z]",
            'u' => "[A-Z\\n]",
            'U' => "[^A-Z]",
            'x' => "[0-9A-Fa-f\\n]",
            'X' => "[^0-9A-Fa-f]",
            'o' => "[0-7\\n]",
            'O' => "[^0-7]",
            'h' => "[A-Za-z_\\n]",
            'H' => "[^A-Za-z_]",
            'i', 'k' => "[0-9A-Za-z_\\n]",
            'I', 'K' => "[A-Za-z_\\n]",
            'f', 'p' => "[^ \\t]",
            'F', 'P' => "[^ \\t0-9]",
            else => null,
        };
    }
    return switch (c) {
        's' => "[ \\t]",
        'S' => "[^ \\t\\n]",
        'd' => "[0-9]",
        'D' => "[^0-9\\n]",
        'w' => "[0-9A-Za-z_]",
        'W' => "[^0-9A-Za-z_\\n]",
        'a' => "[A-Za-z]",
        'A' => "[^A-Za-z\\n]",
        'l' => "[a-z]",
        'L' => "[^a-z\\n]",
        'u' => "[A-Z]",
        'U' => "[^A-Z\\n]",
        'x' => "[0-9A-Fa-f]",
        'X' => "[^0-9A-Fa-f\\n]",
        'o' => "[0-7]",
        'O' => "[^0-7\\n]",
        'h' => "[A-Za-z_]",
        'H' => "[^A-Za-z_\\n]",
        'i', 'k' => "[0-9A-Za-z_]",
        'I', 'K' => "[A-Za-z_]",
        'f', 'p' => "[^ \\t\\n]",
        'F', 'P' => "[^ \\t\\n0-9]",
        else => null,
    };
}

/// `\{n,m}` (the `\` already consumed; `i` is just past the `{`). Vim
/// closes it with `}` or `\}`. `\{-…}` is the non-greedy form.
fn brace(w: *Writer, pat: []const u8, i_in: usize) Error!usize {
    var i = i_in;
    var lazy = false;
    if (i < pat.len and pat[i] == '-') {
        lazy = true;
        i += 1;
    }
    const body_start = i;
    while (i < pat.len and pat[i] != '}') : (i += 1) {}
    if (i >= pat.len) return error.Invalid;
    var body = pat[body_start..i];
    if (body.len > 0 and body[body.len - 1] == '\\') body = body[0 .. body.len - 1];
    i += 1;
    for (body) |b| if (!(std.ascii.isDigit(b) or b == ',')) return error.Invalid;
    if (body.len == 0) {
        try w.put("*");
    } else if (std.mem.indexOfScalar(u8, body, ',')) |comma| {
        const lo = body[0..comma];
        const hi = body[comma + 1 ..];
        try w.put("{");
        try w.put(if (lo.len == 0) "0" else lo);
        try w.put(",");
        try w.put(hi);
        try w.put("}");
    } else {
        try w.put("{");
        try w.put(body);
        try w.put("}");
    }
    if (lazy) try w.put("?");
    return i;
}

/// `\@=` `\@!` `\@<=` `\@<!` `\@>` after an atom: wrap the atom.
fn lookaround(w: *Writer, pat: []const u8, i_in: usize) Error!usize {
    var i = i_in;
    if (i >= pat.len) return error.Invalid;
    const start = w.last_atom orelse return error.Invalid;
    var open: []const u8 = undefined;
    switch (pat[i]) {
        '=' => open = "(?=",
        '!' => open = "(?!",
        '>' => open = "(?>",
        '<' => {
            i += 1;
            if (i >= pat.len) return error.Invalid;
            open = switch (pat[i]) {
                '=' => "(?<=",
                '!' => "(?<!",
                else => return error.Invalid,
            };
        },
        else => return error.Invalid,
    }
    i += 1;
    // Oniguruma refuses a capture inside a lookbehind: `\(foo\)\@<=`
    // becomes `(?<=(?:foo))`. The group no longer counts for `\1`.
    const behind = open.len == 4;
    if (behind and w.len > start + 1 and w.out[start] == '(' and w.out[start + 1] != '?') try w.insert(start + 1, "?:");
    try w.insert(start, open);
    try w.put(")");
    w.last_atom = start;
    return i;
}

/// `\%(` non-capturing group, `\%^` `\%$` buffer anchors, `\%d` `\%x`
/// `\%o` `\%u` `\%U` numbered chars, `\%[` optional sequence.
fn percent(w: *Writer, pat: []const u8, i_in: usize, branch_start: *bool) Error!usize {
    var i = i_in;
    if (i >= pat.len) return error.Invalid;
    const p = pat[i];
    i += 1;
    switch (p) {
        '(' => {
            if (w.depth >= w.groups.len) return error.TooLong;
            w.groups[w.depth] = w.len;
            w.depth += 1;
            try w.put("(?:");
            branch_start.* = true;
        },
        '^' => try w.put("\\A"),
        '$' => try w.put("\\z"),
        'd', 'x', 'o', 'u', 'U' => {
            const base: u8 = switch (p) {
                'd' => 10,
                'x', 'u', 'U' => 16,
                'o' => 8,
                else => unreachable,
            };
            const start = i;
            while (i < pat.len and std.fmt.charToDigit(pat[i], base) != error.InvalidCharacter) : (i += 1) {}
            if (i == start) return error.Invalid;
            const cp = std.fmt.parseInt(u21, pat[start..i], base) catch return error.Invalid;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch return error.Invalid;
            for (buf[0..n]) |b| try w.literal(b);
            w.last_atom = w.len - n;
        },
        '[' => {
            // `\%[abc]` — `a`, then optionally `b`, then optionally `c`:
            // `(?:a(?:b(?:c)?)?)?`.
            const start = i;
            while (i < pat.len and pat[i] != ']') : (i += 1) {}
            if (i >= pat.len) return error.Invalid;
            const seq = pat[start..i];
            i += 1;
            w.atom();
            for (seq) |b| {
                try w.put("(?:");
                try w.literalNoAtom(b);
            }
            for (seq) |_| try w.put(")?");
        },
        else => return error.Unsupported,
    }
    return i;
}

/// `[...]` starting at `pat[i]` (the `[`). Vim: an unclosed `[` is a
/// literal. Returns the index past `]`.
fn collection(w: *Writer, pat: []const u8, i_in: usize) Error!usize {
    var i = i_in + 1;
    var j = i;
    if (j < pat.len and pat[j] == '^') j += 1;
    if (j < pat.len and pat[j] == ']') j += 1;
    while (j < pat.len and pat[j] != ']') : (j += 1) {
        if (pat[j] == '\\' and j + 1 < pat.len) {
            j += 1;
        } else if (pat[j] == '[' and j + 1 < pat.len and pat[j + 1] == ':') {
            // `[:alpha:]` — its `]` does not close the collection.
            if (std.mem.indexOfPos(u8, pat, j + 2, ":]")) |end| j = end + 1;
        }
    }
    if (j >= pat.len) {
        try w.literal('[');
        return i;
    }
    w.atom();
    try w.put("[");
    if (i < pat.len and pat[i] == '^') {
        try w.put("^");
        i += 1;
    }
    if (i < pat.len and pat[i] == ']') {
        try w.put("\\]");
        i += 1;
    }
    while (i < j) : (i += 1) {
        const c = pat[i];
        if (c == '\\' and i + 1 < j) {
            i += 1;
            switch (pat[i]) {
                'e' => try w.put("\\e"),
                't' => try w.put("\\t"),
                'r' => try w.put("\\r"),
                'n' => try w.put("\\n"),
                'b' => try w.put("\\x08"),
                '\\' => try w.put("\\\\"),
                ']' => try w.put("\\]"),
                '^' => try w.put("\\^"),
                '-' => try w.put("\\-"),
                'd' => {
                    const start = i + 1;
                    var k = start;
                    while (k < j and std.ascii.isDigit(pat[k])) : (k += 1) {}
                    const cp = std.fmt.parseInt(u21, pat[start..k], 10) catch return error.Invalid;
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch return error.Invalid;
                    try w.put(buf[0..n]);
                    i = k - 1;
                },
                else => |o| {
                    // Vim keeps both the backslash and the char.
                    try w.put("\\\\");
                    try w.literalInClass(o);
                },
            }
            continue;
        }
        if (c == '[' and i + 1 < j and pat[i + 1] == ':') {
            // A POSIX class `[:alpha:]` passes through.
            const end = std.mem.indexOfPos(u8, pat, i + 2, ":]") orelse {
                try w.put("\\[");
                continue;
            };
            try w.put(pat[i .. end + 2]);
            i = end + 1;
            continue;
        }
        try w.literalInClass(c);
    }
    try w.put("]");
    return j + 1;
}

// ─── tests: translation shapes ──────────────────────────────────────────

const testing = std.testing;

fn tr(pat: []const u8) ![]const u8 {
    const S = struct {
        var buf: [1024]u8 = undefined;
    };
    const r = try translate(pat, &S.buf);
    return r.pattern;
}

test "vim → oniguruma: magic mode quantifiers, groups, alternation" {
    try testing.expectEqualStrings("ab+", try tr("ab\\+"));
    try testing.expectEqualStrings("ab?", try tr("ab\\="));
    try testing.expectEqualStrings("ab?", try tr("ab\\?"));
    try testing.expectEqualStrings("a\\+b", try tr("a+b"));
    try testing.expectEqualStrings("(ab)|c", try tr("\\(ab\\)\\|c"));
    try testing.expectEqualStrings("\\(ab\\)\\|c", try tr("(ab)|c"));
    try testing.expectEqualStrings("a{2,3}", try tr("a\\{2,3}"));
    try testing.expectEqualStrings("a{2,3}?", try tr("a\\{-2,3}"));
    try testing.expectEqualStrings("a{0,3}", try tr("a\\{,3}"));
    try testing.expectEqualStrings("a{2}", try tr("a\\{2\\}"));
    try testing.expectEqualStrings("a*?", try tr("a\\{-}"));
}

test "vim → oniguruma: very magic, nomagic and very nomagic" {
    try testing.expectEqualStrings("(ab)+|c{2}", try tr("\\v(ab)+|c{2}"));
    try testing.expectEqualStrings("a\\(b", try tr("\\va\\(b"));
    try testing.expectEqualStrings("a\\.b.", try tr("\\Ma.b\\."));
    try testing.expectEqualStrings("a\\*b\\.\\[x\\]", try tr("\\Va*b.[x]"));
    try testing.expectEqualStrings("^a\\$b$", try tr("\\V^a$b$"));
}

test "vim → oniguruma: word boundaries, classes, anchors, escapes" {
    try testing.expectEqualStrings("(?<!\\w)(?=\\w)foo(?<=\\w)(?!\\w)", try tr("\\<foo\\>"));
    try testing.expectEqualStrings("[0-9]+[ \\t]*[0-9A-Za-z_]", try tr("\\d\\+\\s*\\w"));
    try testing.expectEqualStrings("^a\\^b$", try tr("^a^b$"));
    try testing.expectEqualStrings("a\\$b", try tr("a$b"));
    try testing.expectEqualStrings("\\.\\*\\[", try tr("\\.\\*\\["));
    try testing.expectEqualStrings("a\\Kb(?=c)", try tr("a\\zsb\\zec"));
    // `\@=` applies to the atom before it — one char unless grouped.
    try testing.expectEqualStrings("fo(?=o)bar", try tr("foo\\@=bar"));
    try testing.expectEqualStrings("(?=(foo))bar", try tr("\\(foo\\)\\@=bar"));
    try testing.expectEqualStrings("(?<!(?:foo))bar", try tr("\\(foo\\)\\@<!bar"));
    try testing.expectEqualStrings("(?:ab)+", try tr("\\%(ab\\)\\+"));
    try testing.expectEqualStrings("\\Aa\\z", try tr("\\%^a\\%$"));
    try testing.expectEqualStrings("[a-z\\]]", try tr("[a-z\\]]"));
    try testing.expectEqualStrings("[^0-9]", try tr("[^0-9]"));
    try testing.expectEqualStrings("\\[abc", try tr("[abc"));
    try testing.expectEqualStrings("(?m:.)*", try tr("\\_.*"));
    try testing.expectEqualStrings("(?:[ab]|\\n)", try tr("\\_[ab]"));
    try testing.expectEqualStrings("(?:a(?:b)?)?", try tr("\\%[ab]"));
    try testing.expectEqualStrings("A", try tr("\\%d65"));
    try testing.expectEqualStrings("(a)\\1", try tr("\\(a\\)\\1"));
}

test "vim → oniguruma: case flags and errors" {
    var buf: [256]u8 = undefined;
    const a = try translate("\\cfoo", &buf);
    try testing.expectEqualStrings("foo", a.pattern);
    try testing.expectEqual(@as(?bool, true), a.ignore_case);
    const b = try translate("foo\\C", &buf);
    try testing.expectEqual(@as(?bool, false), b.ignore_case);
    try testing.expectError(error.Invalid, translate("\\(ab", &buf));
    try testing.expectError(error.Invalid, translate("ab\\)", &buf));
    try testing.expectError(error.Invalid, translate("ab\\", &buf));
    try testing.expectError(error.Unsupported, translate("a\\&b", &buf));
    try testing.expectError(error.Unsupported, translate("\\%V", &buf));
    var tiny: [3]u8 = undefined;
    try testing.expectError(error.TooLong, translate("\\<foo\\>", &tiny));
}
