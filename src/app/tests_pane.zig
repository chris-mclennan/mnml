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
//! And `zig` (`Runner.zig`: the `test.*` ids on a project with a
//! `build.zig`): `test.run_all` is `zig build test`, `run_file` is
//! `zig test <file>`, `run_at_cursor` is `zig build test
//! -Dtest-filter=<name>` when the build.zig declares that option (as
//! this repo's does) and `zig test <file> --test-filter <name>`
//! otherwise. `parseZig` reads both the default test runner's lines and
//! the build runner's failure report; a failure's file:line is its own
//! frame, a passed test is found by its `test "…"` line.
//!
//! And vitest (`Runner.vitest`: the `test.*` ids on an npm project whose
//! package.json names vitest — `npx vitest run --reporter=json
//! --includeTaskLocation`, the Jest-shaped report) and pytest
//! (`Runner.pytest`: `pytest.run` / `pytest.failed` and the `test.*` ids
//! on a Python project — `pytest -q -rA` with a JUnit file under
//! `.mnml/`, the `-rA` lines when the file is missing). Each runner is
//! one arm of the `Runner` switches: its argv, its parser, the shape of
//! a re-run of the failures — vitest's `-t '^(a|b)$'` with the failing
//! files, pytest's node ids — and the rest of the pane is shared.
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
const builtin = @import("builtin");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const alloc = @import("../core/alloc.zig");
const pty_pane = @import("pty_pane.zig");
const runners = @import("runners.zig");
const dotnet = @import("dotnet.zig");
const ai_app = @import("ai.zig");
const flaky = @import("flaky.zig");
const jobs = @import("jobs.zig");

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
    zig,
    /// `npx vitest run --reporter=json` — the Jest-shaped report.
    vitest,
    /// `pytest -q -rA --junitxml=…` — the JUnit file, the console as a fallback.
    pytest,

    pub fn label(r: Runner) []const u8 {
        return switch (r) {
            .playwright => "playwright",
            .dotnet => "dotnet test",
            .zig => "zig test",
            .vitest => "vitest",
            .pytest => "pytest",
        };
    }

    /// The tool's name in a heal prompt, and the fence its sources take.
    pub fn healTool(r: Runner) []const u8 {
        return switch (r) {
            .playwright => "Playwright",
            .dotnet => ".NET",
            .vitest => "vitest",
            .pytest => "pytest",
            .zig => "Zig",
        };
    }

    pub fn fence(r: Runner) []const u8 {
        return switch (r) {
            .playwright, .vitest => "ts",
            .dotnet => "cs",
            .pytest => "py",
            .zig => "zig",
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
    /// `parseZig`: the location is the test's own frame, not a
    /// caller's — a later `in test.<name>` frame must not be replaced.
    frame_own: bool = false,
};

pub const TestRun = struct {
    command: []const u8 = "",
    tests: []const TestCase = &.{},
    /// Config errors and the like, one line each.
    global_errors: []const []const u8 = &.{},
    /// The tool's own tally line, when it prints one (`Failed!  - Failed: 1, …`).
    summary: []const u8 = "",
    /// Passes the tool counted but never named: `zig build test` reports
    /// only the failures and a `4/5 tests passed` tally.
    passed_unlisted: usize = 0,

    pub fn count(r: TestRun, status: Status) usize {
        var n: usize = 0;
        for (r.tests) |tc| n += @intFromBool(tc.status == status);
        return n;
    }

    /// Every pass: the named rows plus the tally's unnamed ones.
    pub fn passed(r: TestRun) usize {
        return r.count(.passed) + r.passed_unlisted;
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

/// A stack frame names the file by its real path (the compiler records
/// it resolved), so under a workspace reached through a symlink —
/// macOS's `/var` and `/tmp`, a `~/work` link — a failure's file is
/// `/private/var/…/CalcTests.cs` where the workspace is `/var/…`, the
/// prefix test misses and the row keeps an absolute path. Compare the
/// real paths: a file inside the real workspace becomes relative to it,
/// so it heads the same group as its passing siblings and Enter opens
/// the editor already open on it.
fn realRelative(arena: Allocator, io: Io, workspace: []const u8, tests: []TestCase) Allocator.Error!void {
    var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
    var ws_real: ?[]const u8 = null;
    for (tests) |*tc| {
        if (!std.fs.path.isAbsolute(tc.file)) continue;
        if (ws_real == null) {
            const n = Io.Dir.cwd().realPathFile(io, workspace, &ws_buf) catch return;
            ws_real = ws_buf[0..n];
        }
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = Io.Dir.cwd().realPathFile(io, tc.file, &buf) catch continue;
        const rel = try relativeTo(arena, buf[0..n], ws_real.?);
        if (!std.fs.path.isAbsolute(rel)) tc.file = rel;
    }
}

/// `relativeTo`, against the workspace as mnml names it and as the
/// tool's own cwd names it: a tool started under `/var/folders/…` prints
/// `/private/var/folders/…` (node's `process.cwd()`, a shell's `$PWD`
/// resolve the symlink), and a row's path must still be short and its
/// flaky key stable. `real` is the workspace's real path, or empty.
fn relativeToEither(arena: Allocator, path: []const u8, workspace: []const u8, real: []const u8) Allocator.Error![]const u8 {
    const rel = try relativeTo(arena, path, workspace);
    if (rel.len != path.len or real.len == 0) return rel;
    return relativeTo(arena, path, real);
}

/// The workspace's real path (symlinks resolved), or empty when it
/// cannot be read.
fn realWorkspace(io: Io, arena: Allocator, workspace: []const u8) Allocator.Error![]const u8 {
    var dir = Io.Dir.cwd().openDir(io, workspace, .{}) catch return "";
    defer dir.close(io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = dir.realPath(io, &buf) catch return "";
    return arena.dupe(u8, buf[0..n]);
}

/// The `Results File: <path>.trx` line, when the trx logger ran.
pub fn trxPathIn(text: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, "Results File:") orelse return null;
    const rest = text[at + "Results File:".len ..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const path = std.mem.trim(u8, rest[0..end], " \t\r");
    return if (std.mem.endsWith(u8, path, ".trx")) path else null;
}

// ─── zig test / zig build test ─────────────────────────────────────────

/// The output of `zig test` and of `zig build test`, both on stderr.
/// The default test runner names each test `<module>.test.<name>` and
/// prints a line per test, the failure's message on its line, then
/// `FAIL (<error>)`, its frames, and a tally:
///
///     1/4 shapes.test.rect area...OK
///     3/4 shapes.test.deliberately failing...expected 5, found 4
///     FAIL (TestExpectedEqual)
///     /…/src/shapes.zig:67:5: 0x… in test.deliberately failing (test)
///     3 passed; 0 skipped; 1 failed.
///
/// The build runner reports only the failures, indented under
/// `error: '<name>' failed:`, and a `Build Summary` whose `N/M tests
/// passed` is where the passes come from (`passed_unlisted`):
///
///     error: 'shapes.test.deliberately failing' failed:
///            expected 5, found 4
///            /…/src/shapes.zig:67:5: 0x… in test.deliberately failing (test)
///     Build Summary: 1/3 steps succeeded (1 failed); 4/5 tests passed (1 failed)
///
/// A failure's file:line is the frame in its own test (`in test.<name>`),
/// else the first frame under `workspace`; a compile error
/// (`src/a.zig:3:5: error: …`) is a global error.
pub fn parseZig(arena: Allocator, text: []const u8, workspace: []const u8) Allocator.Error!TestRun {
    var tests: std.ArrayListUnmanaged(TestCase) = .empty;
    var errors: std.ArrayListUnmanaged([]const u8) = .empty;
    var summary: []const u8 = "";
    var tally_passed: ?usize = null;
    var cur: ?usize = null;
    var in_frames = false;
    var msg: std.ArrayListUnmanaged(u8) = .empty;
    var msg_lines: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const trimmed = std.mem.trim(u8, try stripAnsi(arena, raw), " \t\r");
        if (zigCaseLine(trimmed)) |c| {
            try finishZigCase(arena, &tests, cur, &msg);
            msg_lines = 0;
            in_frames = false;
            const split = splitZigName(c.name);
            try tests.append(arena, .{
                .title = split.title,
                .suite_path = split.suite,
                .file = "",
                .line = 0,
                .status = c.status,
                .duration_ms = 0,
                .err = null,
                .trace_path = null,
            });
            cur = tests.items.len - 1;
            if (c.status == .failed and c.message.len > 0) {
                try msg.appendSlice(arena, c.message);
                msg_lines = 1;
            }
            continue;
        }
        if (zigTally(trimmed)) |tl| {
            try finishZigCase(arena, &tests, cur, &msg);
            cur = null;
            summary = try arena.dupe(u8, trimmed);
            tally_passed = tl.passed;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "Build Summary:")) {
            try finishZigCase(arena, &tests, cur, &msg);
            cur = null;
            summary = try arena.dupe(u8, trimmed);
            if (buildSummaryPassed(trimmed)) |n| tally_passed = n;
            continue;
        }
        if (zigCompileError(trimmed)) {
            var dup = false;
            for (errors.items) |e| if (std.mem.eql(u8, e, trimmed)) {
                dup = true;
            };
            if (!dup and errors.items.len < 20) try errors.append(arena, try arena.dupe(u8, trimmed));
            continue;
        }
        const i = cur orelse continue;
        if (tests.items[i].status != .failed) continue;
        if (zigFrame(trimmed)) |fr| {
            in_frames = true;
            const own = std.mem.startsWith(u8, fr.func, "test.") or std.mem.startsWith(u8, fr.func, "decltest.");
            const here = workspace.len > 0 and std.mem.startsWith(u8, fr.path, workspace);
            const tc = &tests.items[i];
            if (tc.file.len == 0 or (own and !tc.frame_own)) {
                if (own or (here and !tc.frame_own)) {
                    tc.file = try relativeTo(arena, fr.path, workspace);
                    tc.line = fr.line;
                    tc.frame_own = own;
                }
            }
            continue;
        }
        if (in_frames) continue; // the frame's source echo and its caret
        if (std.mem.startsWith(u8, trimmed, "FAIL (") or std.mem.startsWith(u8, trimmed, "SKIP")) {
            if (msg.items.len > 0) try msg.append(arena, '\n');
            try msg.appendSlice(arena, trimmed);
            continue;
        }
        if (trimmed.len > 0 and msg_lines < 6 and !std.mem.startsWith(u8, trimmed, "failed command:")) {
            if (msg.items.len > 0) try msg.append(arena, '\n');
            try msg.appendSlice(arena, trimmed);
            msg_lines += 1;
        }
    }
    try finishZigCase(arena, &tests, cur, &msg);
    var out: TestRun = .{ .tests = try tests.toOwnedSlice(arena), .global_errors = try errors.toOwnedSlice(arena), .summary = summary };
    if (tally_passed) |n| out.passed_unlisted = n -| out.count(.passed);
    return out;
}

fn finishZigCase(arena: Allocator, tests: *std.ArrayListUnmanaged(TestCase), cur: ?usize, msg: *std.ArrayListUnmanaged(u8)) Allocator.Error!void {
    const i = cur orelse return;
    if (msg.items.len > 0) tests.items[i].err = try msg.toOwnedSlice(arena);
    msg.* = .empty;
}

const ZigCase = struct { name: []const u8, status: Status, message: []const u8 };

/// `3/4 shapes.test.x...OK` (the test runner) or `error: 'shapes.test.x'
/// failed:` (the build runner). A test-runner line whose tail is neither
/// `OK` nor `SKIP` is a failure and the tail is its message.
fn zigCaseLine(line: []const u8) ?ZigCase {
    if (std.mem.startsWith(u8, line, "error: '")) {
        const rest = line["error: '".len..];
        const close = std.mem.indexOf(u8, rest, "' failed") orelse return null;
        return .{ .name = rest[0..close], .status = .failed, .message = "" };
    }
    var n: usize = 0;
    while (n < line.len and std.ascii.isDigit(line[n])) n += 1;
    if (n == 0 or n >= line.len or line[n] != '/') return null;
    var m = n + 1;
    while (m < line.len and std.ascii.isDigit(line[m])) m += 1;
    if (m == n + 1 or m >= line.len or line[m] != ' ') return null;
    const rest = line[m + 1 ..];
    const dots = std.mem.indexOf(u8, rest, "...") orelse return null;
    const name = rest[0..dots];
    const tail = std.mem.trim(u8, rest[dots + 3 ..], " ");
    if (name.len == 0) return null;
    if (std.mem.eql(u8, tail, "OK")) return .{ .name = name, .status = .passed, .message = "" };
    if (std.mem.eql(u8, tail, "SKIP")) return .{ .name = name, .status = .skipped, .message = "" };
    return .{ .name = name, .status = .failed, .message = tail };
}

/// `shapes.test.rect area` → suite `shapes`, title `rect area`; a
/// doctest is `shapes.decltest.Rect`; a bare name is all title.
fn splitZigName(name: []const u8) struct { suite: []const u8, title: []const u8 } {
    for ([_][]const u8{ ".test.", ".decltest." }) |sep| if (std.mem.indexOf(u8, name, sep)) |at| {
        return .{ .suite = name[0..at], .title = name[at + sep.len ..] };
    };
    for ([_][]const u8{ "test.", "decltest." }) |sep| if (std.mem.startsWith(u8, name, sep)) {
        return .{ .suite = "", .title = name[sep.len..] };
    };
    return .{ .suite = "", .title = name };
}

const ZigTally = struct { passed: usize, skipped: usize, failed: usize };

/// `3 passed; 0 skipped; 1 failed.`
fn zigTally(line: []const u8) ?ZigTally {
    var it = std.mem.splitSequence(u8, std.mem.trimEnd(u8, line, "."), "; ");
    var out: ZigTally = .{ .passed = 0, .skipped = 0, .failed = 0 };
    var seen: u8 = 0;
    while (it.next()) |part| {
        const sp = std.mem.indexOfScalar(u8, part, ' ') orelse return null;
        const n = std.fmt.parseInt(usize, part[0..sp], 10) catch return null;
        const word = part[sp + 1 ..];
        if (std.mem.eql(u8, word, "passed")) {
            out.passed = n;
            seen |= 1;
        } else if (std.mem.eql(u8, word, "skipped")) {
            out.skipped = n;
            seen |= 2;
        } else if (std.mem.eql(u8, word, "failed")) {
            out.failed = n;
            seen |= 4;
        } else return null;
    }
    return if (seen == 7) out else null;
}

/// The `N` of `N/M tests passed` in a `Build Summary:` line.
fn buildSummaryPassed(line: []const u8) ?usize {
    const at = std.mem.indexOf(u8, line, " tests passed") orelse return null;
    const head = line[0..at];
    const slash = std.mem.lastIndexOfScalar(u8, head, '/') orelse return null;
    var pos = slash;
    while (pos > 0 and std.ascii.isDigit(head[pos - 1])) pos -= 1;
    return std.fmt.parseInt(usize, head[pos..slash], 10) catch null;
}

/// `src/a.zig:3:5: error: expected ';'` — the compiler, not a test.
fn zigCompileError(line: []const u8) bool {
    const at = std.mem.indexOf(u8, line, ": error: ") orelse return false;
    const loc = line[0..at];
    // `<path>:<line>:<col>` — two numbers behind the last two colons.
    const c1 = std.mem.lastIndexOfScalar(u8, loc, ':') orelse return false;
    const c2 = std.mem.lastIndexOfScalar(u8, loc[0..c1], ':') orelse return false;
    _ = std.fmt.parseInt(u32, loc[c1 + 1 ..], 10) catch return false;
    _ = std.fmt.parseInt(u32, loc[c2 + 1 .. c1], 10) catch return false;
    return std.mem.endsWith(u8, loc[0..c2], ".zig");
}

const ZigFrame = struct { path: []const u8, line: u32, func: []const u8 };

/// `/ws/src/a.zig:67:5: 0x1024764db in test.deliberately failing (test)`.
fn zigFrame(line: []const u8) ?ZigFrame {
    const at = std.mem.indexOf(u8, line, ": 0x") orelse return null;
    const loc = line[0..at];
    const c1 = std.mem.lastIndexOfScalar(u8, loc, ':') orelse return null;
    const c2 = std.mem.lastIndexOfScalar(u8, loc[0..c1], ':') orelse return null;
    _ = std.fmt.parseInt(u32, loc[c1 + 1 ..], 10) catch return null;
    const ln = std.fmt.parseInt(u32, loc[c2 + 1 .. c1], 10) catch return null;
    const rest = line[at + 4 ..];
    const in_at = std.mem.indexOf(u8, rest, " in ") orelse return null;
    var func = rest[in_at + 4 ..];
    if (std.mem.lastIndexOf(u8, func, " (")) |p| func = func[0..p];
    return .{ .path = loc[0..c2], .line = ln, .func = func };
}

/// The 1-based line of `test "<title>"` in `text`.
fn zigTestLine(text: []const u8, title: []const u8) ?u32 {
    if (title.len == 0) return null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, "test \"")) |at| {
        from = at + 6;
        if (at > 0 and !(text[at - 1] == '\n' or text[at - 1] == ' ' or text[at - 1] == '\t')) continue;
        const rest = text[from..];
        if (!std.mem.startsWith(u8, rest, title)) continue;
        if (rest.len <= title.len or rest[title.len] != '"') continue;
        return @intCast(std.mem.count(u8, text[0..at], "\n") + 1);
    }
    return null;
}

/// The TRX the `trx` logger writes: every `<UnitTestResult>` with its
/// outcome and duration, the `<Message>` / `<StackTrace>` of a failure,
/// and the class + method from the `<UnitTest>` definitions (the
/// console's `testName` is the display name, which NUnit shortens). A
/// data row of a Theory / TestCase keeps its arguments from the display
/// name (`withArguments`), so three `[InlineData]` rows are three rows.
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
        const display = try attrValue(arena, opener, "testName");
        const defined = if (test_id) |id| by_id.get(id) else null;
        const name = if (defined) |fqn| try withArguments(arena, fqn, display) else display orelse "(test)";
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

/// `Class.Method` plus the arguments the display name gives the data
/// row: `Acme.Tests.CalcTests.Describes(x: 1, y: 5, expected: "p")` or
/// NUnit's `Describes(1,5,"p")` → `…CalcTests.Describes(x: 1, …)`. A
/// display name that does not call the method by name (a `DisplayName`)
/// adds nothing.
fn withArguments(arena: Allocator, fqn: []const u8, display: ?[]const u8) Allocator.Error![]const u8 {
    const d = display orelse return fqn;
    const paren = std.mem.indexOfScalar(u8, d, '(') orelse return fqn;
    const method = fqn[if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |dot| dot + 1 else 0..];
    const head = d[0..paren];
    if (!std.mem.endsWith(u8, head, method)) return fqn;
    if (head.len > method.len and head[head.len - method.len - 1] != '.') return fqn;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ fqn, d[paren..] });
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
/// Which sources a row without a file is looked for in: `.cs` by class
/// and method, `.zig` by its `test "…"` line.
pub const SourceLang = enum { cs, zig };

pub fn locateSources(arena: Allocator, io: Io, root: []const u8, workspace: []const u8, tests: []TestCase, lang: SourceLang) Allocator.Error!void {
    var pending: usize = 0;
    for (tests) |tc| pending += @intFromBool(tc.file.len == 0);
    if (pending == 0) return;
    var budget: usize = 3000;
    try locateIn(arena, io, root, workspace, tests, lang, &pending, &budget, 0);
}

const skip_dirs = [_][]const u8{ "bin", "obj", ".git", "node_modules", "TestResults", ".mnml", "zig-out", ".zig-cache", "zig-cache" };

fn locateIn(arena: Allocator, io: Io, dir: []const u8, workspace: []const u8, tests: []TestCase, lang: SourceLang, pending: *usize, budget: *usize, depth: u8) Allocator.Error!void {
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
            try locateIn(arena, io, sub, workspace, tests, lang, pending, budget, depth + 1);
            continue;
        }
        const ext: []const u8 = switch (lang) {
            .cs => ".cs",
            .zig => ".zig",
        };
        if (!std.ascii.endsWithIgnoreCase(entry.name, ext)) continue;
        budget.* -= 1;
        const path = try std.fs.path.join(arena, &.{ dir, entry.name });
        const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch continue;
        for (tests) |*tc| {
            if (tc.file.len > 0) continue;
            const found: ?u32 = switch (lang) {
                .cs => methodLine(text, classOf(tc.suite_path), methodOf(tc.title)),
                .zig => zigTestLine(text, tc.title),
            };
            if (found) |line| {
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

// ─── vitest: the Jest-shaped JSON report ────────────────────────────────

/// `vitest run --reporter=json --includeTaskLocation` (Jest's `--json`
/// is the same shape): `testResults[]` is one file (`name`, absolute),
/// its `assertionResults[]` one test each — `ancestorTitles` are the
/// describes, `status` passed / failed / pending / skipped / todo,
/// `duration` in ms, `location.line` the `it(` (with the flag), and a
/// failure's `failureMessages[0]` with its `at <file>:L:C` frames. A
/// file that failed with no tests (a syntax error, an import that is
/// not there) is one global error. The tally is composed as vitest's
/// own `Tests  1 failed | 3 passed (4)` line.
pub fn parseVitest(arena: Allocator, text: []const u8, workspace: []const u8, real: []const u8) ParseError!TestRun {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, std.mem.trim(u8, text, " \t\r\n"), .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotJson,
    };
    if (root != .object) return error.NotJson;
    const files = root.object.get("testResults") orelse return error.NotJson;
    if (files != .array) return error.NotJson;
    var tests: std.ArrayListUnmanaged(TestCase) = .empty;
    var errors: std.ArrayListUnmanaged([]const u8) = .empty;
    for (files.array.items) |f| {
        if (f != .object) continue;
        const abs = str(f.object.get("name")) orelse "";
        const file = try relativeToEither(arena, abs, workspace, real);
        const before = tests.items.len;
        if (f.object.get("assertionResults")) |cases| if (cases == .array) for (cases.array.items) |c| {
            if (c != .object) continue;
            const o = c.object;
            const st = str(o.get("status")) orelse "";
            const status: Status = if (std.mem.eql(u8, st, "passed")) .passed else if (std.mem.eql(u8, st, "failed")) .failed else .skipped;
            var suite: std.ArrayListUnmanaged(u8) = .empty;
            if (o.get("ancestorTitles")) |anc| if (anc == .array) for (anc.array.items) |a| {
                if (a != .string) continue;
                if (suite.items.len > 0) try suite.appendSlice(arena, " › ");
                try suite.appendSlice(arena, a.string);
            };
            var line: u32 = 0;
            if (o.get("location")) |loc| if (loc == .object) if (int(loc.object.get("line"))) |l| {
                line = @intCast(@min(l, std.math.maxInt(u32)));
            };
            var err: ?[]const u8 = null;
            if (o.get("failureMessages")) |fm| if (fm == .array and fm.array.items.len > 0 and fm.array.items[0] == .string) {
                const plain = try stripAnsi(arena, fm.array.items[0].string);
                if (line == 0) line = frameLineIn(plain, abs) orelse 0;
                const msg = messageLines(plain, 6);
                if (msg.len > 0) err = msg;
            };
            const dur: u64 = if (o.get("duration")) |d| switch (d) {
                .float => |v| if (v > 0) @intFromFloat(v) else 0,
                .integer => |v| if (v > 0) @intCast(v) else 0,
                else => 0,
            } else 0;
            try tests.append(arena, .{
                .title = str(o.get("title")) orelse str(o.get("fullName")) orelse "(test)",
                .suite_path = try suite.toOwnedSlice(arena),
                .file = file,
                .line = line,
                .status = status,
                .duration_ms = dur,
                .err = err,
                .trace_path = null,
            });
        };
        if (tests.items.len == before and std.mem.eql(u8, str(f.object.get("status")) orelse "", "failed")) {
            const m = firstLine(try stripAnsi(arena, str(f.object.get("message")) orelse ""));
            if (errors.items.len < 20) try errors.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ file, if (m.len > 0) m else "failed" }));
        }
    }
    const failed = int(root.object.get("numFailedTests")) orelse 0;
    const passed = int(root.object.get("numPassedTests")) orelse 0;
    const pending = int(root.object.get("numPendingTests")) orelse 0;
    const total = int(root.object.get("numTotalTests")) orelse 0;
    var summary: std.ArrayListUnmanaged(u8) = .empty;
    if (total > 0) {
        try summary.appendSlice(arena, "Tests  ");
        const parts = [_]struct { u64, []const u8 }{ .{ failed, "failed" }, .{ passed, "passed" }, .{ pending, "skipped" } };
        var n: usize = 0;
        for (parts) |part| {
            if (part[0] == 0) continue;
            if (n > 0) try summary.appendSlice(arena, " | ");
            try summary.print(arena, "{d} {s}", .{ part[0], part[1] });
            n += 1;
        }
        try summary.print(arena, " ({d})", .{total});
    }
    return .{ .tests = try tests.toOwnedSlice(arena), .global_errors = try errors.toOwnedSlice(arena), .summary = try summary.toOwnedSlice(arena) };
}

/// The lines of a failure message before its first `at …` frame, at
/// most `n`; the assertion, its expected / received, not the stack.
fn messageLines(s: []const u8, n: usize) []const u8 {
    var end: usize = 0;
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| : (lines += 1) {
        if (lines == n) break;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, l, " \t"), "at ")) break;
        end = @intFromPtr(l.ptr) - @intFromPtr(s.ptr) + l.len;
    }
    return std.mem.trimEnd(u8, s[0..end], " \t\r\n");
}

/// The line of the first `<abs>:L:C` in a stack — the frame inside the
/// test's own file — else null.
fn frameLineIn(text: []const u8, abs: []const u8) ?u32 {
    if (abs.len == 0) return null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, abs)) |at| {
        from = at + abs.len;
        if (from >= text.len or text[from] != ':') continue;
        var end = from + 1;
        while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
        if (end == from + 1) continue;
        return std.fmt.parseInt(u32, text[from + 1 .. end], 10) catch continue;
    }
    return null;
}

/// `-t '^(a|b)$'` and the failing files, for a re-run of a vitest run's
/// failures: the full names (the describes and the title, space-joined,
/// what vitest matches `-t` against) as one anchored regex, its
/// metacharacters escaped. Null when nothing failed.
pub fn vitestFailedArgs(arena: Allocator, tr: TestRun) Allocator.Error!?[]const []const u8 {
    var re: std.ArrayListUnmanaged(u8) = .empty;
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var n: usize = 0;
    for (tr.tests) |tc| {
        if (tc.status != .failed) continue;
        try re.appendSlice(arena, if (n == 0) "^(" else "|");
        var parts = std.mem.splitSequence(u8, tc.suite_path, " › ");
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            try regexEscape(arena, &re, part);
            try re.append(arena, ' ');
        }
        try regexEscape(arena, &re, tc.title);
        n += 1;
        var seen = false;
        for (files.items) |f| seen = seen or std.mem.eql(u8, f, tc.file);
        if (!seen and tc.file.len > 0) try files.append(arena, tc.file);
    }
    if (n == 0) return null;
    try re.appendSlice(arena, ")$");
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    try out.append(arena, "-t");
    try out.append(arena, try re.toOwnedSlice(arena));
    try out.appendSlice(arena, files.items);
    return try out.toOwnedSlice(arena);
}

fn regexEscape(arena: Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) Allocator.Error!void {
    for (s) |c| {
        if (std.mem.indexOfScalar(u8, "\\^$.|?*+()[]{}/", c) != null) try out.append(arena, '\\');
        try out.append(arena, c);
    }
}

// ─── pytest: the JUnit file, the -rA lines ──────────────────────────────

/// Where pytest writes its report, relative to the run's cwd.
pub const pytest_junit = ".mnml/pytest-junit.xml";

/// pytest's `--junitxml` (with `junit_family=xunit1`, which carries
/// `file` and `line`): one `<testcase>` per test — `name` with its
/// parametrize id, `classname` the module and the class, `file` relative
/// to the run's cwd, `line` 0-based at the `def`, `time` in seconds —
/// with a `<failure>` / `<error>` (its `message`, and the traceback whose
/// last `<file>:<n>:` line inside the test's file is where it broke) or
/// a `<skipped>`. Paths are made workspace-relative.
pub fn parseJunit(arena: Allocator, xml: []const u8, cwd: []const u8, workspace: []const u8, real: []const u8) Allocator.Error!TestRun {
    var tests: std.ArrayListUnmanaged(TestCase) = .empty;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, xml, from, "<testcase ")) |at| {
        const open_end = std.mem.indexOfScalarPos(u8, xml, at, '>') orelse break;
        const opener = xml[at..open_end];
        const self_closing = opener.len > 0 and opener[opener.len - 1] == '/';
        const close = if (self_closing) open_end else (std.mem.indexOfPos(u8, xml, open_end, "</testcase>") orelse xml.len);
        from = close;
        const name = (try attrValue(arena, opener, "name")) orelse "(test)";
        const classname = (try attrValue(arena, opener, "classname")) orelse "";
        const file_attr = (try attrValue(arena, opener, "file")) orelse "";
        const file: []const u8 = if (file_attr.len == 0)
            try moduleFile(arena, classname)
        else if (std.fs.path.isAbsolute(file_attr))
            try relativeToEither(arena, file_attr, workspace, real)
        else
            try relativeTo(arena, try std.fs.path.join(arena, &.{ cwd, file_attr }), workspace);
        var line: u32 = if (try attrValue(arena, opener, "line")) |l| (std.fmt.parseInt(u32, l, 10) catch 0) +| 1 else 0;
        const secs = std.fmt.parseFloat(f64, (try attrValue(arena, opener, "time")) orelse "0") catch 0;
        var status: Status = .passed;
        var err: ?[]const u8 = null;
        const body = xml[open_end..close];
        const fail_at = std.mem.indexOf(u8, body, "<failure") orelse std.mem.indexOf(u8, body, "<error");
        if (fail_at) |fa| {
            status = .failed;
            const tag_end = std.mem.indexOfScalarPos(u8, body, fa, '>') orelse body.len;
            const tag = body[fa..tag_end];
            const text_end = std.mem.indexOfPos(u8, body, tag_end, "</") orelse body.len;
            const text = if (tag_end < text_end) try xmlUnescape(arena, body[tag_end + 1 .. text_end]) else "";
            const msg = (try attrValue(arena, tag, "message")) orelse firstLine(std.mem.trim(u8, text, " \t\r\n"));
            if (msg.len > 0) err = firstLines(msg, 6);
            if (junitFrameLine(text, file_attr)) |l| line = l;
        } else if (std.mem.indexOf(u8, body, "<skipped") != null) {
            status = .skipped;
        }
        try tests.append(arena, .{
            .title = name,
            .suite_path = junitSuite(classname, file_attr),
            .file = file,
            .line = line,
            .status = status,
            .duration_ms = if (secs > 0) @intFromFloat(secs * 1000.0) else 0,
            .err = err,
            .trace_path = null,
        });
    }
    return .{ .tests = try tests.toOwnedSlice(arena) };
}

/// `tests.test_models` → `tests/test_models.py`, for a report without
/// `file` (xunit2 — never asked for, but a config may insist).
fn moduleFile(arena: Allocator, classname: []const u8) Allocator.Error![]const u8 {
    if (classname.len == 0) return "";
    const out = try arena.alloc(u8, classname.len + 3);
    for (classname, 0..) |c, i| out[i] = if (c == '.') '/' else c;
    @memcpy(out[classname.len..], ".py");
    return out;
}

/// The class part of `classname` past the module the file names:
/// `tests.test_models.TestShelf` with `tests/test_models.py` → `TestShelf`;
/// the bare module → nothing.
fn junitSuite(classname: []const u8, file_attr: []const u8) []const u8 {
    if (file_attr.len == 0) return classname;
    const stem = file_attr[0 .. std.mem.lastIndexOfScalar(u8, file_attr, '.') orelse file_attr.len];
    // The module's dotted path is the file's with `/` → `.`; compare char by char.
    if (classname.len < stem.len) return classname;
    for (stem, 0..) |c, i| {
        const want: u8 = if (c == '/' or c == '\\') '.' else c;
        if (classname[i] != want) return classname;
    }
    if (classname.len == stem.len) return "";
    if (classname[stem.len] != '.') return classname;
    return classname[stem.len + 1 ..];
}

/// The line of the last `<file>:<n>:` in a traceback that names the
/// test's own file — pytest prints the test's frame with its assertion
/// and the source lines it called into after it.
fn junitFrameLine(text: []const u8, file_attr: []const u8) ?u32 {
    if (file_attr.len == 0) return null;
    var found: ?u32 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, l, file_attr)) continue;
        const rest = l[file_attr.len..];
        if (rest.len < 2 or rest[0] != ':') continue;
        var end: usize = 1;
        while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
        if (end == 1 or end >= rest.len or rest[end] != ':') continue;
        found = std.fmt.parseInt(u32, rest[1..end], 10) catch continue;
    }
    return found;
}

/// The `-rA` short summary — `PASSED tests/x.py::name[id]`, `FAILED
/// tests/x.py::name - message`, `ERROR …`, `SKIPPED [1] tests/x.py:20:
/// reason` — for a run whose JUnit file did not land.
pub fn parsePytestConsole(arena: Allocator, text: []const u8, workspace: []const u8) Allocator.Error!TestRun {
    _ = workspace;
    var tests: std.ArrayListUnmanaged(TestCase) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, try stripAnsi(arena, raw), " \t\r");
        const heads = [_]struct { []const u8, Status }{ .{ "PASSED ", .passed }, .{ "FAILED ", .failed }, .{ "ERROR ", .failed }, .{ "XFAIL ", .skipped }, .{ "XPASS ", .passed } };
        var matched = false;
        for (heads) |h| if (std.mem.startsWith(u8, l, h[0])) {
            matched = true;
            const rest = l[h[0].len..];
            const dash = std.mem.indexOf(u8, rest, " - ");
            const nodeid = std.mem.trim(u8, rest[0 .. dash orelse rest.len], " ");
            const err: ?[]const u8 = if (dash) |d| std.mem.trim(u8, rest[d + 3 ..], " ") else null;
            const sep = std.mem.indexOf(u8, nodeid, "::") orelse nodeid.len;
            const file = nodeid[0..sep];
            const tail = if (sep < nodeid.len) nodeid[sep + 2 ..] else "";
            const last = if (std.mem.lastIndexOf(u8, tail, "::")) |i| i else null;
            var suite: []const u8 = "";
            if (last) |i| {
                const s = try arena.dupe(u8, tail[0..i]);
                std.mem.replaceScalar(u8, s, ':', '.');
                var out: std.ArrayListUnmanaged(u8) = .empty;
                var parts = std.mem.tokenizeScalar(u8, s, '.');
                while (parts.next()) |part| {
                    if (out.items.len > 0) try out.append(arena, '.');
                    try out.appendSlice(arena, part);
                }
                suite = try out.toOwnedSlice(arena);
            }
            try tests.append(arena, .{
                .title = if (last) |i| tail[i + 2 ..] else tail,
                .suite_path = suite,
                .file = file,
                .line = 0,
                .status = h[1],
                .duration_ms = 0,
                .err = if (err) |e| (if (e.len > 0) e else null) else null,
                .trace_path = null,
            });
            break;
        };
        if (matched) continue;
        if (std.mem.startsWith(u8, l, "SKIPPED ")) {
            var rest = l["SKIPPED ".len..];
            if (std.mem.startsWith(u8, rest, "[")) rest = rest[(std.mem.indexOfScalar(u8, rest, ']') orelse 0) + 1 ..];
            rest = std.mem.trimStart(u8, rest, " ");
            // `tests/x.py:20: reason`
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
            const file = rest[0..colon];
            var line: u32 = 0;
            var reason: []const u8 = "";
            if (colon < rest.len) {
                const after = rest[colon + 1 ..];
                var end: usize = 0;
                while (end < after.len and std.ascii.isDigit(after[end])) end += 1;
                line = std.fmt.parseInt(u32, after[0..end], 10) catch 0;
                reason = std.mem.trim(u8, if (end < after.len) after[end + 1 ..] else "", " ");
            }
            try tests.append(arena, .{ .title = if (reason.len > 0) reason else "(skipped)", .suite_path = "", .file = file, .line = line, .status = .skipped, .duration_ms = 0, .err = null, .trace_path = null });
        }
    }
    return .{ .tests = try tests.toOwnedSlice(arena) };
}

/// pytest's last line — `1 failed, 13 passed, 1 skipped in 0.04s`,
/// `no tests ran in 0.01s` — without the `=` rule around it.
pub fn pytestSummary(text: []const u8) []const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " =\t\r");
        if (l.len == 0) continue;
        const words = [_][]const u8{ " passed", " failed", " skipped", " error", "no tests ran", " xfailed", " xpassed", " deselected" };
        var hit = false;
        for (words) |w| hit = hit or std.mem.indexOf(u8, l, w) != null;
        if (hit and std.mem.indexOf(u8, l, " in ") != null and l[l.len - 1] == 's') return l;
    }
    return "";
}

/// The node ids of a run's failures — `tests/x.py::Class::name[id]` —
/// for a re-run of exactly those. Null when nothing failed.
pub fn pytestFailedArgs(arena: Allocator, tr: TestRun) Allocator.Error!?[]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (tr.tests) |tc| {
        if (tc.status != .failed or tc.file.len == 0) continue;
        var id: std.ArrayListUnmanaged(u8) = .empty;
        try id.appendSlice(arena, tc.file);
        var parts = std.mem.tokenizeScalar(u8, tc.suite_path, '.');
        while (parts.next()) |part| {
            try id.appendSlice(arena, "::");
            try id.appendSlice(arena, part);
        }
        try id.appendSlice(arena, "::");
        try id.appendSlice(arena, tc.title);
        try out.append(arena, try id.toOwnedSlice(arena));
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
/// The verb is the pane's argument: `build test` or `test <file>`.
pub const zig_argv = [_][]const u8{"zig"};
/// `--includeTaskLocation` puts each `it(`'s line in the report, so a
/// passed row jumps too; `run` keeps vitest from watching.
pub const vitest_argv = [_][]const u8{ "npx", "vitest", "run", "--reporter=json", "--includeTaskLocation" };
/// `-rA` lists every test's outcome for the console fallback; the JUnit
/// file (xunit1: with `file` and `line`) is the report. `-q` keeps the
/// progress dots off the error text.
pub const pytest_argv = [_][]const u8{ "pytest", "-q", "-rA", "-o", "junit_family=xunit1", "--junitxml=" ++ pytest_junit };

fn baseArgv(runner: Runner) []const []const u8 {
    return switch (runner) {
        .playwright => &base_argv,
        .dotnet => &dotnet_argv,
        .zig => &zig_argv,
        .vitest => &vitest_argv,
        .pytest => &pytest_argv,
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
                .zig => std.fmt.allocPrint(arena, "running `zig`: {s} — is Zig on PATH?", .{@errorName(err)}) catch null,
                .vitest => std.fmt.allocPrint(arena, "running `npx vitest run`: {s} — is Node on PATH?", .{@errorName(err)}) catch null,
                .pytest => std.fmt.allocPrint(arena, "running `pytest`: {s} — is pytest installed here?", .{@errorName(err)}) catch null,
            };
            events.post(io, .{ .tests = result });
            return;
        },
    };
    defer gpa.free(proc.stdout);
    defer gpa.free(proc.stderr);
    switch (runner) {
        .dotnet => {
            dotnetResult(io, arena, result, cwd, workspace, proc.stdout, proc.stderr, extra) catch {
                result.destroy(gpa);
                return;
            };
            events.post(io, .{ .tests = result });
            return;
        },
        .pytest => {
            pytestResult(io, arena, result, cwd, workspace, proc.stdout, proc.stderr, extra) catch {
                result.destroy(gpa);
                return;
            };
            events.post(io, .{ .tests = result });
            return;
        },
        .vitest => {
            vitestResult(io, arena, result, workspace, proc.stdout, proc.stderr, extra) catch {
                result.destroy(gpa);
                return;
            };
            events.post(io, .{ .tests = result });
            return;
        },
        .zig => {
            zigResult(io, arena, result, cwd, workspace, proc.stdout, proc.stderr, extra) catch {
                result.destroy(gpa);
                return;
            };
            events.post(io, .{ .tests = result });
            return;
        },
        .playwright => {},
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
    try realRelative(arena, io, workspace, tests);
    try locateSources(arena, io, cwd, workspace, tests, .cs);
    r.tests = tests;
    r.command = try cmdlineFor(arena, .dotnet, extra);
    result.run = r;
}

/// `zig` writes its test report on stderr; stdout (a `zig build`'s own
/// prints) is read behind it. No rows, no compile error and no tally is
/// the tool's own words, four lines.
fn zigResult(io: Io, arena: Allocator, result: *Result, cwd: []const u8, workspace: []const u8, stdout: []const u8, stderr: []const u8, extra: []const []const u8) Allocator.Error!void {
    const text = try std.mem.concat(arena, u8, &.{ stderr, "\n", stdout });
    var r = try parseZig(arena, text, workspace);
    if (r.tests.len == 0 and r.global_errors.len == 0 and r.summary.len == 0) {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        const msg: []const u8 = if (trimmed.len == 0) "zig printed no test results" else trimmed;
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
    // `zig` prints a frame's path as the shell saw it — the cwd's
    // REAL path (`/private/var/…` for a workspace named `/var/…` on
    // macOS) — so a frame under the resolved workspace is made
    // relative too, or the row's header is an absolute path clipped to
    // nothing and Enter still opens it.
    if (std.Io.Dir.realPathFileAbsoluteAlloc(io, workspace, arena)) |real| {
        if (!std.mem.eql(u8, real, workspace)) for (tests) |*tc| {
            if (std.fs.path.isAbsolute(tc.file)) tc.file = try relativeTo(arena, tc.file, real);
        };
    } else |_| {}
    try locateSources(arena, io, cwd, workspace, tests, .zig);
    r.tests = tests;
    r.command = try cmdlineFor(arena, .zig, extra);
    result.run = r;
}

/// The report on stdout; anything else (vitest died before one — no
/// config, a bad flag) is the tool's own words, four lines.
fn vitestResult(io: Io, arena: Allocator, result: *Result, workspace: []const u8, stdout: []const u8, stderr: []const u8, extra: []const []const u8) Allocator.Error!void {
    if (parseVitest(arena, stdout, workspace, try realWorkspace(io, arena, workspace))) |parsed| {
        var r = parsed;
        r.command = try cmdlineFor(arena, .vitest, extra);
        result.run = r;
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotJson => result.err = try toolWords(arena, stdout, stderr, "vitest printed no JSON report"),
    }
}

/// The JUnit file under the run's cwd; the `-rA` lines when it is not
/// there (or holds no test); the console's tally either way. Nothing
/// at all is the tool's own words.
fn pytestResult(io: Io, arena: Allocator, result: *Result, cwd: []const u8, workspace: []const u8, stdout: []const u8, stderr: []const u8, extra: []const []const u8) Allocator.Error!void {
    var r: TestRun = .{};
    const junit = try std.fs.path.join(arena, &.{ cwd, pytest_junit });
    if (Io.Dir.cwd().readFileAlloc(io, junit, arena, .limited(32 << 20))) |xml| {
        r = try parseJunit(arena, xml, cwd, workspace, try realWorkspace(io, arena, workspace));
    } else |_| {}
    if (r.tests.len == 0) r = try parsePytestConsole(arena, stdout, workspace);
    r.summary = try arena.dupe(u8, pytestSummary(try stripAnsi(arena, stdout)));
    if (r.tests.len == 0) {
        result.err = try toolWords(arena, stdout, stderr, "pytest printed no test results");
        return;
    }
    r.command = try cmdlineFor(arena, .pytest, extra);
    result.run = r;
}

/// The tool's stderr (else stdout), ANSI stripped, four lines; `none`
/// when it said nothing.
fn toolWords(arena: Allocator, stdout: []const u8, stderr: []const u8, none: []const u8) Allocator.Error![]const u8 {
    const text = std.mem.trim(u8, if (stderr.len > 0) stderr else stdout, " \t\r\n");
    const msg: []const u8 = if (text.len == 0) none else text;
    var lines = std.mem.splitScalar(u8, msg, '\n');
    var kept: std.ArrayListUnmanaged(u8) = .empty;
    var n: usize = 0;
    while (lines.next()) |l| : (n += 1) {
        if (n == 4) break;
        if (n > 0) try kept.append(arena, '\n');
        try kept.appendSlice(arena, try stripAnsi(arena, l));
    }
    return kept.items;
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

    /// The order the rows follow: by file, then line (then title, then
    /// the report's order) — a test host reports in the order tests
    /// finish, which is not the same twice — or slowest first. A row
    /// no file was found for goes last.
    pub fn order(self: *const TestsPane, arena: Allocator) Allocator.Error![]u32 {
        const idx = try arena.alloc(u32, self.run.tests.len);
        for (idx, 0..) |*x, i| x.* = @intCast(i);
        if (self.sort == .file_line) {
            const Ctx = struct {
                tests: []const TestCase,
                fn lt(ctx: @This(), a: u32, b: u32) bool {
                    const x = ctx.tests[a];
                    const y = ctx.tests[b];
                    if ((x.file.len == 0) != (y.file.len == 0)) return y.file.len == 0;
                    switch (std.mem.order(u8, x.file, y.file)) {
                        .lt => return true,
                        .gt => return false,
                        .eq => {},
                    }
                    if (x.line != y.line) return x.line < y.line;
                    switch (std.mem.order(u8, x.title, y.title)) {
                        .lt => return true,
                        .gt => return false,
                        .eq => {},
                    }
                    return a < b;
                }
            };
            std.mem.sort(u32, idx, Ctx{ .tests = self.run.tests }, Ctx.lt);
        }
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
    // The project's own venv pytest wins over the one on PATH.
    if (p.runner == .pytest) if (pytestVenvBin(app, root)) |venv| {
        const path = try std.fmt.allocPrint(app.frame.allocator(), "{s}{c}{s}", .{ venv, std.fs.path.delimiter, env.get("PATH") orelse "" });
        try env.put("PATH", path);
    };
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
    // The runner and what was asked of it — the full command line is
    // the pane's first row; the list has a row's width.
    const label = if (p.last_args.len == 0) p.runner.label() else try std.fmt.allocPrint(app.frame.allocator(), "{s} {s}", .{ p.runner.label(), try std.mem.join(app.frame.allocator(), " ", p.last_args) });
    p.group.concurrent(app.io, worker, .{ &app.events, app.io, gpa, p.runner, cwd, workspace, env, extra, p.generation, id }) catch |err| {
        p.state = .failed;
        p.err = "could not start the worker";
        jobs.record(app, .{ .kind = .test_run, .label = label, .pane = id }, 0, jobs.Outcome.fail("could not start the worker"));
        return app.diag.fail(app.frame.allocator(), "{s}: could not start the worker: {s}", .{ p.runner.label(), @errorName(err) });
    };
    // A re-run supersedes the run before it (same pane, same key).
    _ = try jobs.begin(app, .{ .kind = .test_run, .key = id, .label = label, .pane = id, .cancel = &cancelRun });
}

/// The JOBS list's Cancel: stop the worker (its child with it), and
/// drop whatever it had already posted by moving the generation on.
fn cancelRun(app: *App, key: u64) void {
    const id: PaneId = @intCast(key);
    const pane = app.panes.get(id) orelse return jobs.endKeyed(app, .test_run, key, jobs.Outcome.cancel(null));
    const p = switch (pane.*) {
        .tests => |*p| p,
        else => return,
    };
    p.generation +%= 1;
    p.group.cancel(app.io);
    p.state = .failed;
    p.err = "cancelled";
    jobs.endKeyed(app, .test_run, key, jobs.Outcome.cancel(null));
    app.needs_render = true;
}

/// How a finished run reads in the JOBS list. A run that ran nothing
/// is a failure: it looked like a pass, and it was not one.
fn runOutcome(arena: Allocator, tr: TestRun) Allocator.Error!jobs.Outcome {
    const f = tr.count(.failed);
    const ok = tr.passed();
    if (f > 0) return jobs.Outcome.fail(try std.fmt.allocPrint(arena, "{d} failed, {d} passed", .{ f, ok }));
    if (tr.tests.len == 0) return jobs.Outcome.fail("no tests ran");
    return jobs.Outcome.done(try std.fmt.allocPrint(arena, "{d} passed", .{ok}));
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
        const ok = p.run.passed();
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
        jobs.endKeyed(app, .test_run, result.pane, try runOutcome(app.frame.allocator(), p.run));
    } else {
        p.state = .failed;
        p.run = .{};
        p.err = try a.dupe(u8, result.err orelse "the run failed");
        jobs.endKeyed(app, .test_run, result.pane, jobs.Outcome.fail(p.err));
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
    return .{ .command = try a.dupe(u8, src.command), .tests = tests, .global_errors = errs, .summary = try a.dupe(u8, src.summary), .passed_unlisted = src.passed_unlisted };
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
        .zig => zigAll(app),
        .vitest => vitestAll(app),
        .pytest => pytestAll(app),
    };
}

fn runFileFor(app: *App, runner: Runner) CommandError!void {
    return switch (runner) {
        .playwright => runFile(app),
        .dotnet => dotnetFile(app),
        .zig => zigFile(app),
        .vitest => vitestFile(app),
        .pytest => pytestFile(app),
    };
}

fn rerunFailedFor(app: *App, runner: Runner) CommandError!void {
    return switch (runner) {
        .playwright => rerunFailed(app),
        .dotnet => dotnetRerunFailed(app),
        .zig => zigRerunFailed(app),
        .vitest => vitestRerunFailed(app),
        .pytest => pytestRerunFailed(app),
    };
}

// ─── vitest, the commands ───────────────────────────────────────────────

/// The nearest package.json at or above the active file names vitest —
/// in its dependencies, or as the first word of its `test` script — and
/// the tests pane runs it in place of `npm test`'s pty. Null otherwise,
/// and `test.*` keep the pty.
pub fn vitestProject(app: *App) ?[]const u8 {
    const arena = app.frame.allocator();
    const dir = runners.findManifestDir(app.io, runners.startDir(app), &.{"package.json"}, app.workspace) orelse return null;
    const path = std.fs.path.join(arena, &.{ dir, "package.json" }) catch return null;
    const src = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(4 << 20)) catch return null;
    return if (packageNamesVitest(arena, src)) dir else null;
}

/// `vitest` under `devDependencies` / `dependencies`, or a `scripts.test`
/// that starts with it.
pub fn packageNamesVitest(arena: Allocator, src: []const u8) bool {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, src, .{}) catch return false;
    if (parsed != .object) return false;
    for ([_][]const u8{ "devDependencies", "dependencies" }) |key| if (parsed.object.get(key)) |deps| if (deps == .object and deps.object.get("vitest") != null) return true;
    if (parsed.object.get("scripts")) |scripts| if (scripts == .object) if (scripts.object.get("test")) |t_| if (t_ == .string) {
        const cmd = std.mem.trimStart(u8, t_.string, " ");
        if (std.mem.startsWith(u8, cmd, "vitest") and (cmd.len == "vitest".len or cmd["vitest".len] == ' ')) return true;
    };
    return false;
}

fn vitestRoot(app: *App) CommandError![]const u8 {
    return vitestProject(app) orelse app.diag.fail(app.frame.allocator(), "vitest: no package.json naming vitest in {s} or any parent", .{app.workspace});
}

/// `test.run_all` on a vitest project: `npx vitest run` in the pane.
pub fn vitestAll(app: *App) CommandError!void {
    _ = try openRun(app, .vitest, try vitestRoot(app), &.{});
}

/// `test.run_file`: the active file as vitest's filter.
pub fn vitestFile(app: *App) CommandError!void {
    const rel = try activeTestRel(app, "test");
    _ = try openRun(app, .vitest, try vitestRoot(app), &.{rel});
}

/// `test.run_at_cursor`: the file and `-t <name>` (the title from
/// `runners.testNameAt`; `-t` is a substring match on the full name).
pub fn vitestAtCursor(app: *App, rel: []const u8, name: []const u8) CommandError!void {
    _ = try openRun(app, .vitest, try vitestRoot(app), &.{ rel, "-t", name });
}

/// `test.rerun_failed` / `R`: the last run's failures by full name and
/// file (`vitestFailedArgs`) — never the whole suite again.
pub fn vitestRerunFailed(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const id = find(app) orelse return app.diag.fail(arena, "no vitest run to re-run yet — run the suite first", .{});
    const p = &app.panes.get(id).?.tests;
    if (p.runner != .vitest or p.state != .done) return app.diag.fail(arena, "no vitest run to re-run yet — run the suite first", .{});
    const args = (try vitestFailedArgs(arena, p.run)) orelse return app.diag.fail(arena, "no failed test to re-run", .{});
    const root = try arena.dupe(u8, p.cwd orelse app.workspace);
    _ = try openRun(app, .vitest, root, args);
}

/// The active file, workspace-relative; `what` names the kind of file
/// the toast asks for.
fn activeTestRel(app: *App, what: []const u8) CommandError![]const u8 {
    const e = app.activeEditor() orelse return app.diag.fail(app.frame.allocator(), "open a {s} file first", .{what});
    const path = e.buf.doc.path orelse return app.diag.fail(app.frame.allocator(), "open a saved {s} file first", .{what});
    return app.relPath(path);
}

// ─── pytest, the commands ───────────────────────────────────────────────

/// `<root>/.venv/bin` (or `venv`, or the Windows `Scripts`) when it holds
/// a pytest: put first on the worker's PATH.
fn pytestVenvBin(app: *App, root: []const u8) ?[]const u8 {
    const arena = app.frame.allocator();
    const dirs = [_][]const u8{ ".venv/bin", ".venv/Scripts", "venv/bin", "venv/Scripts" };
    for (dirs) |d| {
        const dir = std.fs.path.join(arena, &.{ root, d }) catch return null;
        for ([_][]const u8{ "pytest", "pytest.exe" }) |bin| {
            const full = std.fs.path.join(arena, &.{ dir, bin }) catch return null;
            _ = Io.Dir.cwd().statFile(app.io, full, .{}) catch continue;
            return dir;
        }
    }
    return null;
}

/// `pytest.run` / `test.run_all` on a Python project: the whole suite.
pub fn pytestAll(app: *App) CommandError!void {
    _ = try openRun(app, .pytest, try runners.pytestRoot(app), &.{});
}

/// `test.run_file`: the active file.
pub fn pytestFile(app: *App) CommandError!void {
    const rel = try activeTestRel(app, "test");
    _ = try openRun(app, .pytest, try runners.pytestRoot(app), &.{rel});
}

/// `test.run_at_cursor`: the file and `-k <name>`.
pub fn pytestAtCursor(app: *App, rel: []const u8, name: []const u8) CommandError!void {
    _ = try openRun(app, .pytest, try runners.pytestRoot(app), &.{ rel, "-k", name });
}

/// `pytest.failed` / `test.rerun_failed` / `R`: the last run's failures
/// by node id (`pytestFailedArgs`); before any run in this pane,
/// pytest's own `--lf` (its cache remembers the last session's).
pub fn pytestRerunFailed(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const pane: ?*TestsPane = if (find(app)) |id| &app.panes.get(id).?.tests else null;
    if (pane) |p| if (p.runner == .pytest and p.state == .done) {
        const args = (try pytestFailedArgs(arena, p.run)) orelse return app.diag.fail(arena, "no failed test to re-run", .{});
        const root = try arena.dupe(u8, p.cwd orelse app.workspace);
        _ = try openRun(app, .pytest, root, args);
        return;
    };
    _ = try openRun(app, .pytest, try runners.pytestRoot(app), &.{"--lf"});
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

// ─── zig test, the commands ─────────────────────────────────────────────

/// `zig <extra>` at `root` in the one tests pane.
pub fn runZig(app: *App, root: []const u8, extra: []const []const u8) CommandError!PaneId {
    return openRun(app, .zig, root, extra);
}

/// The nearest `build.zig` at or above the file, and `zig` on PATH.
fn zigRoot(app: *App) CommandError![]const u8 {
    const arena = app.frame.allocator();
    const root = runners.findManifestDir(app.io, runners.startDir(app), &.{"build.zig"}, app.workspace) orelse
        return app.diag.fail(arena, "zig.test: no build.zig found in {s} or any parent", .{app.workspace});
    if (!runners.onPath(app, "zig")) {
        try runners.offerInstall(app, "zig");
        return error.Failed;
    }
    return root;
}

/// The active `.zig` file, relative to `root` (the run's cwd).
fn zigFileRel(app: *App, root: []const u8) CommandError![]const u8 {
    const arena = app.frame.allocator();
    const e = app.activeEditor() orelse return app.diag.fail(arena, "open a .zig test file first", .{});
    const path = e.buf.doc.path orelse return app.diag.fail(arena, "open a saved .zig test file first", .{});
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".zig")) return app.diag.fail(arena, "{s} is not a .zig file", .{app.relPath(path)});
    return relativeTo(arena, path, root);
}

/// Does `<root>/build.zig` declare a `test-filter` option (as this
/// repo's does, `b.option([]const u8, "test-filter", …)`)? Then
/// `zig build test -Dtest-filter=<name>` runs one test through the
/// project's own module wiring; without it a single file is tested
/// directly.
pub fn buildExposesTestFilter(io: Io, arena: Allocator, root: []const u8) bool {
    const path = std.fs.path.join(arena, &.{ root, "build.zig" }) catch return false;
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return false;
    return std.mem.indexOf(u8, text, "\"test-filter\"") != null;
}

/// `test.run_all` on a Zig project: `zig build test`.
pub fn zigAll(app: *App) CommandError!void {
    const root = try zigRoot(app);
    _ = try runZig(app, root, &.{ "build", "test" });
}

/// `test.run_file`: `zig test <file>`, every test the file declares.
pub fn zigFile(app: *App) CommandError!void {
    const root = try zigRoot(app);
    const rel = try zigFileRel(app, root);
    _ = try runZig(app, root, &.{ "test", rel });
}

/// `test.run_at_cursor`: the `test "…"` above the cursor, through the
/// build's filter when it has one, else the file's.
pub fn zigAtCursor(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const root = try zigRoot(app);
    const rel = try zigFileRel(app, root);
    const e = app.activeEditor().?;
    const name = runners.testNameAt(e.buf.editor.bytes(), e.buf.editor.cursor) orelse
        return app.diag.fail(arena, "no test above the cursor", .{});
    if (buildExposesTestFilter(app.io, arena, root)) {
        _ = try runZig(app, root, &.{ "build", "test", try std.fmt.allocPrint(arena, "-Dtest-filter={s}", .{name}) });
    } else {
        _ = try runZig(app, root, &.{ "test", rel, "--test-filter", name });
    }
}

/// `test.rerun_failed` / `R`: the last Zig run again — `zig` keeps no
/// "last failed" of its own and a build's filter takes one name.
pub fn zigRerunFailed(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const id = find(app) orelse return app.diag.fail(arena, "no Zig test run to re-run yet", .{});
    const p = &app.panes.get(id).?.tests;
    if (p.runner != .zig or p.state == .running) return app.diag.fail(arena, "no Zig test run to re-run yet", .{});
    try start(app, id, p);
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
    const tool = at.p.runner.healTool();
    const fence = at.p.runner.fence();
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
    // global error, cart header, 1 case, login header, 3 cases (+2
    // error lines +1 trace): by file, then line — not the report's order.
    try t.expectEqual(@as(usize, 10), p.rows.len);
    try t.expect(p.rows[0] == .global_err);
    try t.expectEqualStrings("cart.spec.ts", p.rows[1].file);
    try t.expect(p.rows[2] == .case and p.rows[2].case == 3);
    try t.expectEqualStrings("login.spec.ts", p.rows[3].file);
    try t.expect(p.rows[4] == .case and p.rows[4].case == 0);
    try t.expect(p.rows[5] == .case and p.rows[5].case == 1);
    try t.expect(p.rows[6] == .err_line and p.rows[7] == .err_line);
    try t.expect(p.rows[8] == .trace and p.rows[8].trace == 1);
    try t.expectEqual(@as(usize, 2), p.cursor);
    p.cursor = 8;
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

test "file:line sorts a test host's finishing order: one header per file, lines ascending, the same rows whatever the order they finished in" {
    const Case = struct {
        fn of(title: []const u8, file: []const u8, line: u32) TestCase {
            return .{ .title = title, .suite_path = "Acme.Tests.CalcTests", .file = file, .line = line, .status = .passed, .duration_ms = 0, .err = null, .trace_path = null };
        }
    };
    const calc = "tests/Acme.Tests/CalcTests.cs";
    const desc = "tests/Acme.Tests/Sub/DescribeTests.cs";
    // Two runs of one solution, as xunit reported them.
    const runs = [_][7]TestCase{
        .{ Case.of("Later", calc, 18), Case.of("Adds", calc, 9), Case.of("Nothing", desc, 5), Case.of("Describes(x: 2)", calc, 26), Case.of("DividesWrong", calc, 12), Case.of("Positive", desc, 9), Case.of("Unfound", "", 0) },
        .{ Case.of("Unfound", "", 0), Case.of("Positive", desc, 9), Case.of("DividesWrong", calc, 12), Case.of("Describes(x: 2)", calc, 26), Case.of("Adds", calc, 9), Case.of("Nothing", desc, 5), Case.of("Later", calc, 18) },
    };
    var seen: [2][]const u8 = undefined;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    for (runs, 0..) |cases, n| {
        var p = try TestsPane.init(t.allocator);
        defer p.deinit(t.allocator, t.io);
        p.run = .{ .tests = &cases };
        try p.rebuildRows();
        var text: std.ArrayListUnmanaged(u8) = .empty;
        for (p.rows) |r| switch (r) {
            .file => |f| try text.print(arena_state.allocator(), "[{s}]", .{f}),
            .case => |c| try text.print(arena_state.allocator(), " {s}:{d}", .{ p.run.tests[c].title, p.run.tests[c].line }),
            else => {},
        };
        seen[n] = text.items;
    }
    try t.expectEqualStrings("[tests/Acme.Tests/CalcTests.cs] Adds:9 DividesWrong:12 Later:18 Describes(x: 2):26[tests/Acme.Tests/Sub/DescribeTests.cs] Nothing:5 Positive:9[] Unfound:0", seen[0]);
    try t.expectEqualStrings(seen[0], seen[1]);
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
    \\    <UnitTestResult executionId="e4" testId="t4" testName="Acme.Tests.CalcTests.Describes(x: 2, y: 2, expected: &quot;diagonal 2&quot;)" computerName="box" duration="00:00:00.0000603" outcome="Passed" testType="13cdc9d9" testListId="8c84fa94" relativeResultsDirectory="e4" />
    \\    <UnitTestResult executionId="e5" testId="t5" testName="Acme.Tests.CalcTests.Describes(x: 1, y: 5, expected: &quot;point 1,5&quot;)" computerName="box" duration="00:00:00.0000177" outcome="Passed" testType="13cdc9d9" testListId="8c84fa94" relativeResultsDirectory="e5" />
    \\    <UnitTestResult executionId="e6" testId="t6" testName="adds two numbers" computerName="box" duration="00:00:00.0000177" outcome="Passed" testType="13cdc9d9" testListId="8c84fa94" relativeResultsDirectory="e6" />
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
    \\    <UnitTest name="Acme.Tests.CalcTests.Describes(x: 2, y: 2, expected: &quot;diagonal 2&quot;)" storage="/ws/tests.dll" id="t4">
    \\      <TestMethod codeBase="/ws/tests.dll" adapterTypeName="executor://xunit" className="Acme.Tests.CalcTests" name="Describes" />
    \\    </UnitTest>
    \\    <UnitTest name="Acme.Tests.CalcTests.Describes(x: 1, y: 5, expected: &quot;point 1,5&quot;)" storage="/ws/tests.dll" id="t5">
    \\      <TestMethod codeBase="/ws/tests.dll" adapterTypeName="executor://xunit" className="Acme.Tests.CalcTests" name="Describes" />
    \\    </UnitTest>
    \\    <UnitTest name="adds two numbers" storage="/ws/tests.dll" id="t6">
    \\      <TestMethod codeBase="/ws/tests.dll" adapterTypeName="executor://xunit" className="Acme.Tests.CalcTests" name="AddsNamed" />
    \\    </UnitTest>
    \\  </TestDefinitions>
    \\</TestRun>
;

const fixture_zig_test =
    \\1/4 shapes.test.rect area...OK
    \\2/4 shapes.test.stack push pop...OK
    \\3/4 shapes.test.deliberately failing...expected 5, found 4
    \\FAIL (TestExpectedEqual)
    \\/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/testing.zig:118:17: 0x104e49fab in expectEqualInner__anon_36368 (test)
    \\                return error.TestExpectedEqual;
    \\                ^
    \\/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/testing.zig:83:5: 0x104e4a04f in expectEqual (test)
    \\    return expectEqualInner(T, expected, actual);
    \\    ^
    \\/ws/src/shapes.zig:67:5: 0x104e4a08f in test.deliberately failing (test)
    \\    try std.testing.expectEqual(@as(u64, 5), r.area()); // wrong on purpose: 4 != 5
    \\    ^
    \\4/4 shapes.test.comptime sum...SKIP
    \\2 passed; 1 skipped; 1 failed.
    \\error: the following test command failed with exit code 1:
    \\.zig-cache/o/375fcc04b36b3a995783ff1c41e515fe/test --seed=0x4939d863
    \\
;

const fixture_zig_build =
    \\test
    \\+- run test 4 pass, 1 fail (5 total)
    \\error: 'shapes.test.deliberately failing' failed:
    \\       expected 5, found 4
    \\       /opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/testing.zig:118:17: 0x1024763f7 in expectEqualInner__anon_36444 (test)
    \\                       return error.TestExpectedEqual;
    \\                       ^
    \\       /ws/src/shapes.zig:67:5: 0x1024764db in test.deliberately failing (test)
    \\           try std.testing.expectEqual(@as(u64, 5), r.area()); // wrong on purpose: 4 != 5
    \\           ^
    \\failed command: ./.zig-cache/o/60b5aa4b2908258e4b89e25782dcc59d/test --cache-dir=./.zig-cache --seed=0xee704cf3 --listen=-
    \\
    \\Build Summary: 1/3 steps succeeded (1 failed); 4/5 tests passed (1 failed)
    \\test transitive failure
    \\+- run test 4 pass, 1 fail (5 total)
    \\
    \\error: the following build command failed with exit code 1:
    \\.zig-cache/o/bacf93cf55cce9d7fda50453218d86ac/build /opt/homebrew/bin/zig /opt/homebrew/lib/zig /ws .zig-cache /Users/x/.cache/zig --seed 0xee704cf3 -Z7bcad6dd5908b9d7 test
    \\
;

test "parseZig: the test runner's lines are rows with the failure's message and its OWN frame; the build runner's report names the failures and the tally supplies the passes; a compile error is global" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tr = try parseZig(a, fixture_zig_test, "/ws");
    try t.expectEqual(@as(usize, 4), tr.tests.len);
    try t.expectEqualStrings("rect area", tr.tests[0].title);
    try t.expectEqualStrings("shapes", tr.tests[0].suite_path);
    try t.expectEqual(Status.passed, tr.tests[0].status);
    try t.expectEqual(Status.passed, tr.tests[1].status);
    const f = tr.tests[2];
    try t.expectEqual(Status.failed, f.status);
    try t.expectEqualStrings("deliberately failing", f.title);
    try t.expectEqualStrings("expected 5, found 4\nFAIL (TestExpectedEqual)", f.err.?);
    // std's frames come first; the test's own is the location.
    try t.expectEqualStrings("src/shapes.zig", f.file);
    try t.expectEqual(@as(u32, 67), f.line);
    try t.expectEqual(Status.skipped, tr.tests[3].status);
    try t.expectEqualStrings("2 passed; 1 skipped; 1 failed.", tr.summary);
    try t.expectEqual(@as(usize, 0), tr.passed_unlisted);
    try t.expectEqual(@as(usize, 2), tr.passed());
    try t.expectEqual(@as(usize, 0), tr.global_errors.len);

    const build = try parseZig(a, fixture_zig_build, "/ws");
    try t.expectEqual(@as(usize, 1), build.tests.len);
    try t.expectEqual(Status.failed, build.tests[0].status);
    try t.expectEqualStrings("deliberately failing", build.tests[0].title);
    try t.expectEqualStrings("expected 5, found 4", build.tests[0].err.?);
    try t.expectEqualStrings("src/shapes.zig", build.tests[0].file);
    try t.expectEqual(@as(u32, 67), build.tests[0].line);
    try t.expectEqualStrings("Build Summary: 1/3 steps succeeded (1 failed); 4/5 tests passed (1 failed)", build.summary);
    try t.expectEqual(@as(usize, 4), build.passed_unlisted);
    try t.expectEqual(@as(usize, 4), build.passed());
    try t.expectEqual(@as(usize, 1), build.count(.failed));

    const broken = try parseZig(a, "src/a.zig:3:5: error: expected ';', found '}'\n    x\n    ^\nerror: the following command failed\n", "/ws");
    try t.expectEqual(@as(usize, 0), broken.tests.len);
    try t.expectEqual(@as(usize, 1), broken.global_errors.len);
    try t.expectEqualStrings("src/a.zig:3:5: error: expected ';', found '}'", broken.global_errors[0]);
    // A doctest, and a bare name.
    try t.expectEqualStrings("Rect", splitZigName("shapes.decltest.Rect").title);
    try t.expectEqualStrings("shapes", splitZigName("shapes.decltest.Rect").suite);
    try t.expectEqualStrings("x", splitZigName("test.x").title);
    try t.expectEqualStrings("plain", splitZigName("plain").title);
}

test "locateSources (.zig): a passed row is found by its `test \"…\"` line; zig-out/ and .zig-cache/ are skipped" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try tmp.dir.createDirPath(t.io, "src");
    try tmp.dir.createDirPath(t.io, "zig-out/bin");
    try tmp.dir.createDirPath(t.io, ".zig-cache/o");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "zig-out/bin/a.zig", .data = "test \"rect area\" {}\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".zig-cache/o/a.zig", .data = "test \"rect area\" {}\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/shapes.zig", .data = "const std = @import(\"std\");\n\ntest \"rect area\" {\n    try std.testing.expect(true);\n}\n\ntest \"rect\" {}\n" });
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tests = [_]TestCase{
        .{ .title = "rect area", .suite_path = "shapes", .file = "", .line = 0, .status = .passed, .duration_ms = 0, .err = null, .trace_path = null },
        .{ .title = "rect", .suite_path = "shapes", .file = "", .line = 0, .status = .passed, .duration_ms = 0, .err = null, .trace_path = null },
        .{ .title = "nowhere", .suite_path = "shapes", .file = "", .line = 0, .status = .passed, .duration_ms = 0, .err = null, .trace_path = null },
    };
    try locateSources(a, t.io, root, root, &tests, .zig);
    try t.expectEqualStrings("src/shapes.zig", tests[0].file);
    try t.expectEqual(@as(u32, 3), tests[0].line);
    try t.expectEqualStrings("src/shapes.zig", tests[1].file);
    try t.expectEqual(@as(u32, 7), tests[1].line);
    try t.expectEqualStrings("", tests[2].file);
}

test "test.run_at_cursor on a Zig project: `zig build test -Dtest-filter=<name>` when build.zig declares the option, `zig test <file> --test-filter <name>` when it does not; run_file and run_all" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try tmp.dir.createDirPath(t.io, "src");
    try tmp.dir.createDirPath(t.io, "bin");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.zig", .data = "const std = @import(\"std\");\npub fn build(b: *std.Build) void {\n    _ = b.option([]const u8, \"test-filter\", \"only these\");\n}\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/a.zig", .data = "const std = @import(\"std\");\ntest \"one\" {\n    try std.testing.expect(true);\n}\ntest \"two\" {\n    try std.testing.expect(true);\n}\n" });
    // A `zig` of our own on the App's PATH, so the pane opens.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bin/zig", .data = "#!/bin/sh\necho \"1 passed; 0 skipped; 0 failed.\" >&2\n" });
    const bin_path = try std.fs.path.join(t.allocator, &.{ root, "bin", "zig" });
    defer t.allocator.free(bin_path);
    try Io.Dir.cwd().setFilePermissions(t.io, bin_path, .fromMode(0o755), .{});
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const bin = try std.fs.path.join(t.allocator, &.{ root, "bin" });
    defer t.allocator.free(bin);
    try env.put("PATH", bin);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 120, .rows = 30, .env = &env });
    defer app.deinit();
    app.tree.visible = false;
    const file = try std.fs.path.join(t.allocator, &.{ root, "src", "a.zig" });
    defer t.allocator.free(file);
    const ed = try app.openPath(file);
    try t.expectEqual(runners.Project.zig, runners.detectProject(&app).?);
    // Inside `two` (line 6, 0-based 5).
    app.activeEditor().?.buf.editor.placeCursor(5, 4);
    try command.run(&app, .{ .static = .@"test.run_at_cursor" });
    const id = find(&app).?;
    const p = &app.panes.get(id).?.tests;
    try t.expectEqual(Runner.zig, p.runner);
    try t.expectEqualStrings(root, p.cwd.?);
    try t.expectEqual(@as(usize, 3), p.last_args.len);
    try t.expectEqualStrings("build", p.last_args[0]);
    try t.expectEqualStrings("test", p.last_args[1]);
    try t.expectEqualStrings("-Dtest-filter=two", p.last_args[2]);
    p.group.cancel(t.io);
    // Without the option: the file, filtered.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.zig", .data = "const std = @import(\"std\");\npub fn build(b: *std.Build) void {\n    _ = b;\n}\n" });
    app.showPane(ed);
    try command.run(&app, .{ .static = .@"test.run_at_cursor" });
    try t.expectEqual(@as(usize, 4), p.last_args.len);
    try t.expectEqualStrings("test", p.last_args[0]);
    try t.expectEqualStrings("src/a.zig", p.last_args[1]);
    try t.expectEqualStrings("--test-filter", p.last_args[2]);
    try t.expectEqualStrings("two", p.last_args[3]);
    p.group.cancel(t.io);
    app.showPane(ed);
    try command.run(&app, .{ .static = .@"test.run_file" });
    try t.expectEqual(@as(usize, 2), p.last_args.len);
    try t.expectEqualStrings("test", p.last_args[0]);
    try t.expectEqualStrings("src/a.zig", p.last_args[1]);
    p.group.cancel(t.io);
    app.showPane(ed);
    try command.run(&app, .{ .static = .@"test.run_all" });
    try t.expectEqual(@as(usize, 2), p.last_args.len);
    try t.expectEqualStrings("build", p.last_args[0]);
    try t.expectEqualStrings("test", p.last_args[1]);
    p.group.cancel(t.io);
    // A result lands: the build format's tally is the pass count.
    p.generation +%= 1;
    const r = try Result.create(t.allocator, p.generation, id);
    r.run = try parseZig(r.arena.allocator(), fixture_zig_build, "/ws");
    try handle(&app, r);
    try t.expectEqual(State.done, p.state);
    try t.expectEqualStrings("tests: 1 failed, 4 passed", app.lastToast().?);
    try t.expectEqualStrings("deliberately failing", p.selected().?.title);
}

test "parseTrx: outcomes, durations to the ms, the class from the definitions, the message and the frame unescaped" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try parseTrx(a, fixture_trx, "C:\\ws");
    try t.expectEqual(@as(usize, 6), r.tests.len);
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
    // A Theory's data rows: one row each, named with their arguments;
    // the method is what the sources and the re-run filter see.
    try t.expectEqualStrings("Describes(x: 2, y: 2, expected: \"diagonal 2\")", r.tests[3].title);
    try t.expectEqualStrings("Describes(x: 1, y: 5, expected: \"point 1,5\")", r.tests[4].title);
    try t.expectEqualStrings("Acme.Tests.CalcTests", r.tests[4].suite_path);
    try t.expectEqualStrings("Describes", methodOf(r.tests[4].title));
    // A `DisplayName` that does not name the method: the method, as before.
    try t.expectEqualStrings("AddsNamed", r.tests[5].title);
    try t.expectEqual(@as(usize, 0), (try parseTrx(a, "<TestRun/>", "/ws")).tests.len);
}

test "a Theory's data rows are separate rows with separate histories: breaking one row marks that row, not its siblings" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const row = "<UnitTestResult testId=\"{s}\" testName=\"Acme.Tests.CalcTests.Describes(x: {d}, y: {d})\" duration=\"00:00:00.001\" outcome=\"{s}\" />";
    const def = "<UnitTest name=\"Acme.Tests.CalcTests.Describes(x: {d}, y: {d})\" id=\"{s}\"><TestMethod className=\"Acme.Tests.CalcTests\" name=\"Describes\" /></UnitTest>";
    const Trx = struct {
        fn of(ar: Allocator, outcomes: [3][]const u8) ![]const u8 {
            return std.fmt.allocPrint(ar, "<TestRun><Results>" ++ row ++ row ++ row ++ "</Results><TestDefinitions>" ++ def ++ def ++ def ++ "</TestDefinitions></TestRun>", .{
                "a", 0, 0,   outcomes[0], "b", 2,   2, outcomes[1], "c", 1, 5, outcomes[2],
                0,   0, "a", 2,           2,   "b", 1, 5,           "c",
            });
        }
    };
    var h: flaky.History = .{};
    defer h.deinit(t.allocator);
    for ([_][3][]const u8{ .{ "Passed", "Passed", "Passed" }, .{ "Passed", "Failed", "Passed" } }) |outcomes| {
        const r = try parseTrx(a, try Trx.of(a, outcomes), "/ws");
        try t.expectEqual(@as(usize, 3), r.tests.len);
        for (r.tests) |tc| try h.record(t.allocator, try flaky.keyOf(a, tc.file, tc.suite_path, tc.title), if (tc.status == .passed) .pass else .fail, tc.line);
    }
    // Three keys, not one: the broken row changed, its siblings did not.
    try t.expectEqual(@as(usize, 3), h.entries.count());
    try t.expect(h.get(try flaky.keyOf(a, "", "Acme.Tests.CalcTests", "Describes(x: 2, y: 2)")).?.wobbly());
    try t.expect(!h.get(try flaky.keyOf(a, "", "Acme.Tests.CalcTests", "Describes(x: 0, y: 0)")).?.wobbly());
    try t.expect(!h.get(try flaky.keyOf(a, "", "Acme.Tests.CalcTests", "Describes(x: 1, y: 5)")).?.wobbly());
}

test "a failure's frame under a symlinked workspace: the real path becomes workspace-relative, as its passing siblings are" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try tmp.dir.createDirPath(t.io, "ws/tests/Acme.Tests");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/tests/Acme.Tests/CalcTests.cs", .data = "class CalcTests {}\n" });
    try tmp.dir.symLink(t.io, "ws", "link", .{ .is_directory = true });
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The workspace is the link; the compiler wrote the real path.
    const workspace = try std.fs.path.join(a, &.{ real, "link" });
    const frame_path = try std.fs.path.join(a, &.{ real, "ws", "tests", "Acme.Tests", "CalcTests.cs" });
    const outside = try std.fs.path.join(a, &.{ real, "elsewhere.cs" });
    var tests = [_]TestCase{
        .{ .title = "DividesWrong", .suite_path = "Acme.Tests.CalcTests", .file = frame_path, .line = 14, .status = .failed, .duration_ms = 0, .err = null, .trace_path = null },
        .{ .title = "Gone", .suite_path = "", .file = outside, .line = 1, .status = .failed, .duration_ms = 0, .err = null, .trace_path = null },
        .{ .title = "Adds", .suite_path = "Acme.Tests.CalcTests", .file = "tests/Acme.Tests/CalcTests.cs", .line = 9, .status = .passed, .duration_ms = 0, .err = null, .trace_path = null },
    };
    // The prefix test alone keeps it absolute.
    try t.expect(std.fs.path.isAbsolute(try relativeTo(a, frame_path, workspace)));
    try realRelative(a, t.io, workspace, &tests);
    try t.expectEqualStrings("tests/Acme.Tests/CalcTests.cs", tests[0].file);
    // A file that is not there (or not inside) stays as the frame said.
    try t.expectEqualStrings(outside, tests[1].file);
    try t.expectEqualStrings("tests/Acme.Tests/CalcTests.cs", tests[2].file);
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
    try locateSources(a, t.io, root, root, &tests, .cs);
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

pub const fixture_vitest =
    \\{"numTotalTestSuites":3,"numPassedTestSuites":1,"numFailedTestSuites":2,"numPendingTestSuites":0,"numTotalTests":4,"numPassedTests":3,"numFailedTests":1,"numPendingTests":0,"numTodoTests":0,"startTime":1790089422084,"success":false,"testResults":[
    \\{"assertionResults":[
    \\{"ancestorTitles":["clamp"],"fullName":"clamp clamps below","status":"passed","title":"clamps below","duration":0.7033329999999864,"failureMessages":[],"location":{"line":5,"column":3},"meta":{}},
    \\{"ancestorTitles":["clamp"],"fullName":"clamp clamps above","status":"passed","title":"clamps above","duration":1.5,"failureMessages":[],"location":{"line":8,"column":3},"meta":{}},
    \\{"ancestorTitles":["clamp"],"fullName":"clamp is wrong on purpose","status":"failed","title":"is wrong on purpose","duration":4.518791999999962,"failureMessages":["\u001b[31mAssertionError\u001b[39m: expected 50 to be 51 // Object.is equality\n    at /ws/tests/math.test.ts:12:23\n    at file:///ws/node_modules/@vitest/runner/dist/chunk-hooks.js:155:11"],"meta":{}},
    \\{"ancestorTitles":["area"],"fullName":"area square","status":"passed","title":"square","duration":0.14045800000002373,"failureMessages":[],"location":{"line":17,"column":3},"meta":{}}
    \\],"startTime":1790089422500,"endTime":1790089422600,"status":"failed","message":"","name":"/ws/tests/math.test.ts"},
    \\{"assertionResults":[],"startTime":1790089422500,"endTime":1790089422600,"status":"failed","message":"Error: Failed to resolve import \"./gone\" from \"tests/broken.test.ts\". Does the file exist?\n    at x","name":"/ws/tests/broken.test.ts"},
    \\{"assertionResults":[{"ancestorTitles":[],"fullName":"later","status":"pending","title":"later","duration":0,"failureMessages":[],"meta":{}}],"status":"passed","message":"","name":"/ws/tests/todo.test.ts"}
    \\]}
;

test "parseVitest: the Jest-shaped report — describes, statuses, ms, the `it(` line or the frame's, the message without its stack, a broken file, vitest's own tally" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try parseVitest(a, fixture_vitest, "/ws", "");
    try t.expectEqual(@as(usize, 5), r.tests.len);
    try t.expectEqual(@as(usize, 3), r.count(.passed));
    try t.expectEqual(@as(usize, 1), r.count(.failed));
    try t.expectEqual(@as(usize, 1), r.count(.skipped));
    const below = r.tests[0];
    try t.expectEqualStrings("clamps below", below.title);
    try t.expectEqualStrings("clamp", below.suite_path);
    try t.expectEqualStrings("tests/math.test.ts", below.file);
    try t.expectEqual(@as(u32, 5), below.line);
    try t.expectEqual(@as(u64, 0), below.duration_ms);
    try t.expectEqual(@as(u64, 1), r.tests[1].duration_ms);
    const bad = r.tests[2];
    try t.expectEqual(Status.failed, bad.status);
    // No location: the frame inside the test's file names the line; the stack stays out of the message.
    try t.expectEqual(@as(u32, 12), bad.line);
    try t.expectEqualStrings("AssertionError: expected 50 to be 51 // Object.is equality", bad.err.?);
    try t.expectEqual(@as(u64, 4), bad.duration_ms);
    try t.expectEqualStrings("area", r.tests[3].suite_path);
    try t.expectEqualStrings("", r.tests[4].suite_path);
    try t.expectEqual(Status.skipped, r.tests[4].status);
    try t.expectEqual(@as(usize, 1), r.global_errors.len);
    try t.expectEqualStrings("tests/broken.test.ts: Error: Failed to resolve import \"./gone\" from \"tests/broken.test.ts\". Does the file exist?", r.global_errors[0]);
    try t.expectEqualStrings("Tests  1 failed | 3 passed (4)", r.summary);
    try t.expectError(error.NotJson, parseVitest(a, "vitest: no config", "/ws", ""));
    try t.expectError(error.NotJson, parseVitest(a, "{\"ok\":true}", "/ws", ""));
    // The tool names the workspace by its real path: the row is still relative.
    const via_real = try parseVitest(a, "{\"numTotalTests\":1,\"testResults\":[{\"name\":\"/private/ws/a.test.ts\",\"status\":\"passed\",\"assertionResults\":[{\"title\":\"x\",\"status\":\"passed\",\"ancestorTitles\":[]}]}]}", "/ws", "/private/ws");
    try t.expectEqualStrings("a.test.ts", via_real.tests[0].file);
    // The re-run: the failures' full names as one anchored regex (metacharacters escaped), then their files.
    const args = (try vitestFailedArgs(a, r)).?;
    try t.expectEqual(@as(usize, 3), args.len);
    try t.expectEqualStrings("-t", args[0]);
    try t.expectEqualStrings("^(clamp is wrong on purpose)$", args[1]);
    try t.expectEqualStrings("tests/math.test.ts", args[2]);
    const two = TestRun{ .tests = &.{
        .{ .title = "adds (1+1)", .suite_path = "math › sum", .file = "a.test.ts", .line = 1, .status = .failed, .duration_ms = 0, .err = null, .trace_path = null },
        .{ .title = "fine", .suite_path = "", .file = "a.test.ts", .line = 2, .status = .passed, .duration_ms = 0, .err = null, .trace_path = null },
        .{ .title = "x.y", .suite_path = "", .file = "b.test.ts", .line = 3, .status = .failed, .duration_ms = 0, .err = null, .trace_path = null },
    } };
    const args2 = (try vitestFailedArgs(a, two)).?;
    try t.expectEqualStrings("^(math sum adds \\(1\\+1\\)|x\\.y)$", args2[1]);
    try t.expectEqualStrings("a.test.ts", args2[2]);
    try t.expectEqualStrings("b.test.ts", args2[3]);
    try t.expect((try vitestFailedArgs(a, .{})) == null);
    try t.expectEqualStrings("npx vitest run --reporter=json --includeTaskLocation -t \"^(a b)$\" a.test.ts", try cmdlineFor(a, .vitest, &.{ "-t", "^(a b)$", "a.test.ts" }));
    // A package.json names vitest by dependency or by its test script.
    try t.expect(packageNamesVitest(a, "{\"devDependencies\":{\"vitest\":\"^3\"}}"));
    try t.expect(packageNamesVitest(a, "{\"scripts\":{\"test\":\"vitest run --coverage\"}}"));
    try t.expect(packageNamesVitest(a, "{\"scripts\":{\"test\":\"vitest\"}}"));
    try t.expect(!packageNamesVitest(a, "{\"scripts\":{\"test\":\"jest\"},\"devDependencies\":{\"vitest-fetch-mock\":\"1\"}}"));
    try t.expect(!packageNamesVitest(a, "not json"));
}

pub const fixture_junit =
    \\<?xml version="1.0" encoding="utf-8"?><testsuites name="pytest tests"><testsuite name="pytest" errors="0" failures="1" skipped="1" tests="5" time="0.037">
    \\<testcase classname="tests.test_cli" name="test_classify[item0-heavy]" file="tests/test_cli.py" line="6" time="0.001" />
    \\<testcase classname="tests.test_models" name="test_total_weight_is_wrong_on_purpose" file="tests/test_models.py" line="14" time="0.0025"><failure message="AssertionError: assert 40.201 == 41.0&#10; +  where 40.201 = total_weight()">shelf = Shelf(name='bench')
    \\
    \\    def test_total_weight_is_wrong_on_purpose(shelf):
    \\&gt;       assert shelf.total_weight() == 41.0
    \\E       AssertionError: assert 40.201 == 41.0
    \\
    \\tests/test_models.py:17: AssertionError</failure></testcase>
    \\<testcase classname="tests.test_models" name="test_shelf_sorting" file="tests/test_models.py" line="19" time="0.000"><skipped type="pytest.skip" message="not implemented yet">/ws/tests/test_models.py:20: not implemented yet</skipped></testcase>
    \\<testcase classname="tests.test_models.TestBox" name="test_take[first]" file="tests/test_models.py" line="34" time="1.5" />
    \\<testcase classname="" name="tests/test_broken.py" time="0.0"><error message="collection failure">ImportError while importing test module '/ws/tests/test_broken.py'.
    \\tests/test_broken.py:1: in &lt;module&gt;
    \\    import nope
    \\E   ModuleNotFoundError: No module named 'nope'</error></testcase>
    \\</testsuite></testsuites>
;

test "parseJunit: pytest's xunit1 — parametrize ids, the class past the module, the def line 1-based or the failing frame's, seconds to ms, a collection error" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try parseJunit(a, fixture_junit, "/ws", "/ws", "");
    try t.expectEqual(@as(usize, 5), r.tests.len);
    try t.expectEqualStrings("test_classify[item0-heavy]", r.tests[0].title);
    try t.expectEqualStrings("", r.tests[0].suite_path);
    try t.expectEqualStrings("tests/test_cli.py", r.tests[0].file);
    try t.expectEqual(@as(u32, 7), r.tests[0].line);
    try t.expectEqual(@as(u64, 1), r.tests[0].duration_ms);
    const bad = r.tests[1];
    try t.expectEqual(Status.failed, bad.status);
    try t.expectEqual(@as(u32, 17), bad.line);
    try t.expectEqualStrings("AssertionError: assert 40.201 == 41.0\n +  where 40.201 = total_weight()", bad.err.?);
    try t.expectEqual(@as(u64, 2), bad.duration_ms);
    try t.expectEqual(Status.skipped, r.tests[2].status);
    try t.expectEqual(@as(u32, 20), r.tests[2].line);
    try t.expectEqualStrings("TestBox", r.tests[3].suite_path);
    try t.expectEqual(@as(u64, 1500), r.tests[3].duration_ms);
    try t.expectEqual(Status.failed, r.tests[4].status);
    try t.expectEqualStrings("tests/test_broken.py", r.tests[4].title);
    try t.expectEqualStrings("collection failure", r.tests[4].err.?);
    // A run at a project below the workspace: the file is made workspace-relative.
    const deep = try parseJunit(a, fixture_junit, "/ws/py", "/ws", "");
    try t.expectEqualStrings("py/tests/test_cli.py", deep.tests[0].file);
    // The re-run: node ids of the failures, the class in the middle.
    const ids = (try pytestFailedArgs(a, r)).?;
    try t.expectEqual(@as(usize, 1), ids.len);
    try t.expectEqualStrings("tests/test_models.py::test_total_weight_is_wrong_on_purpose", ids[0]);
    const cls = TestRun{ .tests = &.{.{ .title = "test_take[first]", .suite_path = "TestBox", .file = "tests/test_models.py", .line = 35, .status = .failed, .duration_ms = 0, .err = null, .trace_path = null }} };
    try t.expectEqualStrings("tests/test_models.py::TestBox::test_take[first]", (try pytestFailedArgs(a, cls)).?[0]);
    try t.expect((try pytestFailedArgs(a, .{})) == null);
    try t.expectEqualStrings("pytest -q -rA -o junit_family=xunit1 --junitxml=.mnml/pytest-junit.xml tests/a.py -k test_x", try cmdlineFor(a, .pytest, &.{ "tests/a.py", "-k", "test_x" }));
}

test "parsePytestConsole and pytestSummary: the -rA lines when no JUnit file landed, and the tally line without its rule" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = "........Fs.....                                                          [100%]\n=================================== FAILURES ===================================\n=========================== short test summary info ============================\nPASSED tests/test_cli.py::test_classify[item0-heavy]\nPASSED tests/test_models.py::TestBox::test_take[first]\nSKIPPED [1] tests/test_models.py:20: not implemented yet\nFAILED tests/test_models.py::test_total_weight_is_wrong_on_purpose - AssertionError: assert 40.201 == 41.0\nERROR tests/test_broken.py - ImportError\n=========== 1 failed, 2 passed, 1 skipped, 1 error in 0.04s ============\n";
    const r = try parsePytestConsole(a, text, "/ws");
    try t.expectEqual(@as(usize, 5), r.tests.len);
    try t.expectEqualStrings("test_classify[item0-heavy]", r.tests[0].title);
    try t.expectEqualStrings("tests/test_cli.py", r.tests[0].file);
    try t.expectEqualStrings("TestBox", r.tests[1].suite_path);
    try t.expectEqualStrings("test_take[first]", r.tests[1].title);
    try t.expectEqual(Status.skipped, r.tests[2].status);
    try t.expectEqual(@as(u32, 20), r.tests[2].line);
    try t.expectEqualStrings("not implemented yet", r.tests[2].title);
    try t.expectEqual(Status.failed, r.tests[3].status);
    try t.expectEqualStrings("AssertionError: assert 40.201 == 41.0", r.tests[3].err.?);
    try t.expectEqual(Status.failed, r.tests[4].status);
    try t.expectEqualStrings("tests/test_broken.py", r.tests[4].file);
    try t.expectEqualStrings("1 failed, 2 passed, 1 skipped, 1 error in 0.04s", pytestSummary(text));
    try t.expectEqualStrings("no tests ran in 0.01s", pytestSummary("\n============================ no tests ran in 0.01s =============================\n"));
    try t.expectEqualStrings("", pytestSummary("usage: pytest [options]\npytest: error: unrecognized arguments\n"));
}

test "test.run_all on a vitest project opens the pane; a vitest result lands and R re-runs the failure by name; a pytest result likewise by node id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    // A package.json without vitest is not a vitest project; one naming it is.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "package.json", .data = "{\"scripts\":{\"test\":\"jest\"}}\n" });
    try t.expect(vitestProject(&app) == null);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "package.json", .data = "{\"devDependencies\":{\"vitest\":\"^3\"}}\n" });
    try t.expectEqualStrings(root, vitestProject(&app).?);
    try tmp.dir.createDirPath(t.io, "tests");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "tests/math.test.ts", .data = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n" });
    try vitestAll(&app);
    const id = find(&app).?;
    const p = &app.panes.get(id).?.tests;
    try t.expectEqual(Runner.vitest, p.runner);
    try t.expectEqual(State.running, p.state);
    p.group.cancel(t.io);
    p.generation +%= 1;
    const r = try Result.create(t.allocator, p.generation, id);
    r.run = try parseVitest(r.arena.allocator(), fixture_vitest, "/ws", "");
    try handle(&app, r);
    try t.expectEqual(State.done, p.state);
    try t.expectEqualStrings("Tests  1 failed | 3 passed (4)", p.run.summary);
    try t.expectEqualStrings("is wrong on purpose", p.selected().?.title);
    // Enter: the frame's line in the test file. (Opening a pane moves the
    // store, so the pane is fetched again after each.)
    app.showPane(id);
    _ = try handleKey(&app, id, p, .{ .code = .enter });
    const e = app.activeEditor().?;
    try t.expectEqualStrings("tests/math.test.ts", app.relPath(e.buf.doc.path.?));
    try t.expectEqual(@as(usize, 11), e.buf.editor.rowCol().row);
    // R: `-t` with the failure's full name and its file — not the whole suite.
    try vitestRerunFailed(&app);
    const p2 = &app.panes.get(id).?.tests;
    try t.expectEqualStrings("-t", p2.last_args[0]);
    try t.expectEqualStrings("^(clamp is wrong on purpose)$", p2.last_args[1]);
    try t.expectEqualStrings("tests/math.test.ts", p2.last_args[2]);
    p2.group.cancel(t.io);
    // The pane switches to pytest on a Python project's run; its R is the node ids.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "pyproject.toml", .data = "[project]\nname = \"x\"\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "tests/test_models.py", .data = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n" });
    if (!runners.onPath(&app, "pytest")) {
        // No pytest anywhere: the install box, no run.
        try t.expectError(error.Failed, pytestAll(&app));
        try t.expect(app.overlay == .confirm);
        app.overlay.deinit(app.gpa);
        app.overlay = .none;
        try tmp.dir.createDirPath(t.io, ".venv/bin");
        try tmp.dir.writeFile(t.io, .{ .sub_path = ".venv/bin/pytest", .data = "#!/bin/sh\nexit 1\n" });
    }
    try pytestAll(&app);
    const p3 = &app.panes.get(id).?.tests;
    try t.expectEqual(Runner.pytest, p3.runner);
    p3.group.cancel(t.io);
    p3.generation +%= 1;
    const r2 = try Result.create(t.allocator, p3.generation, id);
    r2.run = try parseJunit(r2.arena.allocator(), fixture_junit, root, root, "");
    r2.run.?.summary = "1 failed, 2 passed, 1 skipped, 1 error in 0.04s";
    try handle(&app, r2);
    try t.expectEqual(State.done, p3.state);
    try t.expectEqualStrings("test_total_weight_is_wrong_on_purpose", p3.selected().?.title);
    app.showPane(id);
    _ = try handleKey(&app, id, p3, .{ .code = .enter });
    const e2 = app.activeEditor().?;
    try t.expectEqualStrings("tests/test_models.py", app.relPath(e2.buf.doc.path.?));
    try t.expectEqual(@as(usize, 16), e2.buf.editor.rowCol().row);
    try pytestRerunFailed(&app);
    const p4 = &app.panes.get(id).?.tests;
    try t.expectEqualStrings("tests/test_models.py::test_total_weight_is_wrong_on_purpose", p4.last_args[0]);
    try t.expectEqual(@as(usize, 1), p4.last_args.len);
    p4.group.cancel(t.io);
    // The venv's bin goes first on the worker's PATH.
    try tmp.dir.createDirPath(t.io, ".venv/bin");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".venv/bin/pytest", .data = "#!/bin/sh\nexit 1\n" });
    const venv = pytestVenvBin(&app, root).?;
    try t.expect(std.mem.endsWith(u8, venv, ".venv/bin"));
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
