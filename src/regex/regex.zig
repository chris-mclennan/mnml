//! The one regex interface: `compile(pattern, opts)` → `Regex`,
//! `find(haystack, from)` → `?Match`, `deinit`. The find bar, `:s` and
//! the grep pane's filter all come through here and never see the
//! engine. Patterns are vim's (`src/regex/vim.zig` translates); the
//! engine is Oniguruma, ghostty's vendored `pkg/oniguruma`.
//!
//! Oniguruma is initialised once per process, on the first compile,
//! behind a mutex — a worker (the in-process grep) may compile on its
//! own thread. A compiled `Regex` is used from the thread that made it.

const std = @import("std");
const onig = @import("oniguruma");
pub const vim = @import("vim.zig");

pub const Error = error{
    /// Vim syntax this translation does not cover (`\&`, `\%V`…).
    Unsupported,
    /// Malformed (an unclosed group, a bad `\{`), or Oniguruma refused it.
    InvalidPattern,
    /// Longer than the translation buffer allows (a few KiB).
    TooLong,
    OutOfMemory,
};

/// How a pattern is written. `.vim`: vim's magic syntax, translated
/// (`\|`, `\+`, `\{n}` — what `/`, `:s` and the vim profile's find bar
/// take). `.perl`: the Perl-style syntax a regex find in the standard
/// profile takes as typed — `a|b`, `\d+`, `x{3}`, `(…)` — handed to the
/// engine as is; `^` / `$` still anchor at each line.
pub const Dialect = enum { vim, perl };

pub const Options = struct {
    /// Case-insensitive unless the pattern itself says `\C` (vim). A
    /// `\c` in the pattern wins the other way.
    ignore_case: bool = false,
    dialect: Dialect = .vim,
};

pub const Range = struct { start: usize, end: usize };

/// Groups 1–9 follow vim's `\1`–`\9`; a group that did not take part
/// is null.
pub const max_groups = 9;

pub const Match = struct {
    start: usize,
    end: usize,
    groups: [max_groups]?Range = .{null} ** max_groups,

    pub fn group(m: Match, n: usize) ?Range {
        if (n == 0) return .{ .start = m.start, .end = m.end };
        if (n > max_groups) return null;
        return m.groups[n - 1];
    }
};

/// The longest translated pattern accepted.
pub const max_pattern = 4096;
/// The vim → Oniguruma translation on its own, for a caller that hands
/// the pattern to an external engine (`git grep -P`, `rg`).
pub const translate = vim.translate;

/// 0 = not yet, 1 = another thread is doing it, 2 = done. No `Io` is
/// in reach here (a compile has none), so this is an atomic hand-off
/// rather than an `Io.Mutex`; the wait is a few loads at most.
var init_state: std.atomic.Value(u8) = .init(0);

/// Oniguruma's global set-up, once per process.
pub fn ensureInit() Error!void {
    while (true) {
        switch (init_state.load(.acquire)) {
            2 => return,
            1 => std.atomic.spinLoopHint(),
            else => {
                if (init_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) continue;
                onig.init(&.{onig.Encoding.utf8}) catch {
                    init_state.store(0, .release);
                    return error.OutOfMemory;
                };
                init_state.store(2, .release);
                return;
            },
        }
    }
}

pub const Regex = struct {
    inner: onig.Regex,
    /// What the compile decided, for a caller that reports it.
    ignore_case: bool,

    pub fn compile(pattern: []const u8, opts: Options) Error!Regex {
        try ensureInit();
        var buf: [max_pattern]u8 = undefined;
        const tr: vim.Result = switch (opts.dialect) {
            .vim => vim.translate(pattern, &buf) catch |err| return switch (err) {
                error.TooLong => error.TooLong,
                error.Unsupported => error.Unsupported,
                error.Invalid => error.InvalidPattern,
            },
            .perl => .{ .pattern = pattern, .ignore_case = null },
        };
        const ignore_case = tr.ignore_case orelse opts.ignore_case;
        const inner = onig.Regex.init(tr.pattern, .{ .ignorecase = ignore_case }, onig.Encoding.utf8, onig.Syntax.default, null) catch |err| return switch (err) {
            error.Memory => error.OutOfMemory,
            else => error.InvalidPattern,
        };
        return .{ .inner = inner, .ignore_case = ignore_case };
    }

    pub fn deinit(self: *Regex) void {
        self.inner.deinit();
    }

    /// The first match starting at or after `from`. Lookbehind sees
    /// the text before `from`.
    pub fn find(self: *Regex, haystack: []const u8, from: usize) ?Match {
        if (from > haystack.len) return null;
        var region: onig.Region = .{};
        defer region.deinit();
        _ = self.inner.searchAdvanced(haystack, from, haystack.len, &region, .{}) catch return null;
        const starts = region.starts();
        const ends = region.ends();
        if (starts.len == 0 or starts[0] < 0) return null;
        var m: Match = .{ .start = @intCast(starts[0]), .end = @intCast(ends[0]) };
        var g: usize = 1;
        while (g < starts.len and g <= max_groups) : (g += 1) {
            if (starts[g] >= 0) m.groups[g - 1] = .{ .start = @intCast(starts[g]), .end = @intCast(ends[g]) };
        }
        return m;
    }

    /// Every non-overlapping match, left to right. An empty match
    /// advances one byte so the scan always ends.
    pub fn findAll(self: *Regex, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Range), haystack: []const u8) std.mem.Allocator.Error!void {
        var from: usize = 0;
        while (from <= haystack.len) {
            const m = self.find(haystack, from) orelse break;
            try out.append(gpa, .{ .start = m.start, .end = m.end });
            from = if (m.end > m.start) m.end else m.end + 1;
        }
    }
};

/// Expand a vim `:s` replacement against `m` into `out`: `&` / `\0`
/// the whole match, `\1`–`\9` the groups, `\n` a newline, `\t` a tab,
/// `\\` a backslash, `\&` a literal `&`, `\u` `\l` `\U` `\L` `\E` the
/// case operators, `\r` a newline. Anything else after a backslash is
/// kept without the backslash.
pub fn expandReplacement(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), rep: []const u8, haystack: []const u8, m: Match) std.mem.Allocator.Error!void {
    const CaseOp = enum { none, upper_one, lower_one, upper_all, lower_all };
    var mode: CaseOp = .none;
    var i: usize = 0;
    while (i < rep.len) : (i += 1) {
        const c = rep[i];
        if (c == '&') {
            try putCased(gpa, out, haystack[m.start..m.end], &mode);
            continue;
        }
        if (c != '\\' or i + 1 >= rep.len) {
            try putCased(gpa, out, &.{c}, &mode);
            continue;
        }
        i += 1;
        switch (rep[i]) {
            '0'...'9' => |d| {
                if (m.group(d - '0')) |r| try putCased(gpa, out, haystack[r.start..r.end], &mode);
            },
            'n', 'r' => try out.append(gpa, '\n'),
            't' => try out.append(gpa, '\t'),
            '&' => try out.append(gpa, '&'),
            'u' => mode = .upper_one,
            'l' => mode = .lower_one,
            'U' => mode = .upper_all,
            'L' => mode = .lower_all,
            'E', 'e' => mode = .none,
            else => |o| try putCased(gpa, out, &.{o}, &mode),
        }
    }
}

/// Expand a Perl-style replacement (the standard profile's find bar):
/// `$&` / `$0` the whole match, `$1`–`$9` the groups, `$$` a dollar,
/// `\n` a newline, `\t` a tab, `\\` a backslash; anything else as typed.
pub fn expandReplacementPerl(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), rep: []const u8, haystack: []const u8, m: Match) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < rep.len) : (i += 1) {
        const c = rep[i];
        if (i + 1 < rep.len and c == '$') {
            switch (rep[i + 1]) {
                '&', '0'...'9' => |d| {
                    const g: usize = if (d == '&') 0 else d - '0';
                    if (m.group(g)) |r| try out.appendSlice(gpa, haystack[r.start..r.end]);
                    i += 1;
                    continue;
                },
                '$' => {
                    try out.append(gpa, '$');
                    i += 1;
                    continue;
                },
                else => {},
            }
        }
        if (i + 1 < rep.len and c == '\\') {
            switch (rep[i + 1]) {
                'n' => try out.append(gpa, '\n'),
                't' => try out.append(gpa, '\t'),
                '\\' => try out.append(gpa, '\\'),
                else => {
                    try out.append(gpa, c);
                    continue;
                },
            }
            i += 1;
            continue;
        }
        try out.append(gpa, c);
    }
}

/// The replacement expansion that goes with `dialect`.
pub fn expandReplacementFor(dialect: Dialect, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), rep: []const u8, haystack: []const u8, m: Match) std.mem.Allocator.Error!void {
    return switch (dialect) {
        .vim => expandReplacement(gpa, out, rep, haystack, m),
        .perl => expandReplacementPerl(gpa, out, rep, haystack, m),
    };
}

fn putCased(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8, mode: anytype) std.mem.Allocator.Error!void {
    for (s) |b| {
        const cased: u8 = switch (mode.*) {
            .none => b,
            .upper_one, .upper_all => std.ascii.toUpper(b),
            .lower_one, .lower_all => std.ascii.toLower(b),
        };
        try out.append(gpa, cased);
        switch (mode.*) {
            .upper_one, .lower_one => mode.* = .none,
            else => {},
        }
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const Case = struct {
    pat: []const u8,
    hay: []const u8,
    /// The matched text of the first match, or null for no match.
    want: ?[]const u8,
    ignore_case: bool = false,
};

/// The conformance table: what a vim user types, what vim would match
/// first. Every row was checked against vim's own `:echo matchstr()`.
const conformance = [_]Case{
    // literals and magic-mode metachars
    .{ .pat = "foo", .hay = "a foo b", .want = "foo" },
    .{ .pat = "f.o", .hay = "fxo", .want = "fxo" },
    .{ .pat = "f.o", .hay = "f\no", .want = null },
    .{ .pat = "fo*", .hay = "fooo!", .want = "fooo" },
    .{ .pat = "fo*", .hay = "f!", .want = "f" },
    .{ .pat = "a+b", .hay = "a+b aab", .want = "a+b" },
    .{ .pat = "a\\+b", .hay = "a+b aab", .want = "aab" },
    .{ .pat = "ab\\=c", .hay = "ac abc", .want = "ac" },
    .{ .pat = "ab\\?c", .hay = "abc", .want = "abc" },
    .{ .pat = "a(b)", .hay = "a(b)", .want = "a(b)" },
    .{ .pat = "a\\(b\\)", .hay = "a(b) ab", .want = "ab" },
    .{ .pat = "cat\\|dog", .hay = "a dog", .want = "dog" },
    .{ .pat = "cat|dog", .hay = "cat|dog", .want = "cat|dog" },
    .{ .pat = "a{2}", .hay = "a{2}", .want = "a{2}" },
    .{ .pat = "a\\{2}", .hay = "aaaa", .want = "aa" },
    .{ .pat = "a\\{2,3}", .hay = "aaaa", .want = "aaa" },
    .{ .pat = "a\\{-2,3}", .hay = "aaaa", .want = "aa" },
    .{ .pat = "a\\{-1,}", .hay = "aaaa", .want = "a" },
    .{ .pat = "a\\{,2}", .hay = "aaaa", .want = "aa" },
    .{ .pat = "a\\{}", .hay = "aaaa", .want = "aaaa" },
    .{ .pat = "x\\{-}", .hay = "xxx", .want = "" },
    .{ .pat = "\\.", .hay = "a.b", .want = "." },
    .{ .pat = "a\\*", .hay = "a*b", .want = "a*" },
    .{ .pat = "\\[x\\]", .hay = "[x]", .want = "[x]" },
    .{ .pat = "\\/", .hay = "a/b", .want = "/" },
    .{ .pat = "\\\\", .hay = "a\\b", .want = "\\" },
    .{ .pat = "a~b", .hay = "a~b", .want = "a~b" },
    // anchors
    .{ .pat = "^foo", .hay = "foo bar", .want = "foo" },
    .{ .pat = "^foo", .hay = "bar foo", .want = null },
    .{ .pat = "^foo", .hay = "bar\nfoo", .want = "foo" },
    .{ .pat = "bar$", .hay = "foo bar", .want = "bar" },
    .{ .pat = "bar$", .hay = "bar\nfoo", .want = "bar" },
    .{ .pat = "a^b", .hay = "a^b", .want = "a^b" },
    .{ .pat = "a$b", .hay = "a$b", .want = "a$b" },
    .{ .pat = "\\(^a\\|b$\\)", .hay = "xb", .want = "b" },
    .{ .pat = "\\%^a", .hay = "b\na", .want = null },
    .{ .pat = "a\\%$", .hay = "a\nb a", .want = "a" },
    // word boundaries
    .{ .pat = "\\<is\\>", .hay = "this is it", .want = "is" },
    .{ .pat = "\\<his\\>", .hay = "this his", .want = "his" },
    .{ .pat = "\\<th", .hay = "with this", .want = "th" },
    .{ .pat = "is\\>", .hay = "isn't this", .want = "is" },
    .{ .pat = "\\<x\\>", .hay = "ax xa x", .want = "x" },
    // classes
    .{ .pat = "\\d\\+", .hay = "ab 123 c", .want = "123" },
    .{ .pat = "\\D\\+", .hay = "12ab3", .want = "ab" },
    .{ .pat = "\\s\\+", .hay = "a \t b", .want = " \t " },
    .{ .pat = "\\S\\+", .hay = "  ab  ", .want = "ab" },
    .{ .pat = "\\w\\+", .hay = "--ab_1--", .want = "ab_1" },
    .{ .pat = "\\W\\+", .hay = "ab--cd", .want = "--" },
    .{ .pat = "\\a\\+", .hay = "12ab34", .want = "ab" },
    .{ .pat = "\\l\\+", .hay = "ABcdEF", .want = "cd" },
    .{ .pat = "\\u\\+", .hay = "abCDef", .want = "CD" },
    .{ .pat = "\\x\\+", .hay = "zz1fZz", .want = "1f" },
    .{ .pat = "\\o\\+", .hay = "9017", .want = "017" },
    .{ .pat = "\\h\\w*", .hay = "9 _a1", .want = "_a1" },
    .{ .pat = "\\i\\+", .hay = "--foo_9--", .want = "foo_9" },
    .{ .pat = "\\k\\+", .hay = "  bar  ", .want = "bar" },
    .{ .pat = "\\_s\\+", .hay = "a \n b", .want = " \n " },
    .{ .pat = "a\\_.b", .hay = "a\nb", .want = "a\nb" },
    .{ .pat = "a\\nb", .hay = "a\nb", .want = "a\nb" },
    .{ .pat = "a\\tb", .hay = "a\tb", .want = "a\tb" },
    // collections
    .{ .pat = "[abc]\\+", .hay = "xxcabx", .want = "cab" },
    .{ .pat = "[^abc]\\+", .hay = "abxyzc", .want = "xyz" },
    .{ .pat = "[a-c]\\+", .hay = "xxcabx", .want = "cab" },
    .{ .pat = "[]a]\\+", .hay = "x]a]x", .want = "]a]" },
    .{ .pat = "[a\\]]\\+", .hay = "x]a]x", .want = "]a]" },
    .{ .pat = "[[:digit:]]\\+", .hay = "ab12", .want = "12" },
    .{ .pat = "[\\t ]\\+", .hay = "a \tb", .want = " \t" },
    .{ .pat = "[abc", .hay = "x[abc", .want = "[abc" },
    .{ .pat = "[.]", .hay = "a.b", .want = "." },
    .{ .pat = "[a-z]*", .hay = "123", .want = "" },
    // very magic
    .{ .pat = "\\v(foo|bar)+", .hay = "xfoobarx", .want = "foobar" },
    .{ .pat = "\\va{2,3}", .hay = "aaaa", .want = "aaa" },
    .{ .pat = "\\v<is>", .hay = "this is", .want = "is" },
    .{ .pat = "\\vab?c", .hay = "ac", .want = "ac" },
    .{ .pat = "\\va=c", .hay = "c", .want = "c" },
    .{ .pat = "\\va\\+b", .hay = "a+b aab", .want = "a+b" },
    .{ .pat = "\\v\\(x\\)", .hay = "(x)", .want = "(x)" },
    .{ .pat = "\\v^\\s*#", .hay = "  # c", .want = "  #" },
    .{ .pat = "\\v(\\d+)-(\\d+)", .hay = "10-20", .want = "10-20" },
    .{ .pat = "\\v[a-z]+\\.zig", .hay = "main.zig", .want = "main.zig" },
    // nomagic / very nomagic
    .{ .pat = "\\Ma.b", .hay = "a.b axb", .want = "a.b" },
    .{ .pat = "\\Ma\\.b", .hay = "a.b axb", .want = "a.b" },
    .{ .pat = "\\Ma*b", .hay = "a*b aab", .want = "a*b" },
    .{ .pat = "\\Va.*b", .hay = "a.*b", .want = "a.*b" },
    .{ .pat = "\\V[x]", .hay = "[x]", .want = "[x]" },
    .{ .pat = "\\V^a", .hay = "ba\na", .want = "a" },
    // groups, backreferences, lookaround, \zs \ze
    .{ .pat = "\\(ab\\)\\1", .hay = "abab", .want = "abab" },
    .{ .pat = "\\(a\\)\\(b\\)\\2\\1", .hay = "abba", .want = "abba" },
    .{ .pat = "\\%(ab\\)\\+", .hay = "ababc", .want = "abab" },
    .{ .pat = "foo\\zsbar", .hay = "foobar", .want = "bar" },
    .{ .pat = "foo\\zebar", .hay = "foobar", .want = "foo" },
    .{ .pat = "foo\\zebar", .hay = "foobaz", .want = null },
    .{ .pat = "foo\\(bar\\)\\@=", .hay = "foobar", .want = "foo" },
    .{ .pat = "foo\\(bar\\)\\@!", .hay = "foobar foobaz", .want = "foo" },
    .{ .pat = "\\(foo\\)\\@<=bar", .hay = "foobar", .want = "bar" },
    .{ .pat = "\\(foo\\)\\@<!bar", .hay = "foobar xbar", .want = "bar" },
    .{ .pat = "\\%[abc]d", .hay = "xabd", .want = "abd" },
    .{ .pat = "\\%d65\\%x42", .hay = "xAB", .want = "AB" },
    // case
    .{ .pat = "\\cfoo", .hay = "FOO", .want = "FOO" },
    .{ .pat = "foo\\C", .hay = "FOO foo", .want = "foo" },
    .{ .pat = "foo", .hay = "FOO", .want = "FOO", .ignore_case = true },
    .{ .pat = "foo\\C", .hay = "FOO foo", .want = "foo", .ignore_case = true },
    .{ .pat = "[a-c]", .hay = "B", .want = "B", .ignore_case = true },
    // utf-8
    .{ .pat = "é.", .hay = "café!", .want = "é!" },
    .{ .pat = "\\<über\\>", .hay = "x über y", .want = "über" },
    .{ .pat = ".", .hay = "日本", .want = "日" },
};

test "regex: vim-pattern conformance table" {
    try testing.expect(conformance.len >= 60);
    for (conformance, 0..) |c, i| {
        var re = Regex.compile(c.pat, .{ .ignore_case = c.ignore_case }) catch |err| {
            std.debug.print("row {d}: pattern {s}: {s}\n", .{ i, c.pat, @errorName(err) });
            return err;
        };
        defer re.deinit();
        const m = re.find(c.hay, 0);
        if (c.want) |want| {
            if (m == null) {
                std.debug.print("row {d}: pattern {s} on {s}: no match, wanted {s}\n", .{ i, c.pat, c.hay, want });
                return error.TestUnexpectedResult;
            }
            const got = c.hay[m.?.start..m.?.end];
            if (!std.mem.eql(u8, got, want)) {
                std.debug.print("row {d}: pattern {s} on {s}: got {s}, wanted {s}\n", .{ i, c.pat, c.hay, got, want });
                return error.TestUnexpectedResult;
            }
        } else if (m != null) {
            std.debug.print("row {d}: pattern {s} on {s}: matched {s}, wanted none\n", .{ i, c.pat, c.hay, c.hay[m.?.start..m.?.end] });
            return error.TestUnexpectedResult;
        }
    }
}

test "regex: find from an offset, findAll, groups, and the error kinds" {
    var re = try Regex.compile("\\(\\d\\+\\)-\\(\\d\\+\\)", .{});
    defer re.deinit();
    const hay = "1-2 and 30-40";
    const a = re.find(hay, 0).?;
    try testing.expectEqualStrings("1-2", hay[a.start..a.end]);
    try testing.expectEqualStrings("1", hay[a.group(1).?.start..a.group(1).?.end]);
    try testing.expectEqualStrings("2", hay[a.group(2).?.start..a.group(2).?.end]);
    try testing.expect(a.group(3) == null);
    const b = re.find(hay, 1).?;
    try testing.expectEqualStrings("30-40", hay[b.start..b.end]);
    try testing.expect(re.find(hay, 12) == null);
    var all: std.ArrayListUnmanaged(Range) = .empty;
    defer all.deinit(testing.allocator);
    try re.findAll(testing.allocator, &all, hay);
    try testing.expectEqual(@as(usize, 2), all.items.len);
    // An empty match still advances.
    var star = try Regex.compile("x*", .{});
    defer star.deinit();
    all.clearRetainingCapacity();
    try star.findAll(testing.allocator, &all, "ab");
    try testing.expectEqual(@as(usize, 3), all.items.len);
    try testing.expectError(error.InvalidPattern, Regex.compile("\\(a", .{}));
    try testing.expectError(error.InvalidPattern, Regex.compile("a\\{x}", .{}));
    try testing.expectError(error.Unsupported, Regex.compile("a\\&b", .{}));
}

test "regex: :s replacement expansion — &, \\0, groups, escapes, case ops" {
    var re = try Regex.compile("\\(\\w\\+\\) \\(\\w\\+\\)", .{});
    defer re.deinit();
    const hay = "hello world";
    const m = re.find(hay, 0).?;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try expandReplacement(testing.allocator, &out, "\\2, \\1!", hay, m);
    try testing.expectEqualStrings("world, hello!", out.items);
    out.clearRetainingCapacity();
    try expandReplacement(testing.allocator, &out, "[&] [\\0] \\& \\\\ \\t|\\n", hay, m);
    try testing.expectEqualStrings("[hello world] [hello world] & \\ \t|\n", out.items);
    out.clearRetainingCapacity();
    try expandReplacement(testing.allocator, &out, "\\u\\1 \\U\\2\\E \\l\\1 \\L\\2", hay, m);
    try testing.expectEqualStrings("Hello WORLD hello world", out.items);
    out.clearRetainingCapacity();
    try expandReplacement(testing.allocator, &out, "\\9x", hay, m);
    try testing.expectEqualStrings("x", out.items);
}

test "regex: the Perl-style dialect takes alternation, \\d, counts and groups as typed; ^ and $ stay line anchors" {
    const t = std.testing;
    const text = "a ERROR x\nb WARN y\ntook 123ms\nok 45ms\n";
    var re = try Regex.compile("ERROR|WARN", .{ .dialect = .perl });
    defer re.deinit();
    var out: std.ArrayListUnmanaged(Range) = .empty;
    defer out.deinit(t.allocator);
    try re.findAll(t.allocator, &out, text);
    try t.expectEqual(@as(usize, 2), out.items.len);
    var re2 = try Regex.compile("took \\d{3}ms", .{ .dialect = .perl });
    defer re2.deinit();
    try t.expect(re2.find(text, 0) != null);
    var re3 = try Regex.compile("\\d+ms$", .{ .dialect = .perl });
    defer re3.deinit();
    out.clearRetainingCapacity();
    try re3.findAll(t.allocator, &out, text);
    try t.expectEqual(@as(usize, 2), out.items.len);
    // The same text is literal to the vim dialect.
    var rv = try Regex.compile("ERROR|WARN", .{});
    defer rv.deinit();
    try t.expect(rv.find(text, 0) == null);
    // `$1` / `$&` in a Perl-style replacement.
    var re4 = try Regex.compile("(\\w+) (\\d+)ms", .{ .dialect = .perl });
    defer re4.deinit();
    const m = re4.find(text, 0).?;
    var rep: std.ArrayListUnmanaged(u8) = .empty;
    defer rep.deinit(t.allocator);
    try expandReplacementPerl(t.allocator, &rep, "$2 <$1> [$&] $$", text, m);
    try t.expectEqualStrings("123 <took> [took 123ms] $", rep.items);
}
