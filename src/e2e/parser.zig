//! The `.test` script grammar. One statement per line; `#` comments and
//! blank lines are skipped. Steps drive the editor, expectations assert on
//! the rendered screen or app state:
//!
//! ```text
//! write <relpath> <content>      # seed a fixture in the temp workspace ("\n" → newline)
//! open  <relpath>                # open it in an editor pane (focuses the pane)
//! key   <keyspec>                # send one chord — "ctrl+s", "enter", "down", "esc", "a", …
//! type  <text>                   # type literal text, char by char ("\n" → Enter)
//! command <id>                   # run a registered command by id
//! ex <cmdline>                   # run an ex command — `ex bd!` runs `:bd!`
//! wait  <ms>                     # sleep while ticking (for async/pty steps)
//! snippet <scope> <trig> <expansion>  # seed a [snippets.<scope>] entry
//! shell <cmd>                    # `$SHELL -c` in the workspace; non-zero exit fails
//! ghost <text>                   # inject an AI ghost-text suggestion on the active editor
//! click <x> <y>                  # left-click at screen cell (x,y) — 0-based
//! rightclick <x> <y>             # right-click (context menus)
//! doubleclick <x> <y>            # double-click (row activation)
//! scroll <x> <y> <up|down>       # mouse wheel at (x,y)
//! drag <fx> <fy> <tx> <ty>       # left-button drag, one event per cell
//! expect screen contains <text>  # the rendered screen contains the substring
//! expect screen lacks <text>     # …does not
//! expect dirty <true|false>      # the active editor's dirty flag
//! expect pane <text>             # the active pane's title contains the substring
//! expect highlights at_least <n> # ≥ n syntax spans on the active editor
//! expect file <relpath> contains <text>  # the workspace file contains it
//! expect file <relpath> lacks <text>     # …does not
//! ```
//!
//! `<text>` may be wrapped in `"…"` (one layer stripped); inside it `\n`
//! `\t` `\\` `\"` are unescaped. Anything else is an error that names the
//! line.
//!
//! The leading comment block may carry runner directives:
//! `# requires: network` (skipped unless opted in), `# width: 120` (runs
//! at that width only).

const std = @import("std");
const Allocator = std.mem.Allocator;
const key = @import("../core/key.zig");
const keymap = @import("../core/keymap.zig");

pub const MouseAction = enum { click, right_click, double_click, scroll_up, scroll_down };

pub const Step = union(enum) {
    write: struct { rel: []const u8, content: []const u8 },
    open: []const u8,
    key: key.Key,
    type: []const u8,
    command: []const u8,
    ex: []const u8,
    wait: u64,
    snippet: struct { scope: []const u8, trigger: []const u8, expansion: []const u8 },
    shell: []const u8,
    ghost: []const u8,
    mouse: struct { x: u16, y: u16, action: MouseAction },
    drag: struct { from_x: u16, from_y: u16, to_x: u16, to_y: u16 },
};

pub const Check = union(enum) {
    screen_contains: []const u8,
    screen_lacks: []const u8,
    dirty: bool,
    pane_title: []const u8,
    file_contains: struct { rel: []const u8, text: []const u8 },
    file_lacks: struct { rel: []const u8, text: []const u8 },
    highlights_at_least: usize,
};

pub const Stmt = union(enum) {
    step: Step,
    check: Check,
};

pub const Line = struct {
    /// 1-based.
    ln: usize,
    stmt: Stmt,
};

/// Directives from the leading comment block.
pub const Header = struct {
    requires_network: bool = false,
    width: ?u16 = null,
};

/// A parsed script. Every slice lives in `arena`.
pub const Script = struct {
    arena: std.heap.ArenaAllocator,
    header: Header,
    lines: []const Line,

    pub fn deinit(self: *Script) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Why parsing stopped: `line N: …`, ready to print.
pub const Diagnostic = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Diagnostic, comptime fmt: []const u8, args: anytype) error{Syntax} {
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch &self.buf;
        self.len = s.len;
        return error.Syntax;
    }
};

pub const Error = error{ Syntax, OutOfMemory };

pub fn parse(gpa: Allocator, text: []const u8, diag: *Diagnostic) Error!Script {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var lines: std.ArrayList(Line) = .empty;

    var it = std.mem.splitScalar(u8, text, '\n');
    var ln: usize = 0;
    while (it.next()) |raw| {
        ln += 1;
        const line = trim(raw);
        if (line.len == 0 or line[0] == '#') continue;
        const head, const rest = split1(line);
        const stmt: Stmt = if (std.meta.stringToEnum(Keyword, head)) |kw| switch (kw) {
            .write => blk: {
                const rel, const content = split1(rest);
                if (rel.len == 0) return diag.set("line {d}: `write` needs a path", .{ln});
                break :blk .{ .step = .{ .write = .{ .rel = rel, .content = try unescape(a, content) } } };
            },
            .open => blk: {
                if (rest.len == 0) return diag.set("line {d}: `open` needs a path", .{ln});
                break :blk .{ .step = .{ .open = trim(rest) } };
            },
            .key => blk: {
                const spec = trim(rest);
                const k = keymap.parseKeySpec(spec) orelse return diag.set("line {d}: unrecognised key spec `{s}`", .{ ln, spec });
                break :blk .{ .step = .{ .key = k } };
            },
            .type => .{ .step = .{ .type = try unescape(a, rest) } },
            .command => blk: {
                if (rest.len == 0) return diag.set("line {d}: `command` needs an id", .{ln});
                break :blk .{ .step = .{ .command = trim(rest) } };
            },
            .ex => blk: {
                if (rest.len == 0) return diag.set("line {d}: `ex` needs an ex command", .{ln});
                break :blk .{ .step = .{ .ex = trim(rest) } };
            },
            .wait => blk: {
                const ms = std.fmt.parseInt(u64, trim(rest), 10) catch return diag.set("line {d}: `wait` needs a millisecond count", .{ln});
                break :blk .{ .step = .{ .wait = ms } };
            },
            .snippet => blk: {
                const scope, const rest1 = split1(rest);
                const trigger, const expansion = split1(rest1);
                if (scope.len == 0 or trigger.len == 0) return diag.set("line {d}: `snippet` needs <scope> <trigger> <expansion>", .{ln});
                break :blk .{ .step = .{ .snippet = .{ .scope = scope, .trigger = trigger, .expansion = try unescape(a, expansion) } } };
            },
            .shell => blk: {
                const cmd = trim(rest);
                if (cmd.len == 0) return diag.set("line {d}: `shell` needs a command", .{ln});
                break :blk .{ .step = .{ .shell = cmd } };
            },
            .ghost => blk: {
                const s = try unescape(a, rest);
                if (s.len == 0) return diag.set("line {d}: `ghost` needs suggestion text", .{ln});
                break :blk .{ .step = .{ .ghost = s } };
            },
            .click, .rightclick, .doubleclick, .scroll => blk: {
                const xy = try parseXy(diag, ln, head, rest);
                const action: MouseAction = switch (kw) {
                    .click => .click,
                    .rightclick => .right_click,
                    .doubleclick => .double_click,
                    else => if (std.mem.eql(u8, trim(xy.rest), "up"))
                        .scroll_up
                    else if (std.mem.eql(u8, trim(xy.rest), "down"))
                        .scroll_down
                    else
                        return diag.set("line {d}: `scroll X Y <up|down>`", .{ln}),
                };
                break :blk .{ .step = .{ .mouse = .{ .x = xy.x, .y = xy.y, .action = action } } };
            },
            .drag => blk: {
                const from = try parseXy(diag, ln, "drag", rest);
                const to = try parseXy(diag, ln, "drag", from.rest);
                break :blk .{ .step = .{ .drag = .{ .from_x = from.x, .from_y = from.y, .to_x = to.x, .to_y = to.y } } };
            },
            .expect => try parseExpect(a, diag, ln, rest),
        } else return diag.set("line {d}: unknown statement `{s}`", .{ ln, head });
        try lines.append(a, .{ .ln = ln, .stmt = stmt });
    }

    return .{ .arena = arena, .header = parseHeader(text), .lines = try lines.toOwnedSlice(a) };
}

const Keyword = enum { write, open, key, type, command, ex, wait, snippet, shell, ghost, click, rightclick, doubleclick, scroll, drag, expect };

fn parseExpect(a: Allocator, diag: *Diagnostic, ln: usize, rest: []const u8) Error!Stmt {
    const what, const arg = split1(rest);
    const What = enum { screen, dirty, pane, highlights, file };
    const kind = std.meta.stringToEnum(What, what) orelse return diag.set("line {d}: unknown expectation `{s}`", .{ ln, what });
    const check: Check = switch (kind) {
        .screen => blk: {
            const op, const text = split1(arg);
            if (std.mem.eql(u8, op, "contains")) break :blk .{ .screen_contains = try unescape(a, text) };
            if (std.mem.eql(u8, op, "lacks")) break :blk .{ .screen_lacks = try unescape(a, text) };
            return diag.set("line {d}: expect screen <contains|lacks> …", .{ln});
        },
        .dirty => blk: {
            const v = trim(arg);
            if (std.mem.eql(u8, v, "true")) break :blk .{ .dirty = true };
            if (std.mem.eql(u8, v, "false")) break :blk .{ .dirty = false };
            return diag.set("line {d}: expect dirty <true|false>", .{ln});
        },
        .pane => .{ .pane_title = try unescape(a, arg) },
        .highlights => blk: {
            const op, const num = split1(arg);
            if (!std.mem.eql(u8, op, "at_least")) return diag.set("line {d}: expect highlights at_least <N>", .{ln});
            const min = std.fmt.parseInt(usize, trim(num), 10) catch return diag.set("line {d}: expect highlights at_least <usize>", .{ln});
            break :blk .{ .highlights_at_least = min };
        },
        .file => blk: {
            const rel, const rest1 = split1(arg);
            if (rel.len == 0) return diag.set("line {d}: expect file needs a path", .{ln});
            const op, const text = split1(rest1);
            if (std.mem.eql(u8, op, "contains")) break :blk .{ .file_contains = .{ .rel = rel, .text = try unescape(a, text) } };
            if (std.mem.eql(u8, op, "lacks")) break :blk .{ .file_lacks = .{ .rel = rel, .text = try unescape(a, text) } };
            return diag.set("line {d}: expect file <path> <contains|lacks> …", .{ln});
        },
    };
    return .{ .check = check };
}

const Xy = struct { x: u16, y: u16, rest: []const u8 };

fn parseXy(diag: *Diagnostic, ln: usize, kw: []const u8, rest: []const u8) Error!Xy {
    const xs, const r1 = split1(rest);
    const ys, const r2 = split1(r1);
    const x = std.fmt.parseInt(u16, xs, 10) catch return diag.set("line {d}: `{s}` needs `X Y` cell coordinates", .{ ln, kw });
    const y = std.fmt.parseInt(u16, ys, 10) catch return diag.set("line {d}: `{s}` needs `X Y` cell coordinates", .{ ln, kw });
    return .{ .x = x, .y = y, .rest = r2 };
}

const whitespace = " \t\r\n\x0b\x0c";

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, whitespace);
}

/// The first whitespace-delimited token and the rest with leading
/// whitespace removed.
pub fn split1(s_in: []const u8) struct { []const u8, []const u8 } {
    const s = std.mem.trimStart(u8, s_in, whitespace);
    const i = std.mem.indexOfAny(u8, s, whitespace) orelse return .{ s, "" };
    return .{ s[0..i], std.mem.trimStart(u8, s[i..], whitespace) };
}

/// Strip one optional layer of `"…"` and unescape `\n \t \\ \"`. An
/// unknown escape keeps its backslash; a trailing lone backslash stays.
pub fn unescape(a: Allocator, s_in: []const u8) Allocator.Error![]const u8 {
    const s = trim(s_in);
    const inner = if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s[1 .. s.len - 1] else s;
    var out = try std.ArrayList(u8).initCapacity(a, inner.len);
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (c != '\\') {
            out.appendAssumeCapacity(c);
            continue;
        }
        i += 1;
        if (i >= inner.len) {
            out.appendAssumeCapacity('\\');
            break;
        }
        switch (inner[i]) {
            'n' => out.appendAssumeCapacity('\n'),
            't' => out.appendAssumeCapacity('\t'),
            '\\' => out.appendAssumeCapacity('\\'),
            '"' => out.appendAssumeCapacity('"'),
            else => |other| {
                out.appendAssumeCapacity('\\');
                out.appendAssumeCapacity(other);
            },
        }
    }
    return out.toOwnedSlice(a);
}

/// Runner directives from the leading comment block only — the block ends
/// at the first non-comment, non-blank line.
pub fn parseHeader(text: []const u8) Header {
    var h: Header = .{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = trim(raw);
        if (line.len == 0) continue;
        if (line[0] != '#') break;
        const after_hash = trim(std.mem.trimStart(u8, line, "#"));
        if (std.ascii.eqlIgnoreCase(after_hash, "requires: network")) h.requires_network = true;
        if (std.ascii.startsWithIgnoreCase(after_hash, "width:")) {
            h.width = std.fmt.parseInt(u16, trim(after_hash["width:".len..]), 10) catch null;
        }
    }
    return h;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn parseOk(src: []const u8) !Script {
    var diag: Diagnostic = .{};
    return parse(t.allocator, src, &diag) catch |e| {
        std.debug.print("unexpected parse failure: {s}\n", .{diag.message()});
        return e;
    };
}

fn parseErr(src: []const u8) ![]const u8 {
    var diag: Diagnostic = .{};
    var script = parse(t.allocator, src, &diag) catch |e| switch (e) {
        error.Syntax => return t.allocator.dupe(u8, diag.message()),
        else => return e,
    };
    script.deinit();
    return error.TestExpectedError;
}

fn expectErr(src: []const u8, want: []const u8) !void {
    const msg = try parseErr(src);
    defer t.allocator.free(msg);
    try t.expectEqualStrings(want, msg);
}

test "a basic script parses with 1-based line numbers" {
    var s = try parseOk(
        \\# a comment
        \\write foo.txt hello
        \\open foo.txt
        \\type " world"
        \\key ctrl+s
        \\expect screen contains "hello world"
        \\expect dirty false
    );
    defer s.deinit();
    try t.expectEqual(@as(usize, 6), s.lines.len);
    try t.expectEqual(@as(usize, 2), s.lines[0].ln);
    try t.expectEqualStrings("foo.txt", s.lines[0].stmt.step.write.rel);
    try t.expectEqualStrings("hello", s.lines[0].stmt.step.write.content);
    try t.expectEqualStrings("foo.txt", s.lines[1].stmt.step.open);
    try t.expectEqualStrings(" world", s.lines[2].stmt.step.type);
    try t.expect(s.lines[3].stmt.step.key.mods.ctrl);
    try t.expectEqual(@as(u21, 's'), s.lines[3].stmt.step.key.code.char);
    try t.expectEqualStrings("hello world", s.lines[4].stmt.check.screen_contains);
    try t.expectEqual(false, s.lines[5].stmt.check.dirty);
    try t.expectEqual(@as(usize, 7), s.lines[5].ln);
}

test "every step directive" {
    var s = try parseOk(
        \\command editor.use_vim
        \\ex bd!
        \\wait 250
        \\snippet rust fn "fn $1() {\n}"
        \\shell git init -q .
        \\ghost "a + b"
        \\click 12 5
        \\rightclick 3 1
        \\doubleclick 8 8
        \\scroll 40 20 down
        \\scroll 40 20 up
        \\drag 1 2 30 2
        \\write dir/x.txt "l1\nl2\ttab \"q\" \\ \z"
    );
    defer s.deinit();
    const L = s.lines;
    try t.expectEqualStrings("editor.use_vim", L[0].stmt.step.command);
    try t.expectEqualStrings("bd!", L[1].stmt.step.ex);
    try t.expectEqual(@as(u64, 250), L[2].stmt.step.wait);
    try t.expectEqualStrings("rust", L[3].stmt.step.snippet.scope);
    try t.expectEqualStrings("fn", L[3].stmt.step.snippet.trigger);
    try t.expectEqualStrings("fn $1() {\n}", L[3].stmt.step.snippet.expansion);
    try t.expectEqualStrings("git init -q .", L[4].stmt.step.shell);
    try t.expectEqualStrings("a + b", L[5].stmt.step.ghost);
    try t.expectEqual(MouseAction.click, L[6].stmt.step.mouse.action);
    try t.expectEqual(@as(u16, 12), L[6].stmt.step.mouse.x);
    try t.expectEqual(@as(u16, 5), L[6].stmt.step.mouse.y);
    try t.expectEqual(MouseAction.right_click, L[7].stmt.step.mouse.action);
    try t.expectEqual(MouseAction.double_click, L[8].stmt.step.mouse.action);
    try t.expectEqual(MouseAction.scroll_down, L[9].stmt.step.mouse.action);
    try t.expectEqual(@as(u16, 40), L[9].stmt.step.mouse.x);
    try t.expectEqual(MouseAction.scroll_up, L[10].stmt.step.mouse.action);
    try t.expectEqual(@as(u16, 30), L[11].stmt.step.drag.to_x);
    try t.expectEqual(@as(u16, 2), L[11].stmt.step.drag.from_y);
    try t.expectEqualStrings("dir/x.txt", L[12].stmt.step.write.rel);
    try t.expectEqualStrings("l1\nl2\ttab \"q\" \\ \\z", L[12].stmt.step.write.content);
}

test "every expectation" {
    var s = try parseOk(
        \\expect screen contains "x"
        \\expect screen lacks y z
        \\expect dirty true
        \\expect pane "notes.txt"
        \\expect highlights at_least 12
        \\expect file out.txt contains "a\nb"
        \\expect file out.txt lacks gone
    );
    defer s.deinit();
    const L = s.lines;
    try t.expectEqualStrings("x", L[0].stmt.check.screen_contains);
    try t.expectEqualStrings("y z", L[1].stmt.check.screen_lacks);
    try t.expectEqual(true, L[2].stmt.check.dirty);
    try t.expectEqualStrings("notes.txt", L[3].stmt.check.pane_title);
    try t.expectEqual(@as(usize, 12), L[4].stmt.check.highlights_at_least);
    try t.expectEqualStrings("out.txt", L[5].stmt.check.file_contains.rel);
    try t.expectEqualStrings("a\nb", L[5].stmt.check.file_contains.text);
    try t.expectEqualStrings("gone", L[6].stmt.check.file_lacks.text);
}

test "errors name the line and the directive" {
    try expectErr("open x\nfrobnicate 1\n", "line 2: unknown statement `frobnicate`");
    try expectErr("write\n", "line 1: `write` needs a path");
    try expectErr("open   \n", "line 1: `open` needs a path");
    try expectErr("key ctrl+nope+x\n", "line 1: unrecognised key spec `ctrl+nope+x`");
    try expectErr("command\n", "line 1: `command` needs an id");
    try expectErr("ex\n", "line 1: `ex` needs an ex command");
    try expectErr("wait soon\n", "line 1: `wait` needs a millisecond count");
    try expectErr("snippet rust\n", "line 1: `snippet` needs <scope> <trigger> <expansion>");
    try expectErr("shell   \n", "line 1: `shell` needs a command");
    try expectErr("ghost   \n", "line 1: `ghost` needs suggestion text");
    try expectErr("click x y\n", "line 1: `click` needs `X Y` cell coordinates");
    try expectErr("scroll 1 2 sideways\n", "line 1: `scroll X Y <up|down>`");
    try expectErr("drag 1 2 3\n", "line 1: `drag` needs `X Y` cell coordinates");
    try expectErr("expect nothing\n", "line 1: unknown expectation `nothing`");
    try expectErr("expect screen equals x\n", "line 1: expect screen <contains|lacks> …");
    try expectErr("expect dirty maybe\n", "line 1: expect dirty <true|false>");
    try expectErr("expect highlights at_most 3\n", "line 1: expect highlights at_least <N>");
    try expectErr("expect highlights at_least many\n", "line 1: expect highlights at_least <usize>");
    try expectErr("expect file\n", "line 1: expect file needs a path");
    try expectErr("expect file a.txt has x\n", "line 1: expect file <path> <contains|lacks> …");
}

test "unescape strips one quote layer and the four escapes" {
    const cases = [_][2][]const u8{
        .{ "\"a\\nb\"", "a\nb" },
        .{ "plain", "plain" },
        .{ "\"tab\\there\"", "tab\there" },
        .{ "  \"padded\"  ", "padded" },
        .{ "\"\"", "" },
        .{ "\"", "\"" },
        .{ "\"\"inner\"\"", "\"inner\"" },
        .{ "a\\\\b", "a\\b" },
        .{ "say \\\"hi\\\"", "say \"hi\"" },
        .{ "keep \\q", "keep \\q" },
        .{ "trailing\\", "trailing\\" },
    };
    for (cases) |c| {
        const got = try unescape(t.allocator, c[0]);
        defer t.allocator.free(got);
        try t.expectEqualStrings(c[1], got);
    }
}

test "split1 splits on the first whitespace run" {
    const a, const b = split1("  write  a b ");
    try t.expectEqualStrings("write", a);
    try t.expectEqualStrings("a b ", b);
    const c, const d = split1("solo");
    try t.expectEqualStrings("solo", c);
    try t.expectEqualStrings("", d);
}

test "header directives come only from the leading comment block" {
    try t.expect(parseHeader("# requires: network\nopen x\n").requires_network);
    try t.expect(parseHeader("#   Requires: Network  \n\n# more\nopen x\n").requires_network);
    try t.expect(!parseHeader("open x\n# requires: network\n").requires_network);
    try t.expectEqual(@as(?u16, 120), parseHeader("# width: 120\n").width);
    try t.expectEqual(@as(?u16, null), parseHeader("# width: wide\n").width);
}

test "CRLF and blank lines are tolerated" {
    var s = try parseOk("open a.txt\r\n\r\n  # indented comment\r\nexpect dirty false\r\n");
    defer s.deinit();
    try t.expectEqual(@as(usize, 2), s.lines.len);
    try t.expectEqualStrings("a.txt", s.lines[0].stmt.step.open);
    try t.expectEqual(@as(usize, 4), s.lines[1].ln);
}
