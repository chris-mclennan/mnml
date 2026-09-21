//! The Playwright runner (`Pane.tests`): `npx playwright test
//! --reporter=json --trace=retain-on-failure <args>` on a worker, the
//! JSON report flattened into one row per spec, grouped under its file
//! (or slowest-first with `s`), the failing one's error beneath it and
//! a *open trace* row when Playwright kept a `trace.zip`. Enter jumps
//! to the test's line; `t` opens the trace in `npx playwright
//! show-trace`; `h` hands a failing test to Claude; `r` / `a` / `f` /
//! `R` re-run (same args / all / this file / `--last-failed`).
//!
//! Every finished run is recorded in the workspace's flaky history
//! (`flaky.zig`), which marks run-to-run wobbly tests with `≋`.
//!
//! The same pane runs `dotnet test` (`Runner.dotnet`: `dotnet.test`, the
//! `test.*` ids on a .NET project): the console logger's lines are the
//! rows, the TRX file it also writes fills in what the console omits, a
//! failure's file:line comes from its first stack frame, and a passed
//! test is found in the project's sources so Enter still jumps. `R`
//! re-runs the failures by name (`--filter FullyQualifiedName=…`).
//!
//!   D1  the run lives on the pane's snapshot arena, replaced wholesale
//!       when the next result lands; `last_args` is gpa-owned;
//!   D3  one `Io.Group` per pane; a re-run bumps the generation and a
//!       stale result is dropped; the worker never toasts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = app_mod.Key;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const alloc = @import("../core/alloc.zig");
const pty_pane = @import("pty_pane.zig");
const runners = @import("runners.zig");
const dotnet = @import("dotnet.zig");
const ai_app = @import("ai.zig");
const flaky = @import("flaky.zig");

pub const table = .{
    .@"test.run_playwright" = &runAll,
    .@"test.run_playwright_file" = &runFile,
    .@"test.run_playwright_at_cursor" = &runAtCursor,
    .@"test.rerun_playwright_failed" = &rerunFailed,
    .@"test.open_trace" = &openTraceCmd,
    .@"test.heal" = &healCmd,
    .@"test.sort" = &sortCmd,
};

// ─── the report ─────────────────────────────────────────────────────────

pub const Status = enum {
    passed,
    failed,
    skipped,
    /// Passed, but only on a retry.
    flaky,

    pub fn glyph(s: Status, ascii: bool) []const u8 {
        return switch (s) {
            .passed => if (ascii) "+" else "✓",
            .failed => if (ascii) "x" else "✗",
            .skipped => if (ascii) "-" else "⊘",
            .flaky => if (ascii) "~" else "≈",
        };
    }
};

/// Which tool the pane ran. The argv, the parser and the shape of a
/// re-run follow it; the rows and the keys are the same.
pub const Runner = enum {
    playwright,
    dotnet,

    pub fn label(r: Runner) []const u8 {
        return switch (r) {
            .playwright => "playwright",
            .dotnet => "dotnet test",
        };
    }
};

/// One spec: where it lives and how it went. Slices on the run's arena.
pub const TestCase = struct {
    title: []const u8,
    /// `describe › subdescribe` (may be empty).
    suite_path: []const u8,
    /// Project-relative.
    file: []const u8,
    line: u32,
    status: Status,
    duration_ms: u64,
    /// The first error (ANSI stripped, a few lines) of a failure.
    err: ?[]const u8,
    /// A retained `trace.zip`, absolute.
    trace_path: ?[]const u8,
};

pub const TestRun = struct {
    command: []const u8 = "",
    tests: []const TestCase = &.{},
    /// Config errors and the like, one line each.
    global_errors: []const []const u8 = &.{},
    /// The tool's own tally line, when it prints one (`Failed!  - Failed: 1, …`).
    summary: []const u8 = "",

    pub fn count(r: TestRun, status: Status) usize {
        var n: usize = 0;
        for (r.tests) |tc| n += @intFromBool(tc.status == status);
        return n;
    }
};

pub const ParseError = Allocator.Error || error{NotJson};

/// Playwright's `json` reporter output, flattened.
pub fn parseReport(arena: Allocator, text: []const u8) ParseError!TestRun {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, std.mem.trim(u8, text, " \t\r\n"), .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotJson,
    };
    const obj = switch (root) {
        .object => |o| o,
        else => return error.NotJson,
    };
    var tests: std.ArrayListUnmanaged(TestCase) = .empty;
    if (obj.get("suites")) |suites| if (suites == .array) {
        for (suites.array.items) |s| try walkSuite(arena, s, "", &tests);
    };
    var errors: std.ArrayListUnmanaged([]const u8) = .empty;
    if (obj.get("errors")) |errs| if (errs == .array) {
        for (errs.array.items) |e| {
            const msg: ?[]const u8 = switch (e) {
                .object => |eo| if (eo.get("message")) |m| (if (m == .string) m.string else null) else null,
                .string => |s| s,
                else => null,
            };
            if (msg) |m| try errors.append(arena, firstLine(try stripAnsi(arena, m)));
        }
    };
    return .{ .tests = try tests.toOwnedSlice(arena), .global_errors = try errors.toOwnedSlice(arena) };
}

fn str(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn int(v: ?std.json.Value) ?u64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .float => |f| if (f >= 0) @intFromFloat(f) else null,
        else => null,
    };
}

/// A suite's `title` is the file at the top level, then the describe
/// names; only the describes accumulate into the path.
fn walkSuite(arena: Allocator, suite: std.json.Value, parent: []const u8, out: *std.ArrayListUnmanaged(TestCase)) Allocator.Error!void {
    if (suite != .object) return;
    const o = suite.object;
    const title = str(o.get("title")) orelse "";
    const file = str(o.get("file")) orelse "";
    const file_level = file.len > 0 and std.mem.eql(u8, title, file);
    const path: []const u8 = if (parent.len == 0)
        (if (file_level) "" else title)
    else if (file_level)
        parent
    else
        try std.fmt.allocPrint(arena, "{s} › {s}", .{ parent, title });
    if (o.get("specs")) |specs| if (specs == .array) {
        for (specs.array.items) |spec| try pushSpec(arena, spec, path, out);
    };
    if (o.get("suites")) |children| if (children == .array) {
        for (children.array.items) |c| try walkSuite(arena, c, path, out);
    };
}

fn pushSpec(arena: Allocator, spec: std.json.Value, suite_path: []const u8, out: *std.ArrayListUnmanaged(TestCase)) Allocator.Error!void {
    if (spec != .object) return;
    const o = spec.object;
    var tc: TestCase = .{
        .title = str(o.get("title")) orelse "(test)",
        .suite_path = suite_path,
        .file = str(o.get("file")) orelse "",
        .line = @intCast(@min(int(o.get("line")) orelse 0, std.math.maxInt(u32))),
        .status = .passed,
        .duration_ms = 0,
        .err = null,
        .trace_path = null,
    };
    // `tests[]` is per project; the first one's results are the story.
    const test0: ?std.json.Value = if (o.get("tests")) |ts| (if (ts == .array and ts.array.items.len > 0) ts.array.items[0] else null) else null;
    const t0_obj: ?std.json.ObjectMap = if (test0) |t0| (if (t0 == .object) t0.object else null) else null;
    if (t0_obj) |to| {
        const results: []const std.json.Value = if (to.get("results")) |rs| (if (rs == .array) rs.array.items else &.{}) else &.{};
        for (results) |r| if (r == .object) {
            tc.duration_ms += int(r.object.get("duration")) orelse 0;
        };
        // `tests[].status`: expected | unexpected | flaky | skipped.
        const st = str(to.get("status")) orelse "";
        tc.status = if (std.mem.eql(u8, st, "expected")) .passed else if (std.mem.eql(u8, st, "flaky")) .flaky else if (std.mem.eql(u8, st, "skipped")) .skipped else blk: {
            const last: ?std.json.Value = if (results.len > 0) results[results.len - 1] else null;
            const ls = if (last) |l| (if (l == .object) str(l.object.get("status")) else null) else null;
            if (ls) |s| {
                if (std.mem.eql(u8, s, "passed")) break :blk .passed;
                if (std.mem.eql(u8, s, "skipped")) break :blk .skipped;
            }
            break :blk .failed;
        };
        if (tc.status == .failed) {
            var i = results.len;
            while (i > 0) : (i -= 1) if (try resultError(arena, results[i - 1])) |e| {
                tc.err = e;
                break;
            };
        }
        var j = results.len;
        while (j > 0) : (j -= 1) if (resultTrace(results[j - 1])) |p| {
            tc.trace_path = p;
            break;
        };
    } else {
        const ok = if (o.get("ok")) |v| (if (v == .bool) v.bool else true) else true;
        tc.status = if (ok) .passed else .failed;
    }
    try out.append(arena, tc);
}

/// The `trace` attachment's path in one result, if any.
fn resultTrace(result: std.json.Value) ?[]const u8 {
    if (result != .object) return null;
    const atts = result.object.get("attachments") orelse return null;
    if (atts != .array) return null;
    for (atts.array.items) |a| {
        if (a != .object) continue;
        const name = str(a.object.get("name")) orelse continue;
        if (!std.mem.eql(u8, name, "trace")) continue;
        return str(a.object.get("path"));
    }
    return null;
}

/// The first error's message (newer reports: `errors[]`; older: `error`),
/// ANSI stripped, six lines at most.
fn resultError(arena: Allocator, result: std.json.Value) Allocator.Error!?[]const u8 {
    if (result != .object) return null;
    const o = result.object;
    const err: ?std.json.Value = if (o.get("errors")) |es| (if (es == .array and es.array.items.len > 0) es.array.items[0] else null) else o.get("error");
    const e = err orelse return null;
    const msg: ?[]const u8 = switch (e) {
        .object => |eo| str(eo.get("message")),
        .string => |s| s,
        else => null,
    };
    const m = msg orelse return null;
    const clean = try stripAnsi(arena, m);
    var lines = std.mem.splitScalar(u8, clean, '\n');
    var kept: std.ArrayListUnmanaged(u8) = .empty;
    var n: usize = 0;
    while (lines.next()) |l| : (n += 1) {
        if (n == 6) break;
        if (n > 0) try kept.append(arena, '\n');
        try kept.appendSlice(arena, l);
    }
    return try kept.toOwnedSlice(arena);
}

fn firstLine(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, '\n')) |i| s[0..i] else s;
}

/// Drop CSI sequences (`\x1b[...m` and kin).
pub fn stripAnsi(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == 0x1b) {
            if (i + 1 < s.len and s[i + 1] == '[') {
                i += 2;
                while (i < s.len and !(std.ascii.isAlphabetic(s[i]) or s[i] == '~')) : (i += 1) {}
            }
            continue;
        }
        try out.append(arena, s[i]);
    }
    return out.toOwnedSlice(arena);
}

// ─── dotnet test ────────────────────────────────────────────────────────

/// `dotnet test --logger "console;verbosity=normal"`: one `Passed` /
/// `Failed` / `Skipped` line per test (`  Failed A.B.C.Divides [12 ms]`,
/// or the older `X` / `√` / `!` signs), a failure's `Error Message:` and
/// `Stack Trace:` blocks beneath it, `error CS…` lines when the build
/// broke, and the `Passed!` / `Failed!` tally. Paths under `workspace`
/// are made relative to it.
pub fn parseDotnet(arena: Allocator, text: []const u8, workspace: []const u8) Allocator.Error!TestRun {
    var tests: std.ArrayListUnmanaged(TestCase) = .empty;
    var errors: std.ArrayListUnmanaged([]const u8) = .empty;
    var summary: []const u8 = "";
    var cur: ?usize = null;
    var section: enum { none, message, stack } = .none;
    var msg: std.ArrayListUnmanaged(u8) = .empty;
    var msg_lines: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const trimmed = std.mem.trim(u8, try stripAnsi(arena, raw), " \t\r");
        if (dotnetStatusLine(trimmed)) |st| {
            if (cur) |i| if (msg.items.len > 0) {
                tests.items[i].err = try msg.toOwnedSlice(arena);
            };
            msg = .empty;
            msg_lines = 0;
            const name_dur = splitDuration(st.rest);
            const split = splitQualified(name_dur.name);
            try tests.append(arena, .{
                .title = split.title,
                .suite_path = split.suite,
                .file = "",
                .line = 0,
                .status = st.status,
                .duration_ms = name_dur.ms,
                .err = null,
                .trace_path = null,
            });
            cur = tests.items.len - 1;
            section = .none;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "Passed!") or std.mem.startsWith(u8, trimmed, "Failed!") or std.mem.startsWith(u8, trimmed, "Total tests:")) {
            if (summary.len == 0 or std.mem.startsWith(u8, trimmed, "Failed!")) summary = try arena.dupe(u8, trimmed);
            cur = null;
            section = .none;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "Results File:")) {
            cur = null;
            section = .none;
            continue;
        }
        if (isBuildError(trimmed)) {
            var dup = false;
            for (errors.items) |e| if (std.mem.eql(u8, e, trimmed)) {
                dup = true;
            };
            if (!dup and errors.items.len < 20) try errors.append(arena, try arena.dupe(u8, trimmed));
            continue;
        }
        if (cur) |i| {
            if (std.mem.eql(u8, trimmed, "Error Message:")) {
                section = .message;
                continue;
            }
            if (std.mem.eql(u8, trimmed, "Stack Trace:")) {
                section = .stack;
                continue;
            }
            switch (section) {
                .message => if (trimmed.len > 0 and msg_lines < 6) {
                    if (msg.items.len > 0) try msg.append(arena, '\n');
                    try msg.appendSlice(arena, trimmed);
                    msg_lines += 1;
                },
                .stack => if (tests.items[i].file.len == 0) {
                    if (frameLocation(trimmed)) |loc| {
                        tests.items[i].file = try relativeTo(arena, loc.path, workspace);
                        tests.items[i].line = loc.line;
                    }
                },
                .none => {},
            }
            continue;
        }
    }
    if (cur) |i| if (msg.items.len > 0) {
        tests.items[i].err = try msg.toOwnedSlice(arena);
    };
    return .{ .tests = try tests.toOwnedSlice(arena), .global_errors = try errors.toOwnedSlice(arena), .summary = summary };
}

const StatusLine = struct { status: Status, rest: []const u8 };

/// `Passed <name>…` and the three signs the older test host printed.
fn dotnetStatusLine(line: []const u8) ?StatusLine {
    const heads = [_]struct { []const u8, Status }{
        .{ "Passed ", .passed }, .{ "Failed ", .failed }, .{ "Skipped ", .skipped },
        .{ "√ ", .passed },
        .{ "X ", .failed },      .{ "! ", .skipped },
        .{ "✓ ", .passed },
        .{ "✗ ", .failed },
    };
    for (heads) |h| if (std.mem.startsWith(u8, line, h[0])) {
        const rest = std.mem.trim(u8, line[h[0].len..], " \t");
        if (rest.len == 0 or rest[0] == '-' or rest[0] == ':') return null;
        return .{ .status = h[1], .rest = rest };
    };
    return null;
}

/// `Name [12 ms]` → the name and the milliseconds; `[< 1 ms]` is 0;
/// `[1 m 2 s]` adds up. No bracket: the whole line, 0 ms.
fn splitDuration(s: []const u8) struct { name: []const u8, ms: u64 } {
    if (!std.mem.endsWith(u8, s, "]")) return .{ .name = s, .ms = 0 };
    const bracket = std.mem.lastIndexOf(u8, s, " [") orelse return .{ .name = s, .ms = 0 };
    const inner = s[bracket + 2 .. s.len - 1];
    var ms: u64 = 0;
    if (std.mem.startsWith(u8, inner, "<")) return .{ .name = std.mem.trimEnd(u8, s[0..bracket], " "), .ms = 0 };
    var it = std.mem.tokenizeAny(u8, inner, " ");
    var pending: ?u64 = null;
    while (it.next()) |tok| {
        if (std.fmt.parseFloat(f64, tok)) |v| {
            pending = if (v > 0) @intFromFloat(v) else 0;
        } else |_| if (pending) |n| {
            if (std.mem.eql(u8, tok, "ms")) ms += n else if (std.mem.eql(u8, tok, "s")) ms += n * 1000 else if (std.mem.eql(u8, tok, "m")) ms += n * 60_000 else if (std.mem.eql(u8, tok, "h")) ms += n * 3_600_000;
            pending = null;
        }
    }
    return .{ .name = std.mem.trimEnd(u8, s[0..bracket], " "), .ms = ms };
}

/// `Acme.Tests.CalcTests.Adds(a: 1)` → suite `Acme.Tests.CalcTests`,
/// title `Adds(a: 1)`. A name without a dot before its parameters is
/// all title.
fn splitQualified(name: []const u8) struct { suite: []const u8, title: []const u8 } {
    const base = name[0 .. std.mem.indexOfScalar(u8, name, '(') orelse name.len];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return .{ .suite = "", .title = name };
    return .{ .suite = name[0..dot], .title = name[dot + 1 ..] };
}

const Location = struct { path: []const u8, line: u32 };

/// `at A.B.C() in /ws/Tests/CalcTests.cs:line 21` → the path and line.
fn frameLocation(frame: []const u8) ?Location {
    const in_at = std.mem.lastIndexOf(u8, frame, " in ") orelse return null;
    const rest = frame[in_at + 4 ..];
    const mark = std.mem.lastIndexOf(u8, rest, ":line ") orelse return null;
    const line = std.fmt.parseInt(u32, std.mem.trim(u8, rest[mark + 6 ..], " \t"), 10) catch return null;
    const path = std.mem.trim(u8, rest[0..mark], " \t");
    if (path.len == 0) return null;
    return .{ .path = path, .line = line };
}

/// `error CS1002: …` from the compiler, `error MSB…` from the build,
/// `error NU…` from restore — not a test's own `Error Message:`.
fn isBuildError(line: []const u8) bool {
    const at = std.mem.indexOf(u8, line, "error ") orelse return false;
    if (at > 0 and !(line[at - 1] == ' ' or line[at - 1] == ':')) return false;
    const code = line[at + 6 ..];
    return code.len > 2 and std.ascii.isUpper(code[0]) and std.ascii.isUpper(code[1]);
}

fn relativeTo(arena: Allocator, path: []const u8, workspace: []const u8) Allocator.Error![]const u8 {
    if (workspace.len > 0 and std.mem.startsWith(u8, path, workspace) and path.len > workspace.len and (path[workspace.len] == '/' or path[workspace.len] == '\\'))
        return arena.dupe(u8, path[workspace.len + 1 ..]);
    return arena.dupe(u8, path);
}

/// The `Results File: <path>.trx` line, when the trx logger ran.
pub fn trxPathIn(text: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, "Results File:") orelse return null;
    const rest = text[at + "Results File:".len ..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const path = std.mem.trim(u8, rest[0..end], " \t\r");
    return if (std.mem.endsWith(u8, path, ".trx")) path else null;
}

/// The TRX the `trx` logger writes: every `<UnitTestResult>` with its
/// outcome and duration, the `<Message>` / `<StackTrace>` of a failure,
/// and the class + method from the `<UnitTest>` definitions (the
/// console's `testName` is the display name, which NUnit shortens).
pub fn parseTrx(arena: Allocator, xml: []const u8, workspace: []const u8) Allocator.Error!TestRun {
    var by_id: std.StringHashMapUnmanaged([]const u8) = .empty;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, xml, from, "<UnitTest ")) |at| {
        const open_end = std.mem.indexOfScalarPos(u8, xml, at, '>') orelse break;
        const opener = xml[at..open_end];
        const close = std.mem.indexOfPos(u8, xml, open_end, "</UnitTest>") orelse break;
        from = close;
        const id = try attrValue(arena, opener, "id") orelse continue;
        const body = xml[open_end..close];
        const tm_at = std.mem.indexOf(u8, body, "<TestMethod ") orelse continue;
        const tm_end = std.mem.indexOfScalarPos(u8, body, tm_at, '>') orelse continue;
        const tm = body[tm_at..tm_end];
        const method = try attrValue(arena, tm, "name") orelse continue;
        var class = try attrValue(arena, tm, "className") orelse "";
        class = class[0 .. std.mem.indexOfScalar(u8, class, ',') orelse class.len];
        const fqn = if (class.len == 0) method else try std.fmt.allocPrint(arena, "{s}.{s}", .{ class, method });
        try by_id.put(arena, id, fqn);
    }
    var tests: std.ArrayListUnmanaged(TestCase) = .empty;
    from = 0;
    while (std.mem.indexOfPos(u8, xml, from, "<UnitTestResult ")) |at| {
        const open_end = std.mem.indexOfScalarPos(u8, xml, at, '>') orelse break;
        const opener = xml[at..open_end];
        const self_closing = opener.len > 0 and opener[opener.len - 1] == '/';
        const close = if (self_closing) open_end else (std.mem.indexOfPos(u8, xml, open_end, "</UnitTestResult>") orelse xml.len);
        from = close;
        const test_id = try attrValue(arena, opener, "testId");
        const name = (if (test_id) |id| by_id.get(id) else null) orelse (try attrValue(arena, opener, "testName")) orelse "(test)";
        const outcome = (try attrValue(arena, opener, "outcome")) orelse "";
        const status: Status = if (std.mem.eql(u8, outcome, "Passed")) .passed else if (std.mem.eql(u8, outcome, "Failed") or std.mem.eql(u8, outcome, "Error") or std.mem.eql(u8, outcome, "Timeout") or std.mem.eql(u8, outcome, "Aborted")) .failed else .skipped;
        const body = xml[open_end..close];
        const split = splitQualified(name);
        var tc: TestCase = .{
            .title = split.title,
            .suite_path = split.suite,
            .file = "",
            .line = 0,
            .status = status,
            .duration_ms = trxDurationMs((try attrValue(arena, opener, "duration")) orelse ""),
            .err = null,
            .trace_path = null,
        };
        if (status == .failed) {
            if (try elementText(arena, body, "Message")) |m| tc.err = firstLines(m, 6);
            if (try elementText(arena, body, "StackTrace")) |st| {
                var frames = std.mem.splitScalar(u8, st, '\n');
                while (frames.next()) |f| if (frameLocation(std.mem.trim(u8, f, " \t\r"))) |loc| {
                    tc.file = try relativeTo(arena, loc.path, workspace);
                    tc.line = loc.line;
                    break;
                };
            }
        }
        try tests.append(arena, tc);
    }
    return .{ .tests = try tests.toOwnedSlice(arena) };
}

/// `key="value"` in a tag's opener, unescaped. The key must follow
/// whitespace (`testName=` is not `name=`).
fn attrValue(arena: Allocator, opener: []const u8, key: []const u8) Allocator.Error!?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, opener, from, key)) |at| {
        from = at + 1;
        if (at == 0 or !std.ascii.isWhitespace(opener[at - 1])) continue;
        const after = opener[at + key.len ..];
        if (!std.mem.startsWith(u8, after, "=\"")) continue;
        const val = after[2..];
        const end = std.mem.indexOfScalar(u8, val, '"') orelse return null;
        return try xmlUnescape(arena, val[0..end]);
    }
    return null;
}

/// The unescaped, trimmed text of the first `<tag>…</tag>` in `body`.
fn elementText(arena: Allocator, body: []const u8, tag: []const u8) Allocator.Error!?[]const u8 {
    var open_buf: [32]u8 = undefined;
    var close_buf: [32]u8 = undefined;
    const opener = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag}) catch return null;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
    const at = std.mem.indexOf(u8, body, opener) orelse return null;
    const rest = body[at + opener.len ..];
    const end = std.mem.indexOf(u8, rest, close) orelse rest.len;
    const text = std.mem.trim(u8, try xmlUnescape(arena, rest[0..end]), " \t\r\n");
    return if (text.len > 0) text else null;
}

fn xmlUnescape(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            const rest = s[i..];
            const Ent = struct { []const u8, []const u8 };
            const ents = [_]Ent{ .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&amp;", "&" }, .{ "&quot;", "\"" }, .{ "&apos;", "'" }, .{ "&#xD;", "" }, .{ "&#xA;", "\n" }, .{ "&#13;", "" }, .{ "&#10;", "\n" } };
            var hit = false;
            for (ents) |e| if (std.mem.startsWith(u8, rest, e[0])) {
                try out.appendSlice(arena, e[1]);
                i += e[0].len;
                hit = true;
                break;
            };
            if (hit) continue;
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// `00:00:01.2345678` → 1234 ms.
fn trxDurationMs(s: []const u8) u64 {
    var it = std.mem.splitScalar(u8, s, ':');
    const h = std.fmt.parseInt(u64, it.next() orelse return 0, 10) catch return 0;
    const m = std.fmt.parseInt(u64, it.next() orelse return 0, 10) catch return 0;
    const sec_s = it.next() orelse return 0;
    const sec = std.fmt.parseFloat(f64, sec_s) catch return 0;
    return h * 3_600_000 + m * 60_000 + @as(u64, @intFromFloat(sec * 1000.0));
}

fn firstLines(s: []const u8, n: usize) []const u8 {
    var end: usize = 0;
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| : (lines += 1) {
        if (lines == n) break;
        end = @intFromPtr(l.ptr) - @intFromPtr(s.ptr) + l.len;
    }
    return s[0..end];
}

/// A row without a file — every passed test, since only a failure
/// prints a stack — is looked for in the `.cs` sources under `root`: a
/// file naming its class with a line calling out `Method(`. Bounded;
/// a test that is not found keeps no file.
pub fn locateSources(arena: Allocator, io: Io, root: []const u8, workspace: []const u8, tests: []TestCase) Allocator.Error!void {
    var pending: usize = 0;
    for (tests) |tc| pending += @intFromBool(tc.file.len == 0);
    if (pending == 0) return;
    var budget: usize = 3000;
    try locateIn(arena, io, root, workspace, tests, &pending, &budget, 0);
}

const skip_dirs = [_][]const u8{ "bin", "obj", ".git", "node_modules", "TestResults", ".mnml" };

fn locateIn(arena: Allocator, io: Io, dir: []const u8, workspace: []const u8, tests: []TestCase, pending: *usize, budget: *usize, depth: u8) Allocator.Error!void {
    if (pending.* == 0 or budget.* == 0 or depth > 12) return;
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (pending.* == 0 or budget.* == 0) return;
        if (entry.kind == .directory) {
            var skip = false;
            for (skip_dirs) |sd| if (std.mem.eql(u8, sd, entry.name)) {
                skip = true;
            };
            if (skip) continue;
            const sub = try std.fs.path.join(arena, &.{ dir, entry.name });
            try locateIn(arena, io, sub, workspace, tests, pending, budget, depth + 1);
            continue;
        }
        if (!std.ascii.endsWithIgnoreCase(entry.name, ".cs")) continue;
        budget.* -= 1;
        const path = try std.fs.path.join(arena, &.{ dir, entry.name });
        const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch continue;
        for (tests) |*tc| {
            if (tc.file.len > 0) continue;
            if (methodLine(text, classOf(tc.suite_path), methodOf(tc.title))) |line| {
                tc.file = try relativeTo(arena, path, workspace);
                tc.line = line;
                pending.* -= 1;
            }
        }
    }
}

fn classOf(suite: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, suite, '.') orelse return suite;
    return suite[dot + 1 ..];
}

fn methodOf(title: []const u8) []const u8 {
    var end: usize = 0;
    while (end < title.len and (std.ascii.isAlphanumeric(title[end]) or title[end] == '_')) end += 1;
    return title[0..end];
}

/// The 1-based line of ` Method(` in a file that declares `class` (or
/// `record` / `struct`) `Class`; the class check is skipped when the
/// suite gave none.
fn methodLine(text: []const u8, class: []const u8, method: []const u8) ?u32 {
    if (method.len == 0) return null;
    if (class.len > 0 and !declares(text, class)) return null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, method)) |at| {
        from = at + method.len;
        if (at == 0 or !(text[at - 1] == ' ' or text[at - 1] == '\t')) continue;
        if (from >= text.len or text[from] != '(') continue;
        const line_end = std.mem.indexOfScalarPos(u8, text, from, '\n') orelse text.len;
        const tail = std.mem.trimEnd(u8, text[from..line_end], " \t\r");
        if (tail.len > 0 and tail[tail.len - 1] == ';' and std.mem.indexOf(u8, tail, "=>") == null) continue;
        return @intCast(std.mem.count(u8, text[0..at], "\n") + 1);
    }
    return null;
}

fn declares(text: []const u8, class: []const u8) bool {
    for ([_][]const u8{ "class ", "record ", "struct " }) |kw| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, kw)) |at| {
            from = at + kw.len;
            const rest = text[from..];
            if (!std.mem.startsWith(u8, rest, class)) continue;
            const after = rest[class.len..];
            if (after.len == 0 or !(std.ascii.isAlphanumeric(after[0]) or after[0] == '_')) return true;
        }
    }
    return false;
}

/// `--filter FullyQualifiedName=A|FullyQualifiedName=B` for a run's
/// failures; null when nothing failed.
pub fn failedFilter(arena: Allocator, tr: TestRun) Allocator.Error!?[]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (tr.tests) |tc| {
        if (tc.status != .failed) continue;
        if (out.items.len > 0) try out.append(arena, '|');
        try out.appendSlice(arena, "FullyQualifiedName=");
        if (tc.suite_path.len > 0) {
            try out.appendSlice(arena, tc.suite_path);
            try out.append(arena, '.');
        }
        try out.appendSlice(arena, methodOf(tc.title));
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(arena);
}

// ─── the worker ─────────────────────────────────────────────────────────

/// A finished run — the report parsed, or why it could not be.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    generation: u32,
    pane: PaneId,
    run: ?TestRun = null,
    err: ?[]const u8 = null,

    pub fn create(gpa: Allocator, generation: u32, pane: PaneId) Allocator.Error!*Result {
        const r = try gpa.create(Result);
        r.* = .{ .arena = .init(gpa), .generation = generation, .pane = pane };
        return r;
    }

    pub fn destroy(self: *Result, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub const base_argv = [_][]const u8{ "npx", "playwright", "test", "--reporter=json", "--trace=retain-on-failure" };
pub const dotnet_argv = [_][]const u8{ "dotnet", "test", "--nologo", "--logger", "console;verbosity=normal", "--logger", "trx" };

fn baseArgv(runner: Runner) []const []const u8 {
    return switch (runner) {
        .playwright => &base_argv,
        .dotnet => &dotnet_argv,
    };
}

/// The runner's fixed argv plus `extra`.
pub fn argvFor(arena: Allocator, runner: Runner, extra: []const []const u8) Allocator.Error![]const []const u8 {
    const base = baseArgv(runner);
    const out = try arena.alloc([]const u8, base.len + extra.len);
    @memcpy(out[0..base.len], base);
    @memcpy(out[base.len..], extra);
    return out;
}

/// The argv as one line, an argument the shell would split quoted.
pub fn cmdlineFor(arena: Allocator, runner: Runner, extra: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (baseArgv(runner), 0..) |a, i| {
        if (i > 0) try out.append(arena, ' ');
        try appendArg(arena, &out, a);
    }
    for (extra) |a| {
        try out.append(arena, ' ');
        try appendArg(arena, &out, a);
    }
    return out.toOwnedSlice(arena);
}

fn appendArg(arena: Allocator, out: *std.ArrayListUnmanaged(u8), a: []const u8) Allocator.Error!void {
    const quote = std.mem.indexOfAny(u8, a, " ;|&\"") != null;
    if (quote) try out.append(arena, '"');
    try out.appendSlice(arena, a);
    if (quote) try out.append(arena, '"');
}

/// Run the suite and post the result. `env` is the worker's own copy
/// (`PW_TEST_HTML_REPORT_OPEN=never` keeps the HTML report closed) and
/// is freed here; `extra` is the pane's `last_args`, copied first.
fn worker(events: *event.EventQueue, io: Io, gpa: Allocator, runner: Runner, cwd: []const u8, workspace: []const u8, env: *std.process.Environ.Map, extra: []const []const u8, generation: u32, pane: PaneId) Io.Cancelable!void {
    defer {
        env.deinit();
        gpa.destroy(env);
        for (extra) |a| gpa.free(a);
        gpa.free(extra);
        gpa.free(cwd);
        gpa.free(workspace);
    }
    const result = Result.create(gpa, generation, pane) catch return;
    const arena = result.arena.allocator();
    const argv = argvFor(arena, runner, extra) catch {
        result.destroy(gpa);
        return;
    };
    // The App's PATH, not this process's, decides which tool runs
    // (`runners.pathOf`); a tool that is not on it fails as before.
    var where: [std.fs.max_path_bytes]u8 = undefined;
    if (runners.pathOf(io, env, &where, argv[0])) |abs| {
        const owned = arena.dupe(u8, abs) catch {
            result.destroy(gpa);
            return;
        };
        @constCast(argv)[0] = owned;
    }
    const proc = std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    }) catch |err| switch (err) {
        error.Canceled => {
            result.destroy(gpa);
            return error.Canceled;
        },
        else => {
            result.err = switch (runner) {
                .playwright => std.fmt.allocPrint(arena, "running `npx playwright test`: {s} — is Playwright installed here?", .{@errorName(err)}) catch null,
                .dotnet => std.fmt.allocPrint(arena, "running `dotnet test`: {s} — is the .NET SDK on PATH?", .{@errorName(err)}) catch null,
            };
            events.post(io, .{ .tests = result });
            return;
        },
    };
    defer gpa.free(proc.stdout);
    defer gpa.free(proc.stderr);
    if (runner == .dotnet) {
        dotnetResult(io, arena, result, cwd, workspace, proc.stdout, proc.stderr, extra) catch {
            result.destroy(gpa);
            return;
        };
        events.post(io, .{ .tests = result });
        return;
    }
    if (parseReport(arena, proc.stdout)) |parsed| {
        var r = parsed;
        r.command = cmdlineFor(arena, runner, extra) catch "";
        result.run = r;
    } else |err| switch (err) {
        error.OutOfMemory => {
            result.destroy(gpa);
            return;
        },
        error.NotJson => {
            // Playwright errored before a report: its stderr (or stdout), four lines.
            const text = std.mem.trim(u8, if (proc.stderr.len > 0) proc.stderr else proc.stdout, " \t\r\n");
            const msg: []const u8 = if (text.len == 0) "Playwright produced no JSON report" else text;
            var lines = std.mem.splitScalar(u8, msg, '\n');
            var kept: std.ArrayListUnmanaged(u8) = .empty;
            var n: usize = 0;
            while (lines.next()) |l| : (n += 1) {
                if (n == 4) break;
                if (n > 0) kept.append(arena, '\n') catch break;
                kept.appendSlice(arena, l) catch break;
            }
            result.err = kept.items;
        },
    }
    events.post(io, .{ .tests = result });
}

/// The console lines are the rows; the TRX (when the logger wrote one
/// and it parses to at least one test) supplies the rows instead, with
/// its durations and messages; the console's tally and build errors
/// stay. Passed rows are then found in the sources. No rows and no
/// build error is the tool's own words, four lines.
fn dotnetResult(io: Io, arena: Allocator, result: *Result, cwd: []const u8, workspace: []const u8, stdout: []const u8, stderr: []const u8, extra: []const []const u8) Allocator.Error!void {
    var r = try parseDotnet(arena, stdout, workspace);
    if (trxPathIn(stdout)) |trx_path| {
        const abs = if (std.fs.path.isAbsolute(trx_path)) trx_path else try std.fs.path.join(arena, &.{ cwd, trx_path });
        if (Io.Dir.cwd().readFileAlloc(io, abs, arena, .limited(32 << 20))) |xml| {
            const from_trx = try parseTrx(arena, xml, workspace);
            if (from_trx.tests.len > 0) r.tests = from_trx.tests;
        } else |_| {}
    }
    if (r.tests.len == 0 and r.global_errors.len == 0) {
        const text = std.mem.trim(u8, if (stderr.len > 0) stderr else stdout, " \t\r\n");
        const msg: []const u8 = if (text.len == 0) "dotnet test printed no test results" else text;
        var lines = std.mem.splitScalar(u8, msg, '\n');
        var kept: std.ArrayListUnmanaged(u8) = .empty;
        var n: usize = 0;
        while (lines.next()) |l| : (n += 1) {
            if (n == 4) break;
            if (n > 0) try kept.append(arena, '\n');
            try kept.appendSlice(arena, try stripAnsi(arena, l));
        }
        result.err = kept.items;
        return;
    }
    const tests = try arena.dupe(TestCase, r.tests);
    try locateSources(arena, io, cwd, workspace, tests);
    r.tests = tests;
    r.command = try cmdlineFor(arena, .dotnet, extra);
    result.run = r;
}

// ─── the pane ───────────────────────────────────────────────────────────

pub const State = enum { running, done, failed };
pub const Sort = enum {
    file_line,
    duration_desc,

    pub fn next(s: Sort) Sort {
        return if (s == .file_line) .duration_desc else .file_line;
    }
    pub fn label(s: Sort) []const u8 {
        return switch (s) {
            .file_line => "file:line",
            .duration_desc => "slowest",
        };
    }
};

/// One painted row.
pub const Row = union(enum) {
    /// A file header (`file_line` sort only).
    file: []const u8,
    /// A spec, by index into `run.tests`.
    case: u32,
    /// One line of a failure's error, under its case.
    err_line: struct { case: u32, text: []const u8 },
    /// The *open trace* launcher under a case that kept one.
    trace: u32,
    global_err: []const u8,

    pub fn caseOf(r: Row) ?u32 {
        return switch (r) {
            .case, .trace => |c| c,
            .err_line => |e| e.case,
            .file, .global_err => null,
        };
    }
};

pub const TestsPane = struct {
    snapshot: alloc.SnapshotArena,
    /// Heap-allocated: a pane lives in `PaneStore.slots`, which is an
    /// ArrayList, so opening ANY other pane while a run is in flight
    /// moves this struct. An `Io.Group` cannot be moved once it has a
    /// task — the task holds its address — and a moved one makes
    /// `cancel` wait forever, which is a wedged quit.
    group: *Io.Group,
    generation: u32 = 0,
    runner: Runner = .playwright,
    /// The project root the run happens in. Owned.
    cwd: ?[]u8 = null,
    state: State = .running,
    run: TestRun = .{},
    err: []const u8 = "",
    /// The extra args of the run in flight / last run. Owned.
    last_args: []const []u8 = &.{},
    rows: []const Row = &.{},
    /// The focused row.
    cursor: usize = 0,
    scroll: usize = 0,
    sort: Sort = .file_line,

    pub fn init(gpa: Allocator) Allocator.Error!TestsPane {
        const grp = try gpa.create(Io.Group);
        grp.* = .init;
        return .{ .snapshot = alloc.SnapshotArena.init(gpa), .group = grp };
    }

    pub fn deinit(self: *TestsPane, gpa: Allocator, io: Io) void {
        self.group.cancel(io);
        gpa.destroy(self.group);
        for (self.last_args) |a| gpa.free(a);
        gpa.free(self.last_args);
        if (self.cwd) |c| gpa.free(c);
        self.snapshot.deinit();
    }

    pub fn setCwd(self: *TestsPane, gpa: Allocator, root: []const u8) Allocator.Error!void {
        const copy = try gpa.dupe(u8, root);
        if (self.cwd) |c| gpa.free(c);
        self.cwd = copy;
    }

    pub fn setArgs(self: *TestsPane, gpa: Allocator, args: []const []const u8) Allocator.Error!void {
        const copy = try gpa.alloc([]u8, args.len);
        var n: usize = 0;
        errdefer {
            for (copy[0..n]) |a| gpa.free(a);
            gpa.free(copy);
        }
        for (args) |a| {
            copy[n] = try gpa.dupe(u8, a);
            n += 1;
        }
        for (self.last_args) |a| gpa.free(a);
        gpa.free(self.last_args);
        self.last_args = copy;
    }

    /// The case under the cursor (a case, its error, or its trace row).
    pub fn selected(self: *const TestsPane) ?*const TestCase {
        if (self.cursor >= self.rows.len) return null;
        const i = self.rows[self.cursor].caseOf() orelse return null;
        return &self.run.tests[i];
    }

    pub fn title(self: *const TestsPane) []const u8 {
        return switch (self.state) {
            .running => "tests …",
            .failed => "tests ✗",
            .done => if (self.run.count(.failed) > 0) "tests ✗" else "tests ✓",
        };
    }

    /// The order the rows follow: natural (file, then line) or slowest first.
    pub fn order(self: *const TestsPane, arena: Allocator) Allocator.Error![]u32 {
        const idx = try arena.alloc(u32, self.run.tests.len);
        for (idx, 0..) |*x, i| x.* = @intCast(i);
        if (self.sort == .duration_desc) {
            const Ctx = struct {
                tests: []const TestCase,
                fn lt(ctx: @This(), a: u32, b: u32) bool {
                    const da = ctx.tests[a].duration_ms;
                    const db = ctx.tests[b].duration_ms;
                    if (da != db) return da > db;
                    return a < b;
                }
            };
            std.mem.sort(u32, idx, Ctx{ .tests = self.run.tests }, Ctx.lt);
        }
        return idx;
    }

    /// Rebuild `rows` on the snapshot arena from `run` and `sort`,
    /// keeping the cursor on the same case.
    pub fn rebuildRows(self: *TestsPane) Allocator.Error!void {
        const keep: ?u32 = if (self.cursor < self.rows.len) self.rows[self.cursor].caseOf() else null;
        const a = self.snapshot.allocator();
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        for (self.run.global_errors) |g| try rows.append(a, .{ .global_err = g });
        const idx = try self.order(a);
        var last_file: []const u8 = "";
        var cursor: ?usize = null;
        for (idx) |i| {
            const tc = self.run.tests[i];
            if (self.sort == .file_line and !std.mem.eql(u8, tc.file, last_file)) {
                try rows.append(a, .{ .file = tc.file });
                last_file = tc.file;
            }
            if (keep != null and keep.? == i) cursor = rows.items.len;
            try rows.append(a, .{ .case = i });
            if (tc.err) |e| {
                var lines = std.mem.splitScalar(u8, e, '\n');
                while (lines.next()) |l| try rows.append(a, .{ .err_line = .{ .case = i, .text = l } });
            }
            if (tc.trace_path != null) try rows.append(a, .{ .trace = i });
        }
        self.rows = try rows.toOwnedSlice(a);
        self.cursor = cursor orelse firstCaseRow(self.rows, null);
    }
};

/// The row of the first case (of `status`, when given), else 0.
fn firstCaseRow(rows: []const Row, status: ?Status) usize {
    _ = status;
    for (rows, 0..) |r, i| if (r == .case) return i;
    return 0;
}

pub fn find(app: *App) ?PaneId {
    return app.panes.findKind(.tests);
}

fn activeTests(app: *App) ?struct { id: PaneId, p: *TestsPane } {
    const id = app.active orelse return null;
    const pane = app.panes.get(id) orelse return null;
    return switch (pane.*) {
        .tests => |*p| .{ .id = id, .p = p },
        else => null,
    };
}

/// The project root for Playwright: the nearest `package.json` at or
/// above the active file, within the workspace.
fn projectRoot(app: *App) CommandError![]const u8 {
    return runners.findManifestDir(app.io, runners.startDir(app), &.{"package.json"}, app.workspace) orelse
        app.diag.fail(app.frame.allocator(), "playwright: no package.json found in {s} or any parent", .{app.workspace});
}

/// Start (or restart) a Playwright run with `extra` args: the one
/// tests pane, below the active pane the first time.
pub fn run(app: *App, extra: []const []const u8) CommandError!PaneId {
    return openRun(app, .playwright, try projectRoot(app), extra);
}

/// `dotnet test <extra>` at `root` in the one tests pane.
pub fn runDotnet(app: *App, root: []const u8, extra: []const []const u8) CommandError!PaneId {
    return openRun(app, .dotnet, root, extra);
}

fn openRun(app: *App, runner: Runner, root: []const u8, extra: []const []const u8) CommandError!PaneId {
    const id = find(app) orelse blk: {
        var pane = try TestsPane.init(app.gpa);
        errdefer pane.deinit(app.gpa, app.io);
        const id = try app.panes.add(.{ .tests = pane });
        pane = undefined; // moved into the store
        const layout = app.layouts.current();
        if (app.active) |cur| if (layout.leafOf(cur) != null) {
            _ = layout.split(cur, .horizontal, id) catch {};
        };
        break :blk id;
    };
    app.showPane(id);
    const p = &app.panes.get(id).?.tests;
    p.runner = runner;
    try p.setCwd(app.gpa, root);
    try p.setArgs(app.gpa, extra);
    try start(app, id, p);
    return id;
}

fn start(app: *App, id: PaneId, p: *TestsPane) CommandError!void {
    const root = p.cwd orelse app.workspace;
    p.generation +%= 1;
    p.state = .running;
    p.cursor = 0;
    p.scroll = 0;
    app.needs_render = true;
    const gpa = app.gpa;
    const env = try gpa.create(std.process.Environ.Map);
    errdefer gpa.destroy(env);
    env.* = try app.env.clone(gpa);
    errdefer env.deinit();
    try env.put("PW_TEST_HTML_REPORT_OPEN", "never");
    const extra = try gpa.alloc([]const u8, p.last_args.len);
    var n: usize = 0;
    errdefer {
        for (extra[0..n]) |a| gpa.free(a);
        gpa.free(extra);
    }
    for (p.last_args) |a| {
        extra[n] = try gpa.dupe(u8, a);
        n += 1;
    }
    const cwd = try gpa.dupe(u8, root);
    errdefer gpa.free(cwd);
    const workspace = try gpa.dupe(u8, app.workspace);
    errdefer gpa.free(workspace);
    p.group.concurrent(app.io, worker, .{ &app.events, app.io, gpa, p.runner, cwd, workspace, env, extra, p.generation, id }) catch |err| {
        p.state = .failed;
        p.err = "could not start the worker";
        return app.diag.fail(app.frame.allocator(), "{s}: could not start the worker: {s}", .{ p.runner.label(), @errorName(err) });
    };
}

/// `result` is destroyed on every path. A stale generation or a closed
/// pane is dropped; a run is recorded into the flaky history.
pub fn handle(app: *App, result: *Result) Allocator.Error!void {
    defer result.destroy(app.gpa);
    const pane = app.panes.get(result.pane) orelse return;
    const p = switch (pane.*) {
        .tests => |*p| p,
        else => return,
    };
    if (result.generation != p.generation) return;
    p.snapshot.reset();
    p.rows = &.{};
    const a = p.snapshot.allocator();
    if (result.run) |src| {
        p.state = .done;
        p.err = "";
        p.run = try copyRun(a, src);
        try p.rebuildRows();
        // The first failure is the row to land on.
        for (p.rows, 0..) |r, i| if (r == .case and p.run.tests[r.case].status == .failed) {
            p.cursor = i;
            break;
        };
        const f = p.run.count(.failed);
        const ok = p.run.count(.passed);
        const s = p.run.count(.skipped);
        const arena = app.frame.allocator();
        if (f > 0) {
            const note: []const u8 = if (s > 0) try std.fmt.allocPrint(arena, ", {d} skipped", .{s}) else "";
            app.toast("tests: {d} failed, {d} passed{s}", .{ f, ok, note });
        } else {
            const note: []const u8 = if (s > 0) try std.fmt.allocPrint(arena, " ({d} skipped)", .{s}) else "";
            app.toast("tests: all {d} passed{s}", .{ ok, note });
        }
        try flaky.recordRun(app, p.run);
    } else {
        p.state = .failed;
        p.run = .{};
        p.err = try a.dupe(u8, result.err orelse "the run failed");
        app.toast("{s}: {s}", .{ p.runner.label(), firstLine(p.err) });
    }
    app.needs_render = true;
}

fn copyRun(a: Allocator, src: TestRun) Allocator.Error!TestRun {
    const tests = try a.alloc(TestCase, src.tests.len);
    for (src.tests, 0..) |tc, i| tests[i] = .{
        .title = try a.dupe(u8, tc.title),
        .suite_path = try a.dupe(u8, tc.suite_path),
        .file = try a.dupe(u8, tc.file),
        .line = tc.line,
        .status = tc.status,
        .duration_ms = tc.duration_ms,
        .err = if (tc.err) |e| try a.dupe(u8, e) else null,
        .trace_path = if (tc.trace_path) |tp| try a.dupe(u8, tp) else null,
    };
    const errs = try a.alloc([]const u8, src.global_errors.len);
    for (src.global_errors, 0..) |e, i| errs[i] = try a.dupe(u8, e);
    return .{ .command = try a.dupe(u8, src.command), .tests = tests, .global_errors = errs, .summary = try a.dupe(u8, src.summary) };
}

// ─── commands ───────────────────────────────────────────────────────────

fn runAll(app: *App) CommandError!void {
    _ = try run(app, &.{});
}

/// The active file, workspace-relative.
fn activeRel(app: *App) CommandError![]const u8 {
    const e = app.activeEditor() orelse return app.diag.fail(app.frame.allocator(), "open a .spec file first", .{});
    const path = e.buf.doc.path orelse return app.diag.fail(app.frame.allocator(), "open a saved .spec file first", .{});
    return app.relPath(path);
}

fn runFile(app: *App) CommandError!void {
    const rel = try activeRel(app);
    _ = try run(app, &.{rel});
}

/// Playwright's `file:line` selector.
fn runAtCursor(app: *App) CommandError!void {
    const rel = try activeRel(app);
    const e = app.activeEditor().?;
    const sel = try std.fmt.allocPrint(app.frame.allocator(), "{s}:{d}", .{ rel, e.buf.editor.rowCol().row + 1 });
    _ = try run(app, &.{sel});
}

fn rerunFailed(app: *App) CommandError!void {
    _ = try run(app, &.{"--last-failed"});
}

/// The pane's `a` / `f` / `R`: the same three, for whichever tool the
/// pane last ran.
fn runAllFor(app: *App, runner: Runner) CommandError!void {
    return switch (runner) {
        .playwright => runAll(app),
        .dotnet => dotnetAll(app),
    };
}

fn runFileFor(app: *App, runner: Runner) CommandError!void {
    return switch (runner) {
        .playwright => runFile(app),
        .dotnet => dotnetFile(app),
    };
}

fn rerunFailedFor(app: *App, runner: Runner) CommandError!void {
    return switch (runner) {
        .playwright => rerunFailed(app),
        .dotnet => dotnetRerunFailed(app),
    };
}

fn rerunSame(app: *App, id: PaneId, p: *TestsPane) CommandError!void {
    try start(app, id, p);
}

// ─── dotnet test, the commands ──────────────────────────────────────────

/// The nearest project / solution for the .NET runner, and the SDK on
/// PATH; the toast names `dotnet.test`.
fn dotnetRoot(app: *App, which: enum { build, run }) CommandError![]const u8 {
    const arena = app.frame.allocator();
    const proj = (try dotnet.find(app.io, arena, runners.startDir(app), app.workspace)) orelse
        return app.diag.fail(arena, "dotnet.test: no *.csproj / *.sln found in {s} or any parent", .{app.workspace});
    if (!runners.onPath(app, "dotnet")) {
        try runners.offerInstall(app, "dotnet");
        return error.Failed;
    }
    return switch (which) {
        .build => proj.buildRoot(),
        .run => proj.runRoot(),
    };
}

/// `dotnet.test` / `test.run_all`: every test under the solution.
pub fn dotnetAll(app: *App) CommandError!void {
    const root = try dotnetRoot(app, .build);
    _ = try runDotnet(app, root, &.{});
}

/// `test.run_file`: the classes the active file declares, at its project.
pub fn dotnetFile(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const e = app.activeEditor() orelse return app.diag.fail(arena, "open a .cs test file first", .{});
    const path = e.buf.doc.path orelse return app.diag.fail(arena, "open a saved .cs test file first", .{});
    const filter = (try runners.dotnetFileFilter(app)) orelse return app.diag.fail(arena, "no test class in {s}", .{app.relPath(path)});
    const root = try dotnetRoot(app, .run);
    _ = try runDotnet(app, root, &.{ "--filter", filter });
}

/// `test.run_at_cursor`: the enclosing `Class.Method`.
pub fn dotnetAtCursor(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    if (app.activeEditor() == null) return app.diag.fail(arena, "open a .cs test file first", .{});
    const id = (try runners.dotnetTestAtCursor(app)) orelse return app.diag.fail(arena, "no test method around the cursor", .{});
    const root = try dotnetRoot(app, .run);
    _ = try runDotnet(app, root, &.{ "--filter", try dotnet.filterArg(arena, id) });
}

/// `test.rerun_failed` / `R`: the last run's failures by name. `dotnet
/// test` keeps no "last failed" of its own.
pub fn dotnetRerunFailed(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const id = find(app) orelse return app.diag.fail(arena, "no .NET test run to re-run yet", .{});
    const p = &app.panes.get(id).?.tests;
    if (p.runner != .dotnet or p.state != .done) return app.diag.fail(arena, "no .NET test run to re-run yet", .{});
    const filter = (try failedFilter(arena, p.run)) orelse return app.diag.fail(arena, "no failed .NET test to re-run", .{});
    const root = try arena.dupe(u8, p.cwd orelse app.workspace);
    _ = try runDotnet(app, root, &.{ "--filter", filter });
}

fn sortCmd(app: *App) CommandError!void {
    const at = activeTests(app) orelse return error.NoActivePane;
    at.p.sort = at.p.sort.next();
    try at.p.rebuildRows();
    app.needs_render = true;
}

/// Enter: the selected test's line in its file.
pub fn jumpToSelected(app: *App, p: *TestsPane) CommandError!void {
    const tc = p.selected() orelse return app.diag.fail(app.frame.allocator(), "select a test first", .{});
    if (tc.file.len == 0) return app.diag.fail(app.frame.allocator(), "that test has no file", .{});
    try jumpTo(app, tc.file, tc.line);
}

/// Open `rel` (workspace-relative, or absolute) at 1-based `line`.
pub fn jumpTo(app: *App, rel: []const u8, line: u32) CommandError!void {
    const path = if (std.fs.path.isAbsolute(rel)) rel else try std.fs.path.join(app.frame.allocator(), &.{ app.workspace, rel });
    const id = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(app.frame.allocator(), "cannot open {s}: {s}", .{ rel, @errorName(err) }),
    };
    if (app.panes.editor(id)) |e| e.buf.editor.placeCursor(line -| 1, 0);
    app.showPane(id);
}

/// `t` / the trace row: `npx playwright show-trace <trace.zip>` in a
/// pane below.
pub fn openTrace(app: *App, tc: *const TestCase) CommandError!void {
    const path = tc.trace_path orelse return app.diag.fail(app.frame.allocator(), "no trace was kept for `{s}` (traces are retained on failure)", .{tc.title});
    _ = try pty_pane.open(app, .{ .argv = &.{ "npx", "playwright", "show-trace", path }, .label = "trace", .placement = .below, .kind = .command });
}

fn openTraceCmd(app: *App) CommandError!void {
    const at = activeTests(app) orelse return error.NoActivePane;
    const tc = at.p.selected() orelse return app.diag.fail(app.frame.allocator(), "select a test first", .{});
    try openTrace(app, tc);
}

/// `h`: the failing test — title, place, error and the spec's source —
/// to Claude; `c` on the answer promotes it to a session.
fn healCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const at = activeTests(app) orelse return app.diag.fail(arena, "select a failing test in the results pane first", .{});
    const tc = at.p.selected() orelse return app.diag.fail(arena, "select a failing test first", .{});
    if (tc.status != .failed) return app.diag.fail(arena, "that test isn't failing — nothing to heal", .{});
    const path = if (std.fs.path.isAbsolute(tc.file)) tc.file else try std.fs.path.join(arena, &.{ app.workspace, tc.file });
    const src = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(512 * 1024)) catch "";
    const where = if (tc.suite_path.len == 0) try std.fmt.allocPrint(arena, "{s}:{d}", .{ tc.file, tc.line }) else try std.fmt.allocPrint(arena, "{s} › {s}  ({s}:{d})", .{ tc.suite_path, tc.title, tc.file, tc.line });
    const tool: []const u8 = switch (at.p.runner) {
        .playwright => "Playwright",
        .dotnet => ".NET",
    };
    const fence: []const u8 = switch (at.p.runner) {
        .playwright => "ts",
        .dotnet => "cs",
    };
    const prompt = try std.fmt.allocPrint(arena,
        \\This {s} test is failing. Work out why and propose a fix — change the test or the code under test as appropriate. Be concise; reply with the patch in a fenced block plus a short note.
        \\
        \\## Failing test
        \\{s}
        \\
        \\## Error
        \\```
        \\{s}
        \\```
        \\
        \\## {s}
        \\```{s}
        \\{s}
        \\```
    , .{ tool, where, tc.err orelse "", tc.file, fence, src });
    const title = try std.fmt.allocPrint(arena, "AI: heal {s}", .{tc.title});
    _ = try ai_app.ask(app, title, prompt, .ask, null);
}

// ─── keys / mouse ───────────────────────────────────────────────────────

pub fn handleKey(app: *App, id: PaneId, p: *TestsPane, k: Key) Allocator.Error!bool {
    app.needs_render = true;
    const last = p.rows.len -| 1;
    switch (k.code) {
        .down => p.cursor = @min(p.cursor + 1, last),
        .up => p.cursor -|= 1,
        .home => p.cursor = 0,
        .end => p.cursor = last,
        .enter => runToast(app, enterRow(app, p)),
        .esc => try app.forceClosePane(id),
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'j' => p.cursor = @min(p.cursor + 1, last),
                'k' => p.cursor -|= 1,
                'g' => p.cursor = 0,
                'G' => p.cursor = last,
                'r' => runToast(app, rerunSame(app, id, p)),
                'a' => runToast(app, runAllFor(app, p.runner)),
                'f' => runToast(app, runFileFor(app, p.runner)),
                'R' => runToast(app, rerunFailedFor(app, p.runner)),
                't' => runToast(app, openTraceCmd(app)),
                'h' => runToast(app, healCmd(app)),
                's' => runToast(app, sortCmd(app)),
                'q' => try app.forceClosePane(id),
                else => return false,
            }
        },
        else => return false,
    }
    return true;
}

fn enterRow(app: *App, p: *TestsPane) CommandError!void {
    if (p.cursor < p.rows.len and p.rows[p.cursor] == .trace) return openTrace(app, &p.run.tests[p.rows[p.cursor].trace]);
    return jumpToSelected(app, p);
}

fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| {
        if (err == error.Canceled) return;
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("tests: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

/// A click on a row focuses it; a second click on a case row enters it.
pub fn click(app: *App, p: *TestsPane, row: u32, m: Mouse) Allocator.Error!void {
    if (row >= p.rows.len) return;
    if (m.kind != .press or m.button != .left) return;
    if (p.cursor == row) {
        runToast(app, enterRow(app, p));
    } else {
        p.cursor = row;
    }
    app.needs_render = true;
}

pub fn scrollBy(p: *TestsPane, delta: i64) void {
    const cur: i64 = @intCast(p.cursor);
    const last: i64 = @intCast(p.rows.len -| 1);
    p.cursor = @intCast(std.math.clamp(cur + delta, 0, last));
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

pub const fixture_report =
    \\{"suites":[{"title":"login.spec.ts","file":"login.spec.ts","specs":[],"suites":[{"title":"auth","file":"login.spec.ts","specs":[
    \\{"title":"logs in","file":"login.spec.ts","line":7,"ok":true,"tests":[{"status":"expected","results":[{"status":"passed","duration":120}]}]},
    \\{"title":"rejects bad password","file":"login.spec.ts","line":15,"ok":false,"tests":[{"status":"unexpected","results":[{"status":"failed","duration":30,"errors":[{"message":"\u001b[31mError:\u001b[39m expect(received).toBe(expected)\nline 2"}],"attachments":[{"name":"trace","path":"/ws/test-results/login-rejects/trace.zip"}]}]}]},
    \\{"title":"skips this","file":"login.spec.ts","line":20,"tests":[{"status":"skipped","results":[{"status":"skipped","duration":0}]}]}
    \\]}]},{"title":"cart.spec.ts","file":"cart.spec.ts","specs":[{"title":"adds","file":"cart.spec.ts","line":3,"tests":[{"status":"flaky","results":[{"status":"failed","duration":200},{"status":"passed","duration":210}]}]}]}],
    \\"errors":[{"message":"Error: config broke\nat x"}]}
;

test "parseReport flattens suites, reads status / duration / error / trace, strips ANSI" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try parseReport(a, fixture_report);
    try t.expectEqual(@as(usize, 4), r.tests.len);
    try t.expectEqual(@as(usize, 1), r.count(.passed));
    try t.expectEqual(@as(usize, 1), r.count(.failed));
    try t.expectEqual(@as(usize, 1), r.count(.skipped));
    try t.expectEqual(@as(usize, 1), r.count(.flaky));
    const pass = r.tests[0];
    try t.expectEqualStrings("logs in", pass.title);
    try t.expectEqualStrings("auth", pass.suite_path);
    try t.expectEqual(@as(u32, 7), pass.line);
    try t.expectEqual(@as(u64, 120), pass.duration_ms);
    const fail = r.tests[1];
    try t.expectEqual(Status.failed, fail.status);
    try t.expectEqualStrings("Error: expect(received).toBe(expected)\nline 2", fail.err.?);
    try t.expectEqualStrings("/ws/test-results/login-rejects/trace.zip", fail.trace_path.?);
    try t.expectEqual(Status.flaky, r.tests[3].status);
    try t.expectEqual(@as(u64, 410), r.tests[3].duration_ms);
    try t.expectEqualStrings("", r.tests[3].suite_path);
    try t.expectEqual(@as(usize, 1), r.global_errors.len);
    try t.expectEqualStrings("Error: config broke", r.global_errors[0]);
    try t.expectError(error.NotJson, parseReport(a, "not json at all"));
    try t.expectEqualStrings("Error: boom at x", try stripAnsi(a, "\x1b[31mError:\x1b[39m boom\x1b[2m at x\x1b[22m"));
    try t.expectEqualStrings("npx playwright test --reporter=json --trace=retain-on-failure a.spec.ts:3", try cmdlineFor(a, .playwright, &.{"a.spec.ts:3"}));
    try t.expectEqual(@as(usize, 6), (try argvFor(a, .playwright, &.{"--last-failed"})).len);
    try t.expectEqualStrings("dotnet test --nologo --logger \"console;verbosity=normal\" --logger trx --filter \"FullyQualifiedName~Calc.Adds|FullyQualifiedName~P.Q\"", try cmdlineFor(a, .dotnet, &.{ "--filter", "FullyQualifiedName~Calc.Adds|FullyQualifiedName~P.Q" }));
    try t.expectEqual(@as(usize, 9), (try argvFor(a, .dotnet, &.{ "--filter", "x" })).len);
}

test "rows: grouped under file headers with error and trace rows; slowest-first drops the headers; the cursor follows its case" {
    var p = try TestsPane.init(t.allocator);
    defer p.deinit(t.allocator, t.io);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    p.run = try copyRun(p.snapshot.allocator(), try parseReport(arena_state.allocator(), fixture_report));
    p.state = .done;
    try p.rebuildRows();
    // global error, login header, 3 cases (+2 error lines +1 trace), cart header, 1 case.
    try t.expectEqual(@as(usize, 10), p.rows.len);
    try t.expect(p.rows[0] == .global_err);
    try t.expectEqualStrings("login.spec.ts", p.rows[1].file);
    try t.expect(p.rows[2] == .case and p.rows[2].case == 0);
    try t.expect(p.rows[3] == .case and p.rows[3].case == 1);
    try t.expect(p.rows[4] == .err_line and p.rows[5] == .err_line);
    try t.expect(p.rows[6] == .trace and p.rows[6].trace == 1);
    try t.expectEqualStrings("cart.spec.ts", p.rows[8].file);
    try t.expectEqual(@as(usize, 2), p.cursor);
    p.cursor = 6;
    try t.expectEqualStrings("rejects bad password", p.selected().?.title);
    p.sort = .duration_desc;
    try p.rebuildRows();
    // No headers; slowest (cart 410) first; the cursor stays on the failure.
    try t.expectEqual(@as(usize, 8), p.rows.len);
    try t.expect(p.rows[1] == .case and p.rows[1].case == 3);
    try t.expectEqualStrings("rejects bad password", p.selected().?.title);
    try t.expectEqualStrings("tests ✗", p.title());
    scrollBy(&p, 100);
    try t.expectEqual(@as(usize, 7), p.cursor);
}

test "test.run_playwright needs a package.json; a result lands in the pane and the flaky history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    try t.expectError(error.Failed, runAll(&app));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "no package.json") != null);
    app.diag.clear();
    // With a manifest the pane opens, running; a posted result fills it.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "package.json", .data = "{}\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "login.spec.ts", .data = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n" });
    const id = try run(&app, &.{"login.spec.ts"});
    const p = &app.panes.get(id).?.tests;
    try t.expectEqual(State.running, p.state);
    try t.expectEqualStrings("login.spec.ts", p.last_args[0]);
    // Whatever the worker returns (npx is not on the test's PATH, or it
    // is and fails), a result of ours with the fixture is the story.
    p.group.cancel(t.io);
    p.generation +%= 1;
    const r = try Result.create(t.allocator, p.generation, id);
    r.run = try parseReport(r.arena.allocator(), fixture_report);
    try handle(&app, r);
    try t.expectEqual(State.done, p.state);
    try t.expectEqual(@as(usize, 4), p.run.tests.len);
    try t.expectEqualStrings("rejects bad password", p.selected().?.title);
    // Three recorded (the skipped one says nothing); one outcome each is not wobbly yet.
    try t.expectEqual(@as(usize, 3), app.flaky.history.entries.count());
    try t.expect(!flaky.isWobbly(&app, "cart.spec.ts", "", "adds"));
    // Enter jumps to the failing test's line.
    app.showPane(id);
    _ = try handleKey(&app, id, p, .{ .code = .enter });
    const e = app.activeEditor().?;
    try t.expectEqualStrings("login.spec.ts", app.relPath(e.buf.doc.path.?));
    try t.expectEqual(@as(usize, 14), e.buf.editor.rowCol().row);
    // A stale result is dropped; an error result flips the state.
    const stale = try Result.create(t.allocator, p.generation -% 1, id);
    stale.err = "old";
    try handle(&app, stale);
    try t.expectEqual(State.done, p.state);
    const bad = try Result.create(t.allocator, p.generation, id);
    bad.err = try bad.arena.allocator().dupe(u8, "running `npx playwright test`: FileNotFound — is Playwright installed here?");
    try handle(&app, bad);
    try t.expectEqual(State.failed, p.state);
    try t.expectEqualStrings("tests ✗", p.title());
}

pub const fixture_dotnet_console =
    \\  Determining projects to restore...
    \\  Restored /ws/src/Tests/Tests.csproj (in 120 ms).
    \\  Tests -> /ws/src/Tests/bin/Debug/net8.0/Tests.dll
    \\Test run for /ws/src/Tests/bin/Debug/net8.0/Tests.dll (.NETCoreApp,Version=v8.0)
    \\Starting test execution, please wait...
    \\A total of 1 test files matched the specified pattern.
    \\  Passed Acme.Tests.CalcTests.Adds [3 ms]
    \\  Failed Acme.Tests.CalcTests.Divides [12 ms]
    \\  Error Message:
    \\   Assert.Equal() Failure: Values differ
    \\Expected: 2
    \\Actual:   3
    \\  Stack Trace:
    \\     at Acme.Tests.CalcTests.Divides() in /ws/src/Tests/CalcTests.cs:line 21
    \\     at System.RuntimeMethodHandle.InvokeMethod(Object target, Void** arguments, Signature sig, Boolean isConstructor)
    \\  Skipped Acme.Tests.CalcTests.Later
    \\  Passed Acme.Tests.CalcTests.Adds(a: 2, b: 3) [< 1 ms]
    \\
    \\Results File: /ws/src/Tests/TestResults/host_2026-09-08_10_00_00.trx
    \\
    \\Failed!  - Failed:     1, Passed:     2, Skipped:     1, Total:     4, Duration: 16 ms - Tests.dll (net8.0)
    \\
;

test "parseDotnet: the status lines are rows, a failure carries its message and its first frame's file:line, the tally is kept" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try parseDotnet(a, fixture_dotnet_console, "/ws");
    try t.expectEqual(@as(usize, 4), r.tests.len);
    try t.expectEqual(@as(usize, 2), r.count(.passed));
    try t.expectEqual(@as(usize, 1), r.count(.failed));
    try t.expectEqual(@as(usize, 1), r.count(.skipped));
    const adds = r.tests[0];
    try t.expectEqualStrings("Adds", adds.title);
    try t.expectEqualStrings("Acme.Tests.CalcTests", adds.suite_path);
    try t.expectEqual(@as(u64, 3), adds.duration_ms);
    try t.expectEqualStrings("", adds.file);
    const div = r.tests[1];
    try t.expectEqual(Status.failed, div.status);
    try t.expectEqual(@as(u64, 12), div.duration_ms);
    try t.expectEqualStrings("Assert.Equal() Failure: Values differ\nExpected: 2\nActual:   3", div.err.?);
    try t.expectEqualStrings("src/Tests/CalcTests.cs", div.file);
    try t.expectEqual(@as(u32, 21), div.line);
    try t.expectEqual(Status.skipped, r.tests[2].status);
    try t.expectEqualStrings("Later", r.tests[2].title);
    try t.expectEqualStrings("Adds(a: 2, b: 3)", r.tests[3].title);
    try t.expectEqual(@as(u64, 0), r.tests[3].duration_ms);
    try t.expectEqualStrings("Failed!  - Failed:     1, Passed:     2, Skipped:     1, Total:     4, Duration: 16 ms - Tests.dll (net8.0)", r.summary);
    try t.expectEqual(@as(usize, 0), r.global_errors.len);
    try t.expectEqualStrings("/ws/src/Tests/TestResults/host_2026-09-08_10_00_00.trx", trxPathIn(fixture_dotnet_console).?);
    try t.expectEqualStrings("FullyQualifiedName=Acme.Tests.CalcTests.Divides", (try failedFilter(a, r)).?);
    // The older host's signs, a duration in seconds and minutes, and the compiler's errors.
    const old = "√ Acme.One [1 s]\nX Acme.Two [1 m 2 s]\n! Acme.Three\n/ws/A.cs(3,5): error CS1002: ; expected [/ws/A.csproj]\n/ws/A.cs(3,5): error CS1002: ; expected [/ws/A.csproj]\nBuild FAILED.\n";
    const o = try parseDotnet(a, old, "/ws");
    try t.expectEqual(@as(usize, 3), o.tests.len);
    try t.expectEqual(@as(u64, 1000), o.tests[0].duration_ms);
    try t.expectEqual(@as(u64, 62_000), o.tests[1].duration_ms);
    try t.expectEqual(Status.skipped, o.tests[2].status);
    try t.expectEqual(@as(usize, 1), o.global_errors.len);
    try t.expectEqualStrings("/ws/A.cs(3,5): error CS1002: ; expected [/ws/A.csproj]", o.global_errors[0]);
    try t.expectEqualStrings("", o.summary);
    // A build with nothing else is errors only; a passing tally without failures is kept as is.
    const ok = try parseDotnet(a, "Passed!  - Failed:     0, Passed:     1, Skipped:     0, Total:     1, Duration: 1 ms\n", "/ws");
    try t.expectEqual(@as(usize, 0), ok.tests.len);
    try t.expect(std.mem.startsWith(u8, ok.summary, "Passed!"));
    try t.expect((try failedFilter(a, ok)) == null);
}

pub const fixture_trx =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<TestRun id="a1" name="host@box 2026-09-08" xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">
    \\  <Results>
    \\    <UnitTestResult executionId="e1" testId="t1" testName="Adds" computerName="box" duration="00:00:00.0034567" outcome="Passed" testType="13cdc9d9" testListId="8c84fa94" relativeResultsDirectory="e1" />
    \\    <UnitTestResult executionId="e2" testId="t2" testName="Divides" computerName="box" duration="00:00:01.5000000" outcome="Failed" testType="13cdc9d9" testListId="8c84fa94" relativeResultsDirectory="e2">
    \\      <Output>
    \\        <ErrorInfo>
    \\          <Message>Assert.Equal() Failure: Values differ&#xD;
    \\Expected: 2&#xD;
    \\Actual:   3</Message>
    \\          <StackTrace>   at Acme.Tests.CalcTests.Divides() in C:\ws\src\Tests\CalcTests.cs:line 21&#xD;
    \\   at System.RuntimeMethodHandle.InvokeMethod(Object target)</StackTrace>
    \\        </ErrorInfo>
    \\      </Output>
    \\    </UnitTestResult>
    \\    <UnitTestResult executionId="e3" testId="t3" testName="Later" computerName="box" duration="00:00:00.0000000" outcome="NotExecuted" testType="13cdc9d9" testListId="8c84fa94" relativeResultsDirectory="e3" />
    \\  </Results>
    \\  <TestDefinitions>
    \\    <UnitTest name="Adds" storage="/ws/tests.dll" id="t1">
    \\      <Execution id="e1" />
    \\      <TestMethod codeBase="/ws/tests.dll" adapterTypeName="executor://xunit" className="Acme.Tests.CalcTests" name="Adds" />
    \\    </UnitTest>
    \\    <UnitTest name="Divides" storage="/ws/tests.dll" id="t2">
    \\      <Execution id="e2" />
    \\      <TestMethod codeBase="/ws/tests.dll" adapterTypeName="executor://xunit" className="Acme.Tests.CalcTests, Tests, Version=1.0.0.0" name="Divides" />
    \\    </UnitTest>
    \\  </TestDefinitions>
    \\</TestRun>
;

test "parseTrx: outcomes, durations to the ms, the class from the definitions, the message and the frame unescaped" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try parseTrx(a, fixture_trx, "C:\\ws");
    try t.expectEqual(@as(usize, 3), r.tests.len);
    try t.expectEqualStrings("Acme.Tests.CalcTests", r.tests[0].suite_path);
    try t.expectEqualStrings("Adds", r.tests[0].title);
    try t.expectEqual(Status.passed, r.tests[0].status);
    try t.expectEqual(@as(u64, 3), r.tests[0].duration_ms);
    const div = r.tests[1];
    try t.expectEqual(Status.failed, div.status);
    try t.expectEqual(@as(u64, 1500), div.duration_ms);
    try t.expectEqualStrings("Acme.Tests.CalcTests", div.suite_path);
    try t.expectEqualStrings("Assert.Equal() Failure: Values differ\nExpected: 2\nActual:   3", div.err.?);
    try t.expectEqualStrings("src\\Tests\\CalcTests.cs", div.file);
    try t.expectEqual(@as(u32, 21), div.line);
    // No definition for t3: the display name, no class; NotExecuted is skipped.
    try t.expectEqualStrings("Later", r.tests[2].title);
    try t.expectEqualStrings("", r.tests[2].suite_path);
    try t.expectEqual(Status.skipped, r.tests[2].status);
    try t.expectEqual(@as(usize, 0), (try parseTrx(a, "<TestRun/>", "/ws")).tests.len);
}

test "locateSources: a passed row is found by class and method in the project's .cs files, bin/ and obj/ skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try tmp.dir.createDirPath(t.io, "Tests/bin/Debug");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "Tests/bin/Debug/CalcTests.cs", .data = "public class CalcTests { public void Adds() {} }" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "Tests/CalcTests.cs", .data = "using Xunit;\n\npublic class CalcTests\n{\n    [Fact]\n    public void Adds()\n    {\n        Adds2();\n    }\n\n    [Theory]\n    public void Divides(int a) => Assert.True(a > 0);\n}\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "Tests/Other.cs", .data = "public class Other { public void Adds() {} }\n" });
    var tests = [_]TestCase{
        .{ .title = "Adds", .suite_path = "Acme.CalcTests", .file = "", .line = 0, .status = .passed, .duration_ms = 1, .err = null, .trace_path = null },
        .{ .title = "Divides(a: 1)", .suite_path = "Acme.CalcTests", .file = "", .line = 0, .status = .passed, .duration_ms = 1, .err = null, .trace_path = null },
        .{ .title = "Gone", .suite_path = "Acme.CalcTests", .file = "", .line = 0, .status = .passed, .duration_ms = 1, .err = null, .trace_path = null },
        .{ .title = "Kept", .suite_path = "", .file = "x.cs", .line = 3, .status = .failed, .duration_ms = 1, .err = null, .trace_path = null },
    };
    try locateSources(a, t.io, root, root, &tests);
    try t.expectEqualStrings("Tests/CalcTests.cs", tests[0].file);
    try t.expectEqual(@as(u32, 6), tests[0].line);
    try t.expectEqualStrings("Tests/CalcTests.cs", tests[1].file);
    try t.expectEqual(@as(u32, 12), tests[1].line);
    try t.expectEqualStrings("", tests[2].file);
    try t.expectEqualStrings("x.cs", tests[3].file);
}

test "dotnet.test opens the pane on a project; a dotnet result lands with its summary; R re-runs the failures by name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    try t.expectError(error.Failed, dotnetAll(&app));
    try t.expect(std.mem.startsWith(u8, app.diag.msg.?, "dotnet.test: no *.csproj / *.sln found in "));
    app.diag.clear();
    try tmp.dir.createDirPath(t.io, "src/Tests");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "All.sln", .data = "" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/Tests/Tests.csproj", .data = "<Project/>" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/Tests/CalcTests.cs", .data = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n21\n22\n" });
    // The SDK is not on PATH here: the install box, no pane.
    if (!runners.onPath(&app, "dotnet")) {
        try t.expectError(error.Failed, dotnetAll(&app));
        try t.expect(app.overlay == .confirm);
        app.overlay.deinit(app.gpa);
        app.overlay = .none;
    }
    const id = try runDotnet(&app, root, &.{});
    const p = &app.panes.get(id).?.tests;
    try t.expectEqual(Runner.dotnet, p.runner);
    try t.expectEqualStrings(root, p.cwd.?);
    try t.expectEqual(State.running, p.state);
    p.group.cancel(t.io);
    p.generation +%= 1;
    const r = try Result.create(t.allocator, p.generation, id);
    r.run = try parseDotnet(r.arena.allocator(), fixture_dotnet_console, "/ws");
    try handle(&app, r);
    try t.expectEqual(State.done, p.state);
    try t.expectEqual(@as(usize, 4), p.run.tests.len);
    try t.expect(std.mem.startsWith(u8, p.run.summary, "Failed!"));
    try t.expectEqualStrings("Divides", p.selected().?.title);
    try t.expectEqualStrings("tests ✗", p.title());
    // Enter jumps to the failing test's line.
    app.showPane(id);
    _ = try handleKey(&app, id, p, .{ .code = .enter });
    const e = app.activeEditor().?;
    try t.expectEqualStrings("src/Tests/CalcTests.cs", app.relPath(e.buf.doc.path.?));
    try t.expectEqual(@as(usize, 20), e.buf.editor.rowCol().row);
    // R: the failures by name, at the pane's root.
    if (runners.onPath(&app, "dotnet")) {
        try dotnetRerunFailed(&app);
        try t.expectEqualStrings("--filter", p.last_args[0]);
        try t.expectEqualStrings("FullyQualifiedName=Acme.Tests.CalcTests.Divides", p.last_args[1]);
        p.group.cancel(t.io);
    }
}

// ─── the group must not move ────────────────────────────────────────────

/// A worker parked on a pipe nobody writes to — `e2e/cancel_probe.zig`'s
/// shape, and the worst case for `Io.Group.cancel`.
const MoveProbe = struct {
    io: Io,
    fd: std.posix.fd_t,
    /// Set once the worker is about to block.
    entered: Io.Event = .unset,

    fn run(p: *MoveProbe) Io.Cancelable!void {
        const f: Io.File = .{ .handle = p.fd, .flags = .{ .nonblocking = false } };
        var buf: [16]u8 = undefined;
        p.entered.set(p.io);
        _ = f.readStreaming(p.io, &.{&buf}) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            else => {},
        };
    }
};

/// `TestsPane.deinit` on a thread of its own, so a `cancel` that never
/// returns is a failing test rather than a hung suite.
const Closer = struct {
    pane: *TestsPane,
    gpa: Allocator,
    io: Io,
    done: Io.Event = .unset,

    fn run(c: *Closer) void {
        c.pane.deinit(c.gpa, c.io);
        c.done.set(c.io);
    }
};

// `tools/break-check.sh` cannot grade this one: with the break in
// place the test FAILS by name (the watchdog, at ~10 s), but the
// abandoned worker then touches the group it was started with — the
// memory the moved pane no longer owns — and the binary dies before
// the runner prints its per-binary summary, which is the line the
// script counts. Break-check it by hand, under a hard timeout, and
// read the `FAIL … (TestsGroupMovedAndCancelWedged)` verdict line.
test "the tests pane's group survives the pane store moving it under a live worker" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = t.io;
    // `NoRemap` so the store's growth really relocates the panes — the
    // whole point of the test (`core/alloc.zig`).
    var nr = alloc.NoRemap.init(t.allocator);
    const gpa = nr.allocator();

    const fds = try Io.Threaded.pipe2(.{});
    const read_end: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const write_end: Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer read_end.close(io);
    defer write_end.close(io);

    // No `defer store.deinit()`: past the watchdog the pane is wedged
    // inside the closer thread's `deinit` and must not be deinit'd twice.
    var store = app_mod.PaneStore.init(gpa, io);
    const id = try store.add(.{ .tests = try TestsPane.init(gpa) });

    var probe: MoveProbe = .{ .io = io, .fd = fds[0] };
    try store.get(id).?.tests.group.concurrent(io, MoveProbe.run, .{&probe});
    try probe.entered.wait(io);
    try io.sleep(.fromMilliseconds(50), .awake);

    // Open panes until `slots` reallocates: the pane — and anything
    // living inside it — moves, which is what opening any pane during a
    // run does in the app.
    const capacity_before = store.slots.capacity;
    const addr_before = @intFromPtr(&store.slots.items[id].?.tests);
    while (store.slots.capacity == capacity_before) _ = try store.add(.{ .git_status = .{ .repo = 0 } });
    try t.expect(@intFromPtr(&store.slots.items[id].?.tests) != addr_before);

    var closer: Closer = .{ .pane = &store.slots.items[id].?.tests, .gpa = gpa, .io = io };
    const th = try std.Thread.spawn(.{}, Closer.run, .{&closer});
    closer.done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(10_000), .clock = .awake } }) catch |err| switch (err) {
        // The group moved with the pane: the running task holds the
        // address the group had before, and `cancel` waits forever on a
        // task the group at the new address cannot see.
        error.Timeout => return error.TestsGroupMovedAndCancelWedged,
        error.Canceled => return error.Canceled,
    };
    th.join();
    store.slots.items[id] = null; // `Closer` has already deinit'd it
    store.deinit();
}
