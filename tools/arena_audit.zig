//! `zig build arena-audit` — a string that dies at the next frame, handed
//! to something that outlives the frame.
//!
//! `FrameArena.begin` is `reset(.retain_capacity)`, so the next frame
//! hands the same bytes back from offset zero. A slice built on
//! `app.frame.allocator()` — or on a `[N]u8` a function is about to
//! return past — is therefore correct for exactly as long as the frame
//! that made it. Give it to a consumer that keeps it (a menu, a prompt
//! title, a confirm box, the screen's grapheme slices) and it paints as
//! garbage on the NEXT frame, only sometimes. Six bugs of that one shape
//! shipped before this file existed; this is the seventh's tripwire.
//!
//! The audit reads `src/**.zig` and, per function scope, tracks where
//! each local string came from:
//!
//!   frame   `app.frame.allocator()`, `ui.arena`, `ui.fmt`, `ui.clipStr`
//!   stack   a local `var buf: [N]u8`, and what `bufPrint` writes into it
//!   owned   an `ArenaAllocator` the function made — a menu's `mem`
//!   gpa     `app.gpa` / `gpa` — the holder frees it
//!
//! then flags a `frame` or `stack` string reaching a consumer that
//! outlives the frame:
//!
//!   menu-label        a `MenuItem`'s `.label` / `.copy_text` / `.open_url`
//!   prompt-title      `openPrompt` (use `openPromptOwned`)
//!   confirm-text      `openConfirm`
//!   dead-stack-paint  `putStr` of a local `[N]u8` — the screen keeps the
//!                     grapheme slice until the frame is flushed
//!   stored-string     an assignment into state that outlives the frame
//!   raw-open-menu     `App.openMenu` + `overlay.menu.mem = …` open-coded
//!                     instead of `context_menus.openOwned`
//!
//! A `ui.fmt` painted in the SAME frame is not a finding — that is what
//! the frame arena is for. Only a consumer that keeps the slice counts.
//!
//! `--strict` exits 1 on any finding; the unit test below walks the real
//! `src/` and asserts zero, so the seventh bug fails `zig build test`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var stdout_buf: [8192]u8 = undefined;
    var stdout_file: Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buf);
    const w = &stdout_file.interface;
    defer w.flush() catch {};
    if (args.len < 2) {
        try w.writeAll("usage: arena-audit <dir> [--strict] [--job-results]\n");
        return 2;
    }
    const strict = for (args[2..]) |a| {
        if (std.mem.eql(u8, a, "--strict")) break true;
    } else false;
    // `--job-results` reads the OTHER shape: a job's result arena let go
    // by the consumer that stored a slice out of it. The frame-arena
    // rules are `src/`-shaped (menus, prompts, the screen); this one
    // travels, which is why `integrations/` and `sdk/` get it alone.
    const job_results = for (args[2..]) |a| {
        if (std.mem.eql(u8, a, "--job-results")) break true;
    } else false;
    const result = if (job_results) try walkJobResults(arena, init.io, args[1]) else try walk(arena, init.io, args[1]);
    if (job_results) try jobReport(w, args[1], result) else try report(w, result);
    return if (strict and result.findings.len > 0) 1 else 0;
}

// ─── what a string is made of ───────────────────────────────────────────

pub const Origin = enum {
    /// A literal, a comptime string, or anything the audit cannot place.
    unknown,
    /// `"…"` in the source.
    literal,
    /// The gpa — the holder frees it. Safe to keep.
    gpa,
    /// A snapshot arena — lives until the dataset is replaced. Safe for a
    /// menu that closes before the next scan; the audit treats it as safe
    /// because `MenuState.title` is duped and rows are re-read per paint.
    snapshot,
    /// An `ArenaAllocator` this function made and handed to the consumer
    /// (`openOwned`'s `mem`). Safe: the consumer frees it.
    owned,
    /// `app.frame.allocator()` / `ui.arena` — gone at the next frame.
    frame,
    /// A local `[N]u8` — gone when the function returns.
    stack,
    /// A background job's RESULT arena, which the consumer lets go on
    /// the way out unless it says otherwise. Gone the moment `commit`
    /// returns.
    result,

    pub fn dies(o: Origin) bool {
        return o == .frame or o == .stack or o == .result;
    }
};

pub const Rule = enum {
    menu_label,
    prompt_title,
    confirm_text,
    dead_stack_paint,
    stored_string,
    raw_open_menu,
    job_result,

    pub fn text(r: Rule) []const u8 {
        return switch (r) {
            .menu_label => "menu-label",
            .prompt_title => "prompt-title",
            .confirm_text => "confirm-text",
            .dead_stack_paint => "dead-stack-paint",
            .stored_string => "stored-string",
            .raw_open_menu => "raw-open-menu",
            .job_result => "job-result",
        };
    }
};

pub const Finding = struct {
    file: []const u8,
    /// 1-based.
    line: u32,
    rule: Rule,
    origin: Origin,
    /// The function the site is in, for the report.
    scope: []const u8,
    /// The offending expression, trimmed.
    expr: []const u8,
};

/// What the audit looked at, so an empty finding list is evidence rather
/// than an absence of evidence.
pub const Counts = struct {
    files: usize = 0,
    scopes: usize = 0,
    menu_labels: usize = 0,
    prompt_calls: usize = 0,
    confirm_calls: usize = 0,
    paints: usize = 0,
    stores: usize = 0,
    /// Switch prongs of a job-result consumer the audit read.
    prongs: usize = 0,
};

pub const Result = struct { findings: []const Finding, counts: Counts };

// ─── the scanner ────────────────────────────────────────────────────────

/// A function body's locals. Rebuilt at every `fn` / `test` declaration —
/// a nested `fn` cannot see the outer locals anyway.
const Scope = struct {
    name: []const u8,
    /// Allocator-valued locals: `const arena = app.frame.allocator();`
    allocs: std.StringHashMapUnmanaged(Origin) = .empty,
    /// String-valued locals.
    strings: std.StringHashMapUnmanaged(Origin) = .empty,
    /// `var buf: [64]u8 = undefined;`
    stack_bufs: std.StringHashMapUnmanaged(void) = .empty,
    /// `var mem = std.heap.ArenaAllocator.init(app.gpa);`
    arena_objs: std.StringHashMapUnmanaged(void) = .empty,
    /// Parameters (and locals) of type `Ui`, whose `.arena` is the frame.
    ui_vars: std.StringHashMapUnmanaged(void) = .empty,
    /// Every `const` / `var` the function declares. A field assignment
    /// onto one of these stays in the function; only a field reached
    /// through something else outlives the frame.
    locals: std.StringHashMapUnmanaged(void) = .empty,
    /// Locals of type `ArrayList…(MenuItem)`: a call that takes one of
    /// these AND a frame allocator is building menu rows on the frame.
    menu_lists: std.StringHashMapUnmanaged(void) = .empty,
    /// The scope builds menu rows, so `.label =` in it is a menu label.
    builds_menu: bool = false,
    /// The scope open-codes `openOwned` (`App.openMenu` + `menu.mem =`).
    raw_open_menu_line: u32 = 0,
    is_test: bool = false,
};

/// Everything after an unquoted `//`.
pub fn stripComment(line: []const u8) []const u8 {
    var i: usize = 0;
    var in_str = false;
    var in_char = false;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '\\' and (in_str or in_char)) {
            i += 1;
            continue;
        }
        if (c == '"' and !in_char) in_str = !in_str;
        if (c == '\'' and !in_str) in_char = !in_char;
        if (!in_str and !in_char and c == '/' and i + 1 < line.len and line[i + 1] == '/') return line[0..i];
    }
    return line;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `needle` as a whole word in `hay`.
pub fn hasWord(hay: []const u8, needle: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, hay, from, needle)) |at| {
        from = at + 1;
        const before_ok = at == 0 or !isIdentChar(hay[at - 1]);
        const end = at + needle.len;
        const after_ok = end >= hay.len or !isIdentChar(hay[end]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

/// `needle` as a whole word that is not a field of something else —
/// `buf` matches `&buf` and `buf[0..n]`, never `e.buf.doc`.
pub fn hasBareWord(hay: []const u8, needle: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, hay, from, needle)) |at| {
        from = at + 1;
        const before_ok = at == 0 or (!isIdentChar(hay[at - 1]) and hay[at - 1] != '.');
        const end = at + needle.len;
        const after_ok = end >= hay.len or !isIdentChar(hay[end]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

/// The receiver immediately left of `at`: `foo.bar` → `foo` for `.bar`.
fn receiverBefore(line: []const u8, at: usize) []const u8 {
    var i = at;
    while (i > 0 and isIdentChar(line[i - 1])) i -= 1;
    return line[i..at];
}

/// The declaration line of a `fn` or a `test`, or null. Matches at any
/// indent so a struct's methods are their own scopes.
pub fn declName(line: []const u8) ?struct { name: []const u8, is_test: bool } {
    const s = std.mem.trim(u8, stripComment(line), " \t");
    if (std.mem.startsWith(u8, s, "test \"") or std.mem.eql(u8, s, "test {")) return .{ .name = "test", .is_test = true };
    var rest = s;
    inline for (.{ "pub ", "export ", "inline ", "noinline ", "extern " }) |kw| {
        if (std.mem.startsWith(u8, rest, kw)) rest = rest[kw.len..];
    }
    // `pub inline fn` and kin: strip once more.
    inline for (.{ "inline ", "noinline ", "export ", "extern " }) |kw| {
        if (std.mem.startsWith(u8, rest, kw)) rest = rest[kw.len..];
    }
    if (!std.mem.startsWith(u8, rest, "fn ")) return null;
    rest = rest["fn ".len..];
    const end = std.mem.indexOfAny(u8, rest, "( ") orelse return null;
    return .{ .name = rest[0..end], .is_test = false };
}

/// The bit of `expr` that is the first call argument, or the whole thing.
fn firstArg(expr: []const u8) []const u8 {
    const open = std.mem.indexOfScalar(u8, expr, '(') orelse return expr;
    var depth: usize = 0;
    var i = open;
    while (i < expr.len) : (i += 1) {
        switch (expr[i]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                depth -= 1;
                if (depth == 0) return std.mem.trim(u8, expr[open + 1 .. i], " \t");
            },
            ',' => if (depth == 1) return std.mem.trim(u8, expr[open + 1 .. i], " \t"),
            else => {},
        }
    }
    return std.mem.trim(u8, expr[open + 1 ..], " \t");
}

/// The arguments of the first call in `expr`, split at depth 1.
fn argsOf(arena: Allocator, expr: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const open = std.mem.indexOfScalar(u8, expr, '(') orelse return out.toOwnedSlice(arena);
    var depth: usize = 0;
    var start = open + 1;
    var i = open;
    while (i < expr.len) : (i += 1) {
        switch (expr[i]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                depth -= 1;
                if (depth == 0) {
                    try out.append(arena, std.mem.trim(u8, expr[start..i], " \t"));
                    return out.toOwnedSlice(arena);
                }
            },
            ',' => if (depth == 1) {
                try out.append(arena, std.mem.trim(u8, expr[start..i], " \t"));
                start = i + 1;
            },
            else => {},
        }
    }
    if (start < expr.len) try out.append(arena, std.mem.trim(u8, expr[start..], " \t"));
    return out.toOwnedSlice(arena);
}

/// Where the allocator `expr` names allocates from.
fn allocOrigin(sc: *const Scope, expr_in: []const u8) Origin {
    const expr = std.mem.trim(u8, expr_in, " \t&");
    if (std.mem.indexOf(u8, expr, "frame.allocator()") != null) return .frame;
    if (std.mem.indexOf(u8, expr, "snapshot.allocator()") != null) return .snapshot;
    if (std.mem.indexOf(u8, expr, "testing.allocator") != null) return .gpa;
    if (std.mem.endsWith(u8, expr, ".gpa") or std.mem.eql(u8, expr, "gpa")) return .gpa;
    // `ui.arena`, and a `Ui` bound to another name.
    if (std.mem.indexOf(u8, expr, ".arena")) |at| {
        const recv = receiverBefore(expr, at);
        if (std.mem.eql(u8, recv, "ui") or sc.ui_vars.contains(recv)) return .frame;
    }
    // `mem.allocator()` where `mem` is an ArenaAllocator this fn made.
    if (std.mem.indexOf(u8, expr, ".allocator()")) |at| {
        const recv = receiverBefore(expr, at);
        if (sc.arena_objs.contains(recv)) return .owned;
    }
    if (sc.allocs.get(expr)) |o| return o;
    return .unknown;
}

/// Where the string `expr` evaluates to lives.
fn stringOrigin(sc: *const Scope, expr_in: []const u8) Origin {
    var expr = std.mem.trim(u8, expr_in, " \t,");
    inline for (.{ "try ", "await " }) |kw| {
        if (std.mem.startsWith(u8, expr, kw)) expr = std.mem.trimStart(u8, expr[kw.len..], " \t");
    }
    if (expr.len == 0) return .unknown;
    if (expr[0] == '"') return .literal;
    // An `if (…) "a" else "b"` of literals.
    if (std.mem.startsWith(u8, expr, "if (") and std.mem.indexOfScalar(u8, expr, '"') != null and
        std.mem.indexOfAny(u8, expr, "(") != null)
    {
        // Fall through: the branches are classified below by the strongest
        // origin any of them names.
    }

    // The frame-arena helpers on `Ui`.
    if (std.mem.indexOf(u8, expr, ".fmt(")) |at| {
        const recv = receiverBefore(expr, at);
        if (std.mem.eql(u8, recv, "ui") or sc.ui_vars.contains(recv)) return .frame;
    }
    if (std.mem.indexOf(u8, expr, ".clipStr(") != null) return .frame;

    // `std.fmt.bufPrint(&buf, …)` — the buffer decides.
    inline for (.{ "bufPrint(", "bufPrintZ(", "bufPrintIntToSlice(" }) |call| {
        if (std.mem.indexOf(u8, expr, call)) |at| {
            const arg = firstArg(expr[at + call.len - 1 ..]);
            const name = std.mem.trim(u8, arg, " \t&");
            if (sc.stack_bufs.contains(name)) return .stack;
            return .unknown;
        }
    }

    // The allocating builders: their first argument is the allocator.
    inline for (.{ "allocPrint(", "allocPrintZ(", "allocPrintSentinel(", "join(", "concat(", "dupe(", "dupeZ(", "alloc(", "allocSentinel(" }) |call| {
        if (std.mem.indexOf(u8, expr, call)) |at| {
            const o = allocOrigin(sc, firstArg(expr[at + call.len - 1 ..]));
            if (call.len >= 6 and (std.mem.eql(u8, call, "dupe(") or std.mem.eql(u8, call, "dupeZ(") or std.mem.eql(u8, call, "alloc(") or std.mem.eql(u8, call, "allocSentinel("))) {
                // `a.dupe(u8, s)` — the allocator is the receiver.
                const recv = receiverBefore(expr, at -| 1);
                const ro = allocOrigin(sc, recv);
                if (ro != .unknown) return ro;
            }
            if (o != .unknown) return o;
        }
    }

    // A bare local, or a slice of one.
    const name = identHead(expr);
    if (sc.stack_bufs.contains(name)) return .stack;
    if (sc.strings.get(name)) |o| return o;
    if (sc.strings.get(expr)) |o| return o;

    // An `if`/`switch` expression: the worst branch wins, so a frame or a
    // stack name anywhere in it is the answer.
    var it = std.mem.tokenizeAny(u8, expr, " \t()[]{},.!?:;=");
    var worst: Origin = .unknown;
    while (it.next()) |tok| {
        if (sc.stack_bufs.contains(tok)) return .stack;
        if (sc.strings.get(tok)) |o| if (o.dies()) {
            worst = o;
        };
    }
    return worst;
}

/// `foo[0..n]` / `foo.bar` / `foo` → `foo`.
fn identHead(expr: []const u8) []const u8 {
    var i: usize = 0;
    while (i < expr.len and isIdentChar(expr[i])) i += 1;
    return expr[0..i];
}

/// `const NAME` / `var NAME` on `line` → NAME and the right-hand side.
fn binding(line: []const u8) ?struct { name: []const u8, rhs: []const u8 } {
    const s = std.mem.trim(u8, line, " \t");
    var rest = s;
    if (std.mem.startsWith(u8, rest, "const ")) rest = rest["const ".len..] else if (std.mem.startsWith(u8, rest, "var ")) rest = rest["var ".len..] else return null;
    const name_end = for (rest, 0..) |c, i| {
        if (!isIdentChar(c)) break i;
    } else return null;
    const name = rest[0..name_end];
    if (name.len == 0) return null;
    const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
    var rhs = std.mem.trim(u8, rest[eq + 1 ..], " \t");
    if (std.mem.endsWith(u8, rhs, ";")) rhs = rhs[0 .. rhs.len - 1];
    return .{ .name = name, .rhs = rhs };
}

/// A `[N]u8` declaration: `var buf: [64]u8 = undefined;`.
fn isStackBuffer(line: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
    const ty = std.mem.trimStart(u8, line[colon + 1 ..], " \t");
    if (!std.mem.startsWith(u8, ty, "[")) return false;
    const close = std.mem.indexOfScalar(u8, ty, ']') orelse return false;
    // `[]const u8` is a slice, not a buffer; `[64]u8` / `[N]u8` is one.
    if (close == 1) return false;
    return std.mem.startsWith(u8, ty[close + 1 ..], "u8");
}

/// The `Ui`-typed names in a declaration line: `fn draw(ui: Ui, …)`.
fn collectUiVars(arena: Allocator, sc: *Scope, line: []const u8) Allocator.Error!void {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, ": Ui")) |at| {
        from = at + 1;
        const after = at + ": Ui".len;
        if (after < line.len and isIdentChar(line[after])) continue;
        try sc.ui_vars.put(arena, receiverBefore(line, at), {});
    }
}

const menu_fields = [_][]const u8{ ".label = ", ".copy_text = ", ".open_url = ", ".insert_text = ", ".set_theme = " };
/// Assignments into state that outlives the frame.
const stored_fields = [_][]const u8{ ".title = ", ".message = ", ".text = ", ".label = ", ".desc = ", ".tooltip = ", ".path = ", ".name = " };
const paint_calls = [_][]const u8{ "putStr(", "putStrRight(", "putStrOverBlend(", ".grapheme = " };

/// Every finding in one file.
pub fn extractFindings(arena: Allocator, file: []const u8, text: []const u8, counts: *Counts) Allocator.Error![]Finding {
    counts.files += 1;
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(arena, stripComment(l));

    // Scope boundaries: every `fn` / `test` declaration starts one.
    var starts: std.ArrayListUnmanaged(usize) = .empty;
    for (lines.items, 0..) |line, i| {
        if (declName(line) != null) try starts.append(arena, i);
    }
    var out: std.ArrayListUnmanaged(Finding) = .empty;
    for (starts.items, 0..) |start, si| {
        const end = if (si + 1 < starts.items.len) starts.items[si + 1] else lines.items.len;
        const decl = declName(lines.items[start]).?;
        if (decl.is_test) continue;
        counts.scopes += 1;
        var sc: Scope = .{ .name = decl.name };
        const body = lines.items[start..end];

        // ── pass 1: the locals, and what the scope is building ──
        try collectUiVars(arena, &sc, lines.items[start]);
        // A signature spilled over several lines.
        var sig = start;
        while (sig < end and sig < start + 8) : (sig += 1) {
            try collectUiVars(arena, &sc, lines.items[sig]);
            if (std.mem.indexOf(u8, lines.items[sig], ") ") != null) break;
        }
        // A draw takes the frame arena and nothing else — D6 hands it one
        // through `Ui`, and a `paintRow` helper beside it takes the same
        // allocator. Elsewhere an `arena: Allocator` parameter is the
        // caller's choice (a menu's own `mem` is passed as `arena` too),
        // so the audit does not guess: it flags the CALL instead, below.
        if (sc.ui_vars.count() > 0 and
            (std.mem.indexOf(u8, lines.items[start], "arena: Allocator") != null or
                std.mem.indexOf(u8, lines.items[start], "arena: std.mem.Allocator") != null))
        {
            try sc.allocs.put(arena, "arena", .frame);
        }
        for (body) |line| {
            if (std.mem.indexOf(u8, line, "MenuItem") != null or
                std.mem.indexOf(u8, line, "openMenu(") != null or
                std.mem.indexOf(u8, line, "openOwned(") != null or
                std.mem.indexOf(u8, line, "openSubMenu(") != null) sc.builds_menu = true;
            const b = binding(line) orelse continue;
            try sc.locals.put(arena, b.name, {});
            if (std.mem.indexOf(u8, line, "MenuItem") != null and std.mem.indexOf(u8, line, "ArrayList") != null) {
                try sc.menu_lists.put(arena, b.name, {});
                continue;
            }
            if (std.mem.indexOf(u8, b.rhs, "ArenaAllocator.init(") != null) {
                try sc.arena_objs.put(arena, b.name, {});
                continue;
            }
            if (isStackBuffer(line)) {
                try sc.stack_bufs.put(arena, b.name, {});
                continue;
            }
            if (std.mem.indexOf(u8, b.rhs, ".allocator()") != null or std.mem.indexOf(u8, b.rhs, ".arena") != null or std.mem.endsWith(u8, b.rhs, ".gpa")) {
                const o = allocOrigin(&sc, b.rhs);
                if (o != .unknown) try sc.allocs.put(arena, b.name, o);
                continue;
            }
            if (std.mem.indexOf(u8, b.rhs, ": Ui") != null or std.mem.indexOf(u8, b.rhs, ".withClip(") != null) {
                try sc.ui_vars.put(arena, b.name, {});
                continue;
            }
            const o = stringOrigin(&sc, b.rhs);
            if (o != .unknown) try sc.strings.put(arena, b.name, o);
        }
        // A stack buffer with no `=` on the line (`var buf: [8]u8 = undefined;`
        // is a binding; `var buf: [8]u8 = .{0} ** 8;` too) — catch the rest.
        for (body) |line| {
            const s = std.mem.trim(u8, line, " \t");
            if (!std.mem.startsWith(u8, s, "var ") and !std.mem.startsWith(u8, s, "const ")) continue;
            if (!isStackBuffer(s)) continue;
            const rest = s[if (std.mem.startsWith(u8, s, "var ")) 4 else 6..];
            const name_end = for (rest, 0..) |c, i| {
                if (!isIdentChar(c)) break i;
            } else continue;
            try sc.stack_bufs.put(arena, rest[0..name_end], {});
        }

        // ── pass 2: the consumers ──
        var saw_raw_open: u32 = 0;
        var saw_menu_mem = false;
        var persist_depth: u32 = 0;
        for (body, 0..) |line, li| {
            const lineno: u32 = @intCast(start + li + 1);

            if (sc.builds_menu) for (menu_fields) |field| {
                const at = std.mem.indexOf(u8, line, field) orelse continue;
                counts.menu_labels += 1;
                const value = valueAfter(line, at + field.len);
                const o = stringOrigin(&sc, value);
                if (o.dies()) try out.append(arena, .{ .file = file, .line = lineno, .rule = .menu_label, .origin = o, .scope = sc.name, .expr = value });
            };

            // The rows built by a helper: a call that is handed both a
            // `MenuItem` list and a frame allocator fills that list with
            // labels the next frame reuses (`appendOrigins(app, arena, &out, l)`).
            if (sc.menu_lists.count() > 0 and std.mem.indexOfScalar(u8, line, '(') != null) {
                const args = try argsOf(arena, line[std.mem.indexOfScalar(u8, line, '(').?..]);
                var takes_list = false;
                var frame_alloc: ?[]const u8 = null;
                for (args) |a| {
                    if (a.len > 1 and a[0] == '&' and sc.menu_lists.contains(a[1..])) takes_list = true;
                    if (allocOrigin(&sc, a) == .frame) frame_alloc = a;
                }
                if (takes_list) if (frame_alloc) |a| {
                    counts.menu_labels += 1;
                    try out.append(arena, .{ .file = file, .line = lineno, .rule = .menu_label, .origin = .frame, .scope = sc.name, .expr = a });
                };
            }

            if (std.mem.indexOf(u8, line, "openPrompt(")) |at| {
                if (!std.mem.endsWith(u8, line[0..at], "Owned") and std.mem.indexOf(u8, line, "openPromptOwned(") == null) {
                    counts.prompt_calls += 1;
                    for (try argsOf(arena, line[at..])) |a| {
                        const o = stringOrigin(&sc, a);
                        if (o.dies()) try out.append(arena, .{ .file = file, .line = lineno, .rule = .prompt_title, .origin = o, .scope = sc.name, .expr = a });
                    }
                }
            }
            if (std.mem.indexOf(u8, line, "openConfirm(")) |at| {
                counts.confirm_calls += 1;
                for (try argsOf(arena, line[at..])) |a| {
                    const o = stringOrigin(&sc, a);
                    if (o.dies()) try out.append(arena, .{ .file = file, .line = lineno, .rule = .confirm_text, .origin = o, .scope = sc.name, .expr = a });
                }
            }

            for (paint_calls) |call| {
                const at = std.mem.indexOf(u8, line, call) orelse continue;
                counts.paints += 1;
                const args = if (call[0] == '.') &[_][]const u8{valueAfter(line, at + call.len)} else try argsOf(arena, line[at + call.len - 1 ..]);
                for (args) |a| {
                    // The frame arena is exactly what a paint may use; only a
                    // buffer the function is about to return past is dead.
                    if (stringOrigin(&sc, a) == .stack) try out.append(arena, .{ .file = file, .line = lineno, .rule = .dead_stack_paint, .origin = .stack, .scope = sc.name, .expr = a });
                }
            }

            // Inside a draw, a local `[N]u8` may only be written into,
            // measured, compared, or copied onto the frame arena. Anything
            // else hands the painter a slice that is gone before the frame
            // is flushed — `rightAlign(arena, commitDateTime(&buf, …), …)`
            // returns its argument when the text already fills the column.
            if (sc.ui_vars.count() > 0 and sc.stack_bufs.count() > 0 and escapesStackBuffer(&sc, line)) {
                counts.paints += 1;
                try out.append(arena, .{ .file = file, .line = lineno, .rule = .dead_stack_paint, .origin = .stack, .scope = sc.name, .expr = std.mem.trim(u8, line, " \t") });
            }

            if (storedAssignment(line)) |asg| {
                counts.stores += 1;
                const o = stringOrigin(&sc, asg.rhs);
                if (o.dies()) try out.append(arena, .{ .file = file, .line = lineno, .rule = .stored_string, .origin = o, .scope = sc.name, .expr = asg.rhs });
            }

            // `app.overlay = .{ .confirm = .{ .state = .{ .title = … } } };`
            // — the struct literal assigned INTO state. Its strings live
            // as long as the overlay, so the frame arena is the wrong
            // tier even nested four braces deep.
            if (persist_depth == 0 and persistTarget(&sc, line)) persist_depth = 1;
            if (persist_depth > 0) {
                for (stored_fields) |field| {
                    const at = std.mem.indexOf(u8, line, field) orelse continue;
                    if (receiverBefore(line, at).len != 0) continue; // an lvalue, handled above
                    counts.stores += 1;
                    const value = valueAfter(line, at + field.len);
                    const o = stringOrigin(&sc, value);
                    if (o.dies()) try out.append(arena, .{ .file = file, .line = lineno, .rule = .stored_string, .origin = o, .scope = sc.name, .expr = value });
                }
                const d = braceDelta(line);
                persist_depth = if (d < 0 and @abs(d) >= persist_depth) 0 else @intCast(@as(i32, @intCast(persist_depth)) + d);
                if (std.mem.endsWith(u8, std.mem.trim(u8, line, " \t"), ";")) persist_depth = 0;
            }

            if (std.mem.indexOf(u8, line, ".openMenu(") != null and !std.mem.endsWith(u8, file, "context_menus.zig")) saw_raw_open = lineno;
            if (std.mem.indexOf(u8, line, "menu.mem = ") != null) saw_menu_mem = true;
        }
        if (saw_raw_open != 0 and saw_menu_mem) try out.append(arena, .{ .file = file, .line = saw_raw_open, .rule = .raw_open_menu, .origin = .owned, .scope = sc.name, .expr = "App.openMenu + overlay.menu.mem" });
    }
    return out.toOwnedSlice(arena);
}

/// The value between `at` and the `,` or `}` that closes the field.
fn valueAfter(line: []const u8, at: usize) []const u8 {
    var depth: usize = 0;
    var i = at;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth == 0) return std.mem.trim(u8, line[at..i], " \t");
                depth -= 1;
            },
            '"' => {
                i += 1;
                while (i < line.len and line[i] != '"') : (i += 1) {
                    if (line[i] == '\\') i += 1;
                }
            },
            ',', ';' => if (depth == 0) return std.mem.trim(u8, line[at..i], " \t"),
            else => {},
        }
    }
    return std.mem.trim(u8, line[at..], " \t");
}

/// What a local `[N]u8` may legitimately appear in: something writing
/// into it, measuring it, comparing it, or copying it somewhere that
/// outlives it.
const stack_sinks = [_][]const u8{
    "bufPrint",           "bufPrintZ",    "realPath",  "realpath",   "dupe(",       "dupeZ(",
    "eql(",               "startsWith(",  "endsWith(", "indexOf",    "lastIndexOf", "parseInt",
    "@memcpy",            "undefined",    "readFile",  "readAll",    "cwd()",       "formatInt",
    "bufPrintIntToSlice", "join(",        "concat(",   "allocPrint", "print(",      "writeAll(",
    "append(",            "appendSlice(", "trim",      "fmtSlice",   "hash(",       "fill(",
    "toOwnedSlice",       "splitScalar",  "tokenize",  "openDir",    "openFile",    "statFile",
    "makePath",           "access(",      "= .{",      "@splat",     "@memset",     ".fmt(",
};

/// A line in a draw that lets a local `[N]u8` escape into something that
/// keeps the slice. `&buf` / `buf[0..n]` / a call taking one of them,
/// with no sink on the line that makes it safe.
fn escapesStackBuffer(sc: *const Scope, line: []const u8) bool {
    var it = sc.stack_bufs.keyIterator();
    const mentions = while (it.next()) |k| {
        if (hasBareWord(line, k.*)) break true;
    } else false;
    if (!mentions) return false;
    for (stack_sinks) |sink| if (std.mem.indexOf(u8, line, sink) != null) return false;
    // A declaration of the buffer itself, or a bare `buf.len`.
    const s = std.mem.trim(u8, line, " \t");
    if (std.mem.startsWith(u8, s, "var ") or std.mem.startsWith(u8, s, "const ")) return false;
    return std.mem.indexOfScalar(u8, line, '(') != null;
}

/// `{` minus `}` on `line`, ignoring string and character literals.
fn braceDelta(line: []const u8) i32 {
    var d: i32 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '{' => d += 1,
            '}' => d -= 1,
            '"' => {
                i += 1;
                while (i < line.len and line[i] != '"') : (i += 1) {
                    if (line[i] == '\\') i += 1;
                }
            },
            '\'' => {
                i += 1;
                while (i < line.len and line[i] != '\'') : (i += 1) {
                    if (line[i] == '\\') i += 1;
                }
            },
            else => {},
        }
    }
    return d;
}

/// `app.overlay = .{` / `st.confirm = .{` — a struct literal assigned into
/// something reached through a field, so it outlives this function. A
/// `const x = .{` is a local and does not count.
fn persistTarget(sc: *const Scope, line: []const u8) bool {
    const s = std.mem.trim(u8, line, " \t");
    if (std.mem.startsWith(u8, s, "const ") or std.mem.startsWith(u8, s, "var ") or std.mem.startsWith(u8, s, "return ")) return false;
    const eq = std.mem.indexOf(u8, s, " = .{") orelse return false;
    const lvalue = s[0..eq];
    if (std.mem.indexOfScalar(u8, lvalue, '.') == null) return false;
    if (std.mem.indexOfAny(u8, lvalue, " \t()") != null) return false;
    // `seg.accent = .{…}` on a local the frame is about to paint is not a
    // store; `app.overlay = .{…}` is.
    return !sc.locals.contains(identHead(lvalue));
}

/// `st.title = expr;` — an assignment into something that is not a local,
/// on a field a frame string has no business reaching. A struct literal's
/// `.title = x,` is not one: it has a receiver before the dot.
fn storedAssignment(line: []const u8) ?struct { field: []const u8, rhs: []const u8 } {
    const s = std.mem.trim(u8, line, " \t");
    if (!std.mem.endsWith(u8, s, ";")) return null;
    for (stored_fields) |field| {
        const at = std.mem.indexOf(u8, s, field) orelse continue;
        const recv = receiverBefore(s, at);
        if (recv.len == 0) continue; // `.title = x,` in a literal
        // The receiver must be reached through a `.` or a `[…]` — a pointer
        // into state, not a value this function is about to hand off.
        var head = s[0..at];
        if (std.mem.indexOfAny(u8, head, " \t=") != null) continue; // not an lvalue
        if (std.mem.indexOfScalar(u8, head, '.') == null) continue;
        head = head;
        return .{ .field = field, .rhs = std.mem.trim(u8, s[at + field.len ..], " \t;") };
    }
    return null;
}

// ─── the job-result rule ────────────────────────────────────────────────

// A pane's slow work comes back as a RESULT that carries its own
// arena, and the consumer on the loop lets that arena go on the way
// out — `defer if (!keep_arena) res.arena.deinit()`. A prong of that
// switch which stores a payload into the app WITHOUT taking the arena
// (or duping) leaves a field pointing at a listing that is over: the
// bitbucket chip's rows republished as NUL bytes for exactly this
// reason, and the same shape had shipped three times before.
//
// The rule reads one consumer at a time:
//
//   1. A scope is a consumer when it has a `defer` that deinits a
//      parameter's `.arena` — that is the promise to let it go.
//   2. Inside it, `switch (<res>.payload)` opens the union, and each
//      `.tag => |cap|` binds one payload.
//   3. A prong that assigns `cap` (or a field of it) into something
//      that is NOT a local is a store. It is answered by taking the
//      arena (`… = <res>.arena` / `keep_arena = true`) or by duping.
//   4. A store with neither is the finding.

/// Names bound by `.tag => |cap|` on `line`, if any.
fn prongCapture(line: []const u8) ?[]const u8 {
    const s = stripComment(line);
    const arrow = std.mem.indexOf(u8, s, "=> |") orelse return null;
    const start = arrow + "=> |".len;
    const end = std.mem.indexOfScalarPos(u8, s, start, '|') orelse return null;
    const name = std.mem.trim(u8, s[start..end], " \t*");
    if (name.len == 0) return null;
    for (name) |c| if (!isIdentChar(c)) return null;
    return name;
}

/// `defer … <name>.arena.deinit()` — the promise this scope lets a
/// result's arena go. Answers the parameter's name.
fn resultArenaDefer(line: []const u8) ?[]const u8 {
    const s = std.mem.trim(u8, stripComment(line), " \t");
    if (!std.mem.startsWith(u8, s, "defer ")) return null;
    const at = std.mem.indexOf(u8, s, ".arena.deinit()") orelse return null;
    return receiverBefore(s, at);
}

/// `x.y = <rhs>;` where `x` is not a local — a store into something
/// that outlives this call. Answers the whole right-hand side.
fn storeIntoState(sc: *const Scope, line: []const u8) ?[]const u8 {
    const s = std.mem.trim(u8, stripComment(line), " \t");
    if (!std.mem.endsWith(u8, s, ";")) return null;
    const eq = std.mem.indexOf(u8, s, " = ") orelse return null;
    const lvalue = std.mem.trim(u8, s[0..eq], " \t");
    if (std.mem.startsWith(u8, lvalue, "const ") or std.mem.startsWith(u8, lvalue, "var ")) return null;
    if (std.mem.indexOfAny(u8, lvalue, " \t()[]") != null) return null;
    if (std.mem.indexOfScalar(u8, lvalue, '.') == null) return null;
    if (sc.locals.contains(identHead(lvalue))) return null;
    return std.mem.trim(u8, s[eq + 3 .. s.len - 1], " \t");
}

/// The right-hand side is the prong's payload, or a field of it.
fn namesCapture(rhs: []const u8, cap: []const u8) bool {
    const e = std.mem.trim(u8, rhs, " \t");
    if (std.mem.eql(u8, e, cap)) return true;
    if (e.len > cap.len + 1 and std.mem.startsWith(u8, e, cap) and e[cap.len] == '.') {
        // `v.open_items` counts; `v.open_mine` is a number and does not.
        return true;
    }
    return false;
}

/// What makes a store safe: the arena came too, or the bytes were
/// copied onto something the holder owns.
fn prongKeeps(line: []const u8, res: []const u8) bool {
    const s = stripComment(line);
    if (std.mem.indexOf(u8, s, "keep_arena = true") != null) return true;
    if (std.mem.indexOf(u8, s, "keep_arena=true") != null) return true;
    var buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrint(&buf, "{s}.arena", .{res}) catch return false;
    // `ts.data_arena = res.arena;` / `.arena = res.arena,`
    if (std.mem.indexOf(u8, s, marker) != null and std.mem.indexOf(u8, s, " = ") != null) return true;
    return false;
}

/// A store answered on its own line: `x.y = try gpa.dupe(…)`.
fn rhsCopies(rhs: []const u8) bool {
    inline for (.{ "dupe(", "dupeZ(", "allocPrint", "setText", "join(", "concat(", "toOwnedSlice" }) |k| {
        if (std.mem.indexOf(u8, rhs, k) != null) return true;
    }
    return false;
}

/// Every job-result store in `src` that lets its arena go.
pub fn jobResultFindings(arena: Allocator, file: []const u8, src: []const u8, counts: *Counts) Allocator.Error![]Finding {
    var out: std.ArrayListUnmanaged(Finding) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var lineno: u32 = 0;
    var sc: Scope = .{ .name = "(file)" };
    // The consumer's result parameter, empty outside one.
    var res: []const u8 = "";
    // The prong being read, and whether it has answered for the arena.
    var cap: []const u8 = "";
    var cap_depth: i32 = 0;
    var depth: i32 = 0;
    var kept = false;
    var pending: ?Finding = null;
    while (lines.next()) |raw| {
        lineno += 1;
        const line = stripComment(raw);
        if (declName(raw)) |d| {
            sc = .{ .name = d.name, .is_test = d.is_test };
            res = "";
            cap = "";
            depth = 0;
            pending = null;
        }
        const before = depth;
        depth += braceDelta(line);
        if (sc.is_test) continue;

        // Locals, so a store into one is not a store into the app.
        const trimmed = std.mem.trim(u8, line, " \t");
        inline for (.{ "const ", "var " }) |kw| {
            if (std.mem.startsWith(u8, trimmed, kw)) {
                const rest = trimmed[kw.len..];
                const end = std.mem.indexOfAny(u8, rest, " :=") orelse rest.len;
                if (end > 0) sc.locals.put(arena, rest[0..end], {}) catch {};
            }
        }

        if (res.len == 0) {
            if (resultArenaDefer(line)) |name| res = name;
            continue;
        }

        // A prong closing: report what it never answered for.
        if (cap.len > 0 and depth <= cap_depth) {
            if (pending) |f| if (!kept) try out.append(arena, f);
            pending = null;
            cap = "";
        }
        if (prongCapture(line)) |c| {
            cap = c;
            cap_depth = before;
            kept = false;
            pending = null;
            counts.prongs += 1;
            continue;
        }
        if (cap.len == 0) continue;
        if (prongKeeps(line, res)) kept = true;
        if (pending != null) continue;
        const rhs = storeIntoState(&sc, line) orelse continue;
        if (!namesCapture(rhs, cap)) continue;
        if (rhsCopies(rhs)) continue;
        pending = .{ .file = file, .line = lineno, .rule = .job_result, .origin = .result, .scope = sc.name, .expr = trimmed };
    }
    if (pending) |f| if (!kept) try out.append(arena, f);
    return out.toOwnedSlice(arena);
}

/// Every `.zig` under `root`, read for the job-result rule alone. The
/// frame-arena rules above are shaped for `src/` — its menus, prompts
/// and screen — and would only be noise over an integration.
pub fn walkJobResults(arena: Allocator, io: Io, root: []const u8) !Result {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        try files.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var out: std.ArrayListUnmanaged(Finding) = .empty;
    var counts: Counts = .{};
    for (files.items) |rel| {
        counts.files += 1;
        const text = try dir.readFileAlloc(io, rel, arena, .unlimited);
        try out.appendSlice(arena, try jobResultFindings(arena, rel, text, &counts));
    }
    return .{ .findings = try out.toOwnedSlice(arena), .counts = counts };
}

// ─── the walk ───────────────────────────────────────────────────────────

/// Every `.zig` under `root`, sorted, and its findings. Paths are
/// `root`-relative.
pub fn walk(arena: Allocator, io: Io, root: []const u8) !Result {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        try files.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var out: std.ArrayListUnmanaged(Finding) = .empty;
    var counts: Counts = .{};
    for (files.items) |rel| {
        const text = try dir.readFileAlloc(io, rel, arena, .unlimited);
        try out.appendSlice(arena, try extractFindings(arena, rel, text, &counts));
    }
    return .{ .findings = try out.toOwnedSlice(arena), .counts = counts };
}

pub fn report(w: *Io.Writer, r: Result) Io.Writer.Error!void {
    for (r.findings) |f| {
        try w.print("{s}:{d}  {s}  [{s}]  in {s}()  {s}\n", .{ f.file, f.line, f.rule.text(), @tagName(f.origin), f.scope, f.expr });
    }
    try w.print(
        "arena-audit: {d} findings over {d} files / {d} scopes ({d} menu strings, {d} openPrompt, {d} openConfirm, {d} paints, {d} stores inspected)\n",
        .{ r.findings.len, r.counts.files, r.counts.scopes, r.counts.menu_labels, r.counts.prompt_calls, r.counts.confirm_calls, r.counts.paints, r.counts.stores },
    );
}

pub fn jobReport(w: *Io.Writer, root: []const u8, r: Result) Io.Writer.Error!void {
    for (r.findings) |f| {
        try w.print("{s}/{s}:{d}  {s}  in {s}()  {s}\n", .{ root, f.file, f.line, f.rule.text(), f.scope, f.expr });
    }
    try w.print(
        "arena-audit (job results): {d} findings over {d} files / {d} result prongs in {s}\n",
        .{ r.findings.len, r.counts.files, r.counts.prongs, root },
    );
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn findingsOf(a: Allocator, src: []const u8) ![]Finding {
    var counts: Counts = .{};
    return extractFindings(a, "x.zig", src, &counts);
}

test "the frame arena reaching a menu label is a finding; the menu's own arena is not" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bad = try findingsOf(a,
        \\pub fn openRepoMenu(app: *App, x: u16, y: u16) !void {
        \\    const arena = app.frame.allocator();
        \\    var items: std.ArrayListUnmanaged(MenuItem) = .empty;
        \\    try items.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Checkout {s}", .{name}), .action = .{ .command = .@"git.checkout" } });
        \\    try app.openMenu("Repos", try items.toOwnedSlice(app.gpa), x, y);
        \\}
    );
    try t.expectEqual(@as(usize, 1), bad.len);
    try t.expectEqual(Rule.menu_label, bad[0].rule);
    try t.expectEqual(Origin.frame, bad[0].origin);
    try t.expectEqual(@as(u32, 4), bad[0].line);

    const good = try findingsOf(a,
        \\pub fn openRepoMenu(app: *App, x: u16, y: u16) !void {
        \\    var mem = std.heap.ArenaAllocator.init(app.gpa);
        \\    const arena = mem.allocator();
        \\    var items: std.ArrayListUnmanaged(MenuItem) = .empty;
        \\    try items.append(app.gpa, .{ .label = try std.fmt.allocPrint(arena, "Checkout {s}", .{name}), .action = .{ .command = .@"git.checkout" } });
        \\    try context_menus.openOwned(app, "Repos", try items.toOwnedSlice(app.gpa), x, y, mem);
        \\}
    );
    try t.expectEqual(@as(usize, 0), good.len);
}

test "openPrompt with a built title is a finding; openPromptOwned is not" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bad = try findingsOf(a,
        \\fn commitLines(app: *App) !void {
        \\    const arena = app.frame.allocator();
        \\    openPrompt(app, .commit_lines, try std.fmt.allocPrint(arena, "Commit message for the {s}", .{d}));
        \\}
    );
    try t.expectEqual(@as(usize, 1), bad.len);
    try t.expectEqual(Rule.prompt_title, bad[0].rule);

    const good = try findingsOf(a,
        \\fn commitLines(app: *App) !void {
        \\    const arena = app.frame.allocator();
        \\    try openPromptOwned(app, .commit_lines, try std.fmt.allocPrint(arena, "Commit message for the {s}", .{d}));
        \\}
    );
    try t.expectEqual(@as(usize, 0), good.len);
}

test "a stack buffer painted through putStr is a finding; the frame arena is not" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bad = try findingsOf(a,
        \\fn drawDate(ui: Ui, x: u16, y: u16, ts: i64) void {
        \\    var buf: [16]u8 = undefined;
        \\    const date = std.fmt.bufPrint(&buf, "{d}-{d}", .{ a1, b1 }) catch "";
        \\    _ = ui.putStr(x, y, 11, date, .{});
        \\}
    );
    try t.expectEqual(@as(usize, 1), bad.len);
    try t.expectEqual(Rule.dead_stack_paint, bad[0].rule);

    const good = try findingsOf(a,
        \\fn drawDate(ui: Ui, x: u16, y: u16, ts: i64) void {
        \\    const date = ui.fmt("{d}-{d}", .{ a1, b1 });
        \\    _ = ui.putStr(x, y, 11, date, .{});
        \\}
    );
    try t.expectEqual(@as(usize, 0), good.len);
}

test "a test block is not audited, and a literal label is not a finding" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try findingsOf(a,
        \\fn openSortMenu(app: *App, x: u16, y: u16) !void {
        \\    const items = try app.gpa.dupe(MenuItem, &.{
        \\        .{ .label = "Newest", .action = .{ .command = .@"todos.sort" } },
        \\    });
        \\    try app.openMenu("Sort by", items, x, y);
        \\}
        \\test "the frame arena in a test is the test's business" {
        \\    const arena = app.frame.allocator();
        \\    try app.openMenu(try std.fmt.allocPrint(arena, "x", .{}), items, 0, 0);
        \\    const label = try std.fmt.allocPrint(arena, "y", .{});
        \\    try items.append(app.gpa, .{ .label = label });
        \\}
    );
    try t.expectEqual(@as(usize, 0), f.len);
}

fn jobFindingsOf(a: Allocator, src: []const u8) ![]Finding {
    var counts: Counts = .{};
    return jobResultFindings(a, "x.zig", src, &counts);
}

test "a job result's payload stored without its arena is a finding; taking the arena or duping is not" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The bitbucket chip's bug, in the shape it shipped in.
    const bad = try jobFindingsOf(a,
        \\pub fn commit(app: *App, res: *fetch.Result) !void {
        \\    var keep_arena = false;
        \\    defer if (!keep_arena) res.arena.deinit();
        \\    switch (res.payload) {
        \\        .values => |v| {
        \\            app.values = v;
        \\        },
        \\    }
        \\}
    );
    try t.expectEqual(@as(usize, 1), bad.len);
    try t.expectEqual(Rule.job_result, bad[0].rule);
    try t.expectEqual(Origin.result, bad[0].origin);
    try t.expectEqual(@as(u32, 6), bad[0].line);

    // The fix: the arena comes with the figure.
    const kept = try jobFindingsOf(a,
        \\pub fn commit(app: *App, res: *fetch.Result) !void {
        \\    var keep_arena = false;
        \\    defer if (!keep_arena) res.arena.deinit();
        \\    switch (res.payload) {
        \\        .values => |v| {
        \\            if (app.values_arena) |*old| old.deinit();
        \\            app.values_arena = res.arena;
        \\            keep_arena = true;
        \\            app.values = v;
        \\        },
        \\    }
        \\}
    );
    try t.expectEqual(@as(usize, 0), kept.len);

    // The other answer: the bytes are copied onto something the app owns.
    const duped = try jobFindingsOf(a,
        \\pub fn commit(app: *App, res: *fetch.Result) !void {
        \\    var keep_arena = false;
        \\    defer if (!keep_arena) res.arena.deinit();
        \\    switch (res.payload) {
        \\        .whoami => |w| {
        \\            app.me_account_id = try app.gpa.dupe(u8, w.account_id);
        \\        },
        \\    }
        \\}
    );
    try t.expectEqual(@as(usize, 0), duped.len);

    // A function that never promises to free the arena is not a consumer.
    const not_a_consumer = try jobFindingsOf(a,
        \\pub fn apply(app: *App, res: *Result) !void {
        \\    switch (res.payload) {
        \\        .values => |v| {
        \\            app.values = v;
        \\        },
        \\    }
        \\}
    );
    try t.expectEqual(@as(usize, 0), not_a_consumer.len);

    // And a count is not a slice: storing one keeps nothing alive.
    const scalar = try jobFindingsOf(a,
        \\pub fn commit(app: *App, res: *fetch.Result) !void {
        \\    var keep_arena = false;
        \\    defer if (!keep_arena) res.arena.deinit();
        \\    switch (res.payload) {
        \\        .readiness => |rr| {
        \\            var buf: [8]u8 = undefined;
        \\            const key = prRowKey(&buf, rr.key.repo, rr.key.id);
        \\            try app.putReadiness(key, rr.updated_on, rr.readiness);
        \\        },
        \\    }
        \\}
    );
    try t.expectEqual(@as(usize, 0), scalar.len);
}

test "integrations/ and sdk/ store nothing out of a job result they let go" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const roots = [_][]const u8{ build_options.integrations_root, build_options.sdk_root };
    var prongs: usize = 0;
    var files: usize = 0;
    for (roots) |root| {
        const r = try walkJobResults(a, t.io, root);
        if (r.findings.len > 0) {
            var out: Io.Writer.Allocating = .init(a);
            try jobReport(&out.writer, root, r);
            std.debug.print("\n{s}\n", .{out.written()});
        }
        try t.expectEqual(@as(usize, 0), r.findings.len);
        prongs += r.counts.prongs;
        files += r.counts.files;
    }
    // An empty finding list is only evidence when the audit actually
    // looked. `sdk/` has no job-result consumer of its own today — the
    // `Slot` it hands out carries no arena — so the prongs are all on
    // the integrations' side, and a rule that stopped finding them
    // would fail here rather than go quiet.
    try t.expect(files > 60);
    try t.expect(prongs >= 7);
}

test "src/ has no string that dies before the consumer that keeps it" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try walk(a, t.io, build_options.src_root);
    // An empty finding list is only evidence when the audit actually
    // looked: these are the surfaces it walked.
    try t.expect(r.counts.files > 300);
    try t.expect(r.counts.menu_labels > 500);
    try t.expect(r.counts.paints > 500);
    if (r.findings.len > 0) {
        var out: Io.Writer.Allocating = .init(a);
        try report(&out.writer, r);
        std.debug.print("\n{s}\n", .{out.written()});
    }
    try t.expectEqual(@as(usize, 0), r.findings.len);
}
