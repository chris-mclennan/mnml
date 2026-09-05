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

/// `npx playwright test --reporter=json --trace=retain-on-failure <extra>`.
pub fn argvFor(arena: Allocator, extra: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, base_argv.len + extra.len);
    @memcpy(out[0..base_argv.len], &base_argv);
    @memcpy(out[base_argv.len..], extra);
    return out;
}

pub fn cmdlineFor(arena: Allocator, extra: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (base_argv, 0..) |a, i| {
        if (i > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, a);
    }
    for (extra) |a| {
        try out.append(arena, ' ');
        try out.appendSlice(arena, a);
    }
    return out.toOwnedSlice(arena);
}

/// Run the suite and post the result. `env` is the worker's own copy
/// (`PW_TEST_HTML_REPORT_OPEN=never` keeps the HTML report closed) and
/// is freed here; `extra` is the pane's `last_args`, copied first.
fn worker(events: *event.EventQueue, io: Io, gpa: Allocator, cwd: []const u8, env: *std.process.Environ.Map, extra: []const []const u8, generation: u32, pane: PaneId) Io.Cancelable!void {
    defer {
        env.deinit();
        gpa.destroy(env);
        for (extra) |a| gpa.free(a);
        gpa.free(extra);
        gpa.free(cwd);
    }
    const result = Result.create(gpa, generation, pane) catch return;
    const arena = result.arena.allocator();
    const argv = argvFor(arena, extra) catch {
        result.destroy(gpa);
        return;
    };
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
            result.err = std.fmt.allocPrint(arena, "running `npx playwright test`: {s} — is Playwright installed here?", .{@errorName(err)}) catch null;
            events.post(io, .{ .tests = result });
            return;
        },
    };
    defer gpa.free(proc.stdout);
    defer gpa.free(proc.stderr);
    if (parseReport(arena, proc.stdout)) |parsed| {
        var r = parsed;
        r.command = cmdlineFor(arena, extra) catch "";
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
    group: Io.Group = .init,
    generation: u32 = 0,
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

    pub fn init(gpa: Allocator) TestsPane {
        return .{ .snapshot = alloc.SnapshotArena.init(gpa) };
    }

    pub fn deinit(self: *TestsPane, gpa: Allocator, io: Io) void {
        self.group.cancel(io);
        for (self.last_args) |a| gpa.free(a);
        gpa.free(self.last_args);
        self.snapshot.deinit();
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

/// Start (or restart) a run with `extra` args: the one tests pane,
/// below the active pane the first time.
pub fn run(app: *App, extra: []const []const u8) CommandError!PaneId {
    const root = try projectRoot(app);
    const id = find(app) orelse blk: {
        const id = try app.panes.add(.{ .tests = TestsPane.init(app.gpa) });
        const layout = app.layouts.current();
        if (app.active) |cur| if (layout.leafOf(cur) != null) {
            _ = layout.split(cur, .horizontal, id) catch {};
        };
        break :blk id;
    };
    app.showPane(id);
    const p = &app.panes.get(id).?.tests;
    try p.setArgs(app.gpa, extra);
    try start(app, id, p, root);
    return id;
}

fn start(app: *App, id: PaneId, p: *TestsPane, root: []const u8) CommandError!void {
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
    p.group.concurrent(app.io, worker, .{ &app.events, app.io, gpa, cwd, env, extra, p.generation, id }) catch |err| {
        p.state = .failed;
        p.err = "could not start the worker";
        return app.diag.fail(app.frame.allocator(), "playwright: could not start the worker: {s}", .{@errorName(err)});
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
        p.err = try a.dupe(u8, result.err orelse "playwright: error");
        app.toast("playwright: {s}", .{firstLine(p.err)});
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
    return .{ .command = try a.dupe(u8, src.command), .tests = tests, .global_errors = errs };
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

fn rerunSame(app: *App, id: PaneId, p: *TestsPane) CommandError!void {
    const root = try projectRoot(app);
    try start(app, id, p, root);
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
    const path = try std.fs.path.join(arena, &.{ app.workspace, tc.file });
    const src = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(512 * 1024)) catch "";
    const where = if (tc.suite_path.len == 0) try std.fmt.allocPrint(arena, "{s}:{d}", .{ tc.file, tc.line }) else try std.fmt.allocPrint(arena, "{s} › {s}  ({s}:{d})", .{ tc.suite_path, tc.title, tc.file, tc.line });
    const prompt = try std.fmt.allocPrint(arena,
        \\This Playwright test is failing. Work out why and propose a fix — change the test or the code under test as appropriate. Be concise; reply with the patch in a fenced block plus a short note.
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
        \\```ts
        \\{s}
        \\```
    , .{ where, tc.err orelse "", tc.file, src });
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
                'a' => runToast(app, runAll(app)),
                'f' => runToast(app, runFile(app)),
                'R' => runToast(app, rerunFailed(app)),
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
    try t.expectEqualStrings("npx playwright test --reporter=json --trace=retain-on-failure a.spec.ts:3", try cmdlineFor(a, &.{"a.spec.ts:3"}));
    try t.expectEqual(@as(usize, 6), (try argvFor(a, &.{"--last-failed"})).len);
}

test "rows: grouped under file headers with error and trace rows; slowest-first drops the headers; the cursor follows its case" {
    var p = TestsPane.init(t.allocator);
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
