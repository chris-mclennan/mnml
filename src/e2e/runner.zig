//! Runs `.test` scripts against a `Driver`. The oracle for the port: the
//! same files drive Rust mnml, so every timing and every message here is
//! the one that runner uses.
//!
//! Per file: a fresh temp workspace, a driver on its own leak-checking
//! allocator, a fixed 120×40 screen. Every step is followed by a render
//! cycle — tick, 50 ms, expire any pending chord chain, tick, draw — so
//! async work started by the step has a chance to land before the next
//! statement. An expectation that fails is retried every 40 ms for up to
//! 3 s (a tick and a draw between tries) before it counts. `wait <ms>`
//! ticks every 25 ms while the clock runs so background work progresses.
//!
//! A file runs on its own thread under a wall-clock deadline (120 s,
//! `MNML_E2E_FILE_TIMEOUT_SECS`); on timeout the thread is abandoned and
//! the suite continues. Leaked memory fails the file.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parser = @import("parser.zig");
const mock = @import("../http/mock.zig");
const driver_mod = @import("driver.zig");
const key = @import("../core/key.zig");
const screen_mod = @import("../ipc/screen.zig");

pub const Driver = driver_mod.Driver;
pub const Factory = driver_mod.Factory;

pub const Size = struct {
    cols: u16,
    rows: u16,

    pub fn eql(a: Size, b: Size) bool {
        return a.cols == b.cols and a.rows == b.rows;
    }
};

/// Content assertions hold only here; every `.test` was written at it.
pub const content_size: Size = .{ .cols = 120, .rows = 40 };

pub const Timing = struct {
    /// Sleep inside every post-step render cycle.
    step_settle_ms: u64 = 50,
    /// How long a failing expectation is retried.
    expect_budget_ms: u64 = 3000,
    /// Sleep between retries.
    expect_poll_ms: u64 = 40,
    /// Longest sleep between ticks inside `wait`.
    wait_slice_ms: u64 = 25,
};

pub const Options = struct {
    /// `shell` steps are refused unless the caller opted in
    /// (`MNML_E2E_ALLOW_SHELL=1`; `mnml-zig test` sets it).
    allow_shell: bool = false,
    /// Run files marked `# requires: network` (`MNML_E2E_NETWORK=1`).
    network: bool = false,
    file_timeout_secs: u64 = 120,
    /// Screen sizes to run each file at. Assertions count at `content_size` only.
    sizes: []const Size = &.{content_size},
    timing: Timing = .{},
    /// `$SHELL` for `shell` steps.
    shell: []const u8 = "/bin/sh",
    /// Where per-file workspaces are created (`$TMPDIR`).
    tmp_root: []const u8 = "/tmp",
    /// The isolated `MNML_DATA_ROOT` every driver persists into.
    data_root: []const u8,
    /// The environment every App's children inherit (`mnml-zig test`
    /// passes the process's with `MNML_FAKE_DAP` added); null = the
    /// process's own.
    env: ?*const std.process.Environ.Map = null,
    /// Detect leaks without logging the leaked allocations. The list is
    /// what makes a leak fixable, so it stays on outside the harness's own
    /// tests (whose runner treats any logged error as a failure).
    quiet_leak_report: bool = false,
    /// Only files whose name (without `.test`) contains this run
    /// (`-Dtest-filter` reaches here as `--filter`). Others are silent.
    name_filter: ?[]const u8 = null,
    /// File names (without `.test`) to skip, announced as such
    /// (`--skip`): what `zig build check` cuts by design.
    skip: []const []const u8 = &.{},
};

/// The file's name without its `.test`.
pub fn stemOf(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (std.mem.endsWith(u8, base, ".test")) base[0 .. base.len - ".test".len] else base;
}

pub const Outcome = struct {
    name: []u8,
    passed: bool,
    message: ?[]u8,

    pub fn deinit(self: *Outcome, gpa: Allocator) void {
        gpa.free(self.name);
        if (self.message) |m| gpa.free(m);
        self.* = undefined;
    }
};

pub const Stats = struct {
    total: usize = 0,
    failed: usize = 0,
};

// ─── one file ───────────────────────────────────────────────────────────

/// Run one file at one size. Never errors: every failure is an Outcome.
pub fn runFile(gpa: Allocator, io: Io, factory: Factory, path: []const u8, size: Size, opts: Options) Outcome {
    const name = outcomeName(gpa, path, size) catch return oom(gpa, path);
    var run: Run = .{ .gpa = gpa, .io = io, .factory = factory, .path = path, .size = size, .opts = opts, .name = name };
    return run.go();
}

fn oom(gpa: Allocator, path: []const u8) Outcome {
    return .{ .name = gpa.dupe(u8, std.fs.path.basename(path)) catch @constCast(""), .passed = false, .message = null };
}

fn outcomeName(gpa: Allocator, path: []const u8, size: Size) Allocator.Error![]u8 {
    const base = std.fs.path.basename(path);
    if (size.eql(content_size)) return gpa.dupe(u8, base);
    return std.fmt.allocPrint(gpa, "{s} @{d}x{d}", .{ base, size.cols, size.rows });
}

const Run = struct {
    gpa: Allocator,
    io: Io,
    factory: Factory,
    path: []const u8,
    size: Size,
    opts: Options,
    name: []u8,
    workspace: []u8 = "",
    driver: ?Driver = null,
    /// `serve` steps' servers, stopped after the script; their canned
    /// answers live on `serve_arena`.
    servers: std.ArrayListUnmanaged(*mock.Server) = .empty,
    serve_arena: ?std.heap.ArenaAllocator = null,

    fn fail(self: *Run, comptime fmt: []const u8, args: anytype) Outcome {
        const msg = std.fmt.allocPrint(self.gpa, fmt, args) catch null;
        return .{ .name = self.name, .passed = false, .message = msg };
    }

    fn go(self: *Run) Outcome {
        const gpa = self.gpa;
        const io = self.io;

        const text = Io.Dir.cwd().readFileAlloc(io, self.path, gpa, .unlimited) catch |e| return self.fail("can't read: {s}", .{@errorName(e)});
        defer gpa.free(text);
        var diag: parser.Diagnostic = .{};
        var script = parser.parse(gpa, text, &diag) catch |e| switch (e) {
            error.Syntax => return self.fail("{s}", .{diag.message()}),
            error.OutOfMemory => return self.fail("out of memory", .{}),
        };
        defer script.deinit();

        self.workspace = makeTempDir(gpa, io, self.opts.tmp_root) catch |e| return self.fail("tempdir: {s}", .{@errorName(e)});
        defer {
            Io.Dir.cwd().deleteTree(io, self.workspace) catch {};
            gpa.free(self.workspace);
        }

        // The driver gets its own leak-checking allocator: a leak anywhere
        // in the App is this file's failure, not a note at process exit.
        var dbg: std.heap.DebugAllocator(.{ .safety = true, .thread_safe = true, .enable_memory_limit = true }) = .init;
        // `# env: NAME=value` lines: the App's environment is the run's
        // (or the process's) plus those, for this file only. `$NAME` /
        // `${NAME}` in a value expands from the run's environment
        // (`PATH=${MNML_SHIMS}:${PATH}`), an unset name to nothing.
        // `MNML_E2E_WORKSPACE` is this file's temp workspace, so a
        // value can name a directory inside it (`HOME=`, a PATH entry a
        // shim's "installer" drops a fake binary into).
        const header = parser.parseHeader(text);
        var file_env: ?std.process.Environ.Map = null;
        defer if (file_env) |*m| m.deinit();
        if (header.env_len > 0) {
            var m = (if (self.opts.env) |e| e.clone(gpa) else std.process.Environ.Map.init(gpa)) catch return self.fail("out of memory", .{});
            m.put("MNML_E2E_WORKSPACE", self.workspace) catch return self.fail("out of memory", .{});
            for (header.envPairs()) |pair| {
                const value = expandEnv(gpa, pair.value, &m) catch return self.fail("out of memory", .{});
                defer gpa.free(value);
                m.put(pair.key, value) catch return self.fail("out of memory", .{});
            }
            file_env = m;
        }
        const outcome = blk: {
            const d = self.factory.make(dbg.allocator(), io, .{
                .workspace = self.workspace,
                .data_root = self.opts.data_root,
                .cols = self.size.cols,
                .rows = self.size.rows,
                .env = if (file_env) |*m| m else self.opts.env,
            }) catch |e| break :blk self.fail("App::new: {s}", .{@errorName(e)});
            self.driver = d;
            const result = self.runScript(&script);
            d.deinit();
            self.stopServers();
            break :blk result;
        };
        const leaked = if (self.opts.quiet_leak_report) blk: {
            const outstanding = dbg.total_requested_bytes != 0;
            dbg.deinitWithoutLeakChecks();
            break :blk outstanding;
        } else dbg.deinit() == .leak;
        if (leaked and outcome.passed) {
            return .{ .name = self.name, .passed = false, .message = gpa.dupe(u8, "leak: the App leaked memory (DebugAllocator reported leaks)") catch null };
        }
        return outcome;
    }

    fn runScript(self: *Run, script: *const parser.Script) Outcome {
        const asserting = self.size.eql(content_size);
        if (self.renderCycle()) |msg| return self.failMsg(msg);
        for (script.lines) |line| switch (line.stmt) {
            .step => |step| {
                if (self.runStep(step)) |msg| {
                    defer self.gpa.free(msg);
                    return self.fail("line {d}: {s}", .{ line.ln, msg });
                }
                if (self.renderCycle()) |msg| return self.failMsg(msg);
            },
            .check => |check| {
                if (self.pollCheck(check, asserting)) |msg| {
                    defer self.gpa.free(msg);
                    if (std.mem.startsWith(u8, msg, "render: ")) return self.fail("{s}", .{msg});
                    return self.fail("line {d}: {s}", .{ line.ln, msg });
                }
            },
        };
        return .{ .name = self.name, .passed = true, .message = null };
    }

    fn failMsg(self: *Run, msg: []u8) Outcome {
        return .{ .name = self.name, .passed = false, .message = msg };
    }

    /// tick → settle → expire chords → tick → draw. Returns an owned
    /// message on driver failure.
    fn renderCycle(self: *Run) ?[]u8 {
        const d = self.driver.?;
        d.tick() catch |e| return self.errMsg("render: {s}", e);
        self.sleepMs(self.opts.timing.step_settle_ms);
        d.expireChords() catch |e| return self.errMsg("render: {s}", e);
        d.tick() catch |e| return self.errMsg("render: {s}", e);
        d.render() catch |e| return self.errMsg("render: {s}", e);
        return null;
    }

    fn errMsg(self: *Run, comptime fmt: []const u8, e: anyerror) ?[]u8 {
        return std.fmt.allocPrint(self.gpa, fmt, .{@errorName(e)}) catch null;
    }

    fn sleepMs(self: *Run, ms: u64) void {
        self.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
    }

    fn nowMs(self: *Run) i64 {
        return Io.Timestamp.now(self.io, .awake).toMilliseconds();
    }

    /// A failing check is retried until the budget runs out. At a
    /// non-content size the check is evaluated once and its verdict
    /// ignored — those runs exist to prove nothing panics or leaks.
    fn pollCheck(self: *Run, check: parser.Check, asserting: bool) ?[]u8 {
        const d = self.driver.?;
        const deadline = self.nowMs() + @as(i64, @intCast(self.opts.timing.expect_budget_ms));
        while (true) {
            const screen = screen_mod.toTestText(self.gpa, d.screen()) catch return self.errMsg("render: {s}", error.OutOfMemory);
            defer self.gpa.free(screen);
            const err = self.runCheck(screen, check) orelse return null;
            if (!asserting) {
                self.gpa.free(err);
                return null;
            }
            if (self.nowMs() >= deadline) return err;
            self.gpa.free(err);
            d.tick() catch |e| return self.errMsg("render: {s}", e);
            self.sleepMs(self.opts.timing.expect_poll_ms);
            d.render() catch |e| return self.errMsg("render: {s}", e);
        }
    }

    // ── steps ──

    fn runStep(self: *Run, step: parser.Step) ?[]u8 {
        const gpa = self.gpa;
        const io = self.io;
        const d = self.driver.?;
        switch (step) {
            .write => |w| {
                if (rejectUnsafePath(gpa, w.rel, "write")) |m| return m;
                const p = std.fs.path.join(gpa, &.{ self.workspace, w.rel }) catch return null;
                defer gpa.free(p);
                if (std.fs.path.dirname(p)) |parent| {
                    Io.Dir.cwd().createDirPath(io, parent) catch |e| return self.errMsg("mkdir: {s}", e);
                }
                Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = w.content }) catch |e| {
                    return std.fmt.allocPrint(gpa, "write {s}: {s}", .{ w.rel, @errorName(e) }) catch null;
                };
            },
            .open => |rel| {
                if (rejectUnsafePath(gpa, rel, "open")) |m| return m;
                const p = std.fs.path.join(gpa, &.{ self.workspace, rel }) catch return null;
                defer gpa.free(p);
                d.open(p) catch |e| return self.errMsg("open: {s}", e);
            },
            .key => |k| d.key(k) catch |e| return self.errMsg("key: {s}", e),
            .type => |s| d.typeText(s) catch |e| return self.errMsg("type: {s}", e),
            .command => |id| d.command(id) catch |e| switch (e) {
                error.NoSuchCommand => return std.fmt.allocPrint(gpa, "no such command `{s}`", .{id}) catch null,
                else => return self.errMsg("command: {s}", e),
            },
            .ex => |line| d.ex(line) catch |e| return self.errMsg("ex: {s}", e),
            .wait => |ms| {
                // Tick throughout the sleep so async work makes progress
                // while the clock runs, then once more so anything queued
                // by the last slice is drained before the next step.
                const deadline = self.nowMs() + @as(i64, @intCast(ms));
                while (self.nowMs() < deadline) {
                    d.tick() catch |e| return self.errMsg("wait: {s}", e);
                    const remaining: u64 = @intCast(@max(deadline - self.nowMs(), 0));
                    self.sleepMs(@min(remaining, self.opts.timing.wait_slice_ms));
                }
                d.tick() catch |e| return self.errMsg("wait: {s}", e);
            },
            .snippet => |s| d.snippet(s.scope, s.trigger, s.expansion) catch |e| return self.errMsg("snippet: {s}", e),
            .shell => |cmd| return self.runShell(cmd),
            .serve => |sv| return self.serve(sv),
            .ghost => |text| d.ghost(text) catch |e| switch (e) {
                error.NoActiveEditor => return gpa.dupe(u8, "ghost: no active editor pane") catch null,
                else => return self.errMsg("ghost: {s}", e),
            },
            .mouse => |m| {
                const r = switch (m.action) {
                    .click => d.click(m.x, m.y, .left, .{}),
                    .right_click => d.click(m.x, m.y, .right, .{}),
                    .double_click => blk: {
                        d.click(m.x, m.y, .left, .{}) catch |e| break :blk e;
                        break :blk d.click(m.x, m.y, .left, .{});
                    },
                    .hover => d.mouse(.{ .x = m.x, .y = m.y, .kind = .motion }),
                    .scroll_up => d.mouse(.{ .x = m.x, .y = m.y, .kind = .scroll_up }),
                    .scroll_down => d.mouse(.{ .x = m.x, .y = m.y, .kind = .scroll_down }),
                };
                r catch |e| return self.errMsg("mouse: {s}", e);
            },
            .drag => |g| _ = d.drag(g.from_x, g.from_y, g.to_x, g.to_y) catch |e| return self.errMsg("drag: {s}", e),
        }
        return null;
    }

    /// `serve PORT STATUS [delay=MS] TEXT`: a mock server on the loopback
    /// for the rest of the file. `TEXT` is `Name: value` lines, a blank
    /// line, the body — or just the body. With a delay the body goes out
    /// as one late chunk with no length (a server that never finishes,
    /// for a timeout to trip on). The text `@echo` makes the body the
    /// request as it arrived, so a test can read what went on the wire.
    fn serve(self: *Run, sv: @FieldType(parser.Step, "serve")) ?[]u8 {
        const gpa = self.gpa;
        if (self.serve_arena == null) self.serve_arena = std.heap.ArenaAllocator.init(gpa);
        const a = self.serve_arena.?.allocator();
        const HeaderT = std.meta.Child(@FieldType(mock.Canned, "headers"));
        var headers: std.ArrayListUnmanaged(HeaderT) = .empty;
        var body: []const u8 = sv.text;
        if (std.mem.indexOf(u8, sv.text, "\n\n")) |blank| {
            body = sv.text[blank + 2 ..];
            var lines = std.mem.splitScalar(u8, sv.text[0..blank], '\n');
            while (lines.next()) |l| {
                const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
                headers.append(a, .{ .name = std.mem.trim(u8, l[0..colon], " \t"), .value = std.mem.trim(u8, l[colon + 1 ..], " \t") }) catch return null;
            }
        }
        const hs = a.dupe(HeaderT, headers.items) catch return null;
        const chunks: ?[]const []const u8 = if (sv.delay_ms > 0) (a.dupe([]const u8, &.{body}) catch return null) else null;
        const echo = std.mem.eql(u8, std.mem.trim(u8, sv.text, " \t\r\n"), "@echo");
        const canned: mock.Canned = .{ .status = sv.status, .status_text = statusText(sv.status), .headers = hs, .body = body, .chunks = chunks, .chunk_delay_ms = sv.delay_ms, .echo = echo };
        const server = mock.Server.startOn(gpa, self.io, sv.port, canned) catch |e| return std.fmt.allocPrint(gpa, "serve 127.0.0.1:{d}: {s}", .{ sv.port, @errorName(e) }) catch null;
        self.servers.append(gpa, server) catch {
            server.stop(self.io);
            return null;
        };
        return null;
    }

    fn statusText(status: u16) []const u8 {
        return switch (status) {
            200 => "OK",
            201 => "Created",
            204 => "No Content",
            301 => "Moved Permanently",
            302 => "Found",
            303 => "See Other",
            307 => "Temporary Redirect",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            418 => "I'm a teapot",
            500 => "Internal Server Error",
            else => "",
        };
    }

    fn stopServers(self: *Run) void {
        for (self.servers.items) |s| s.stop(self.io);
        self.servers.deinit(self.gpa);
        self.servers = .empty;
        if (self.serve_arena) |*ar| ar.deinit();
        self.serve_arena = null;
    }

    /// `shell <cmd>` runs unsandboxed in the user's account, so it is
    /// default-deny: a cloned repo's `.test` files must not be arbitrary
    /// code execution under `zig build test`.
    fn runShell(self: *Run, cmd: []const u8) ?[]u8 {
        const gpa = self.gpa;
        if (!self.opts.allow_shell) {
            return std.fmt.allocPrint(gpa, "shell `{s}`: refused. .test `shell` steps run unsandboxed; set MNML_E2E_ALLOW_SHELL=1 to opt in (only for trusted repos).", .{cmd}) catch null;
        }
        const result = std.process.run(gpa, self.io, .{
            .argv = &.{ self.opts.shell, "-c", cmd },
            .cwd = .{ .path = self.workspace },
        }) catch |e| return std.fmt.allocPrint(gpa, "shell spawn: {s}", .{@errorName(e)}) catch null;
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        const ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (ok) return null;
        const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
        const stdout = std.mem.trim(u8, result.stdout, " \t\r\n");
        var status_buf: [48]u8 = undefined;
        const status = switch (result.term) {
            .exited => |code| std.fmt.bufPrint(&status_buf, "exit status: {d}", .{code}) catch "",
            .signal => |sig| std.fmt.bufPrint(&status_buf, "signal: {d}", .{@intFromEnum(sig)}) catch "",
            .stopped => |sig| std.fmt.bufPrint(&status_buf, "stopped: {d}", .{@intFromEnum(sig)}) catch "",
            .unknown => |v| std.fmt.bufPrint(&status_buf, "unknown: {d}", .{v}) catch "",
        };
        return std.fmt.allocPrint(gpa, "shell `{s}` exited {s}: {s}{s}", .{ cmd, status, stderr, if (stderr.len == 0) stdout else "" }) catch null;
    }

    // ── checks ──

    fn runCheck(self: *Run, screen: []const u8, check: parser.Check) ?[]u8 {
        const gpa = self.gpa;
        const d = self.driver.?;
        switch (check) {
            .screen_contains => |want| {
                if (std.mem.indexOf(u8, screen, want) != null) return null;
                return std.fmt.allocPrint(gpa, "screen does not contain {f}\n── rendered screen ──\n{s}", .{ debug(want), screen }) catch null;
            },
            .screen_lacks => |want| {
                if (std.mem.indexOf(u8, screen, want) == null) return null;
                return std.fmt.allocPrint(gpa, "screen unexpectedly contains {f}\n── rendered screen ──\n{s}", .{ debug(want), screen }) catch null;
            },
            .dirty => |want| {
                const got = d.dirty() orelse false;
                if (got == want) return null;
                return std.fmt.allocPrint(gpa, "active editor dirty == {}, expected {}", .{ got, want }) catch null;
            },
            .pane_title => |want| {
                const title = d.paneTitle(gpa) catch null orelse {
                    return std.fmt.allocPrint(gpa, "no active pane (expected one whose title contains {f})", .{debug(want)}) catch null;
                };
                defer gpa.free(title);
                if (std.mem.indexOf(u8, title, want) != null) return null;
                return std.fmt.allocPrint(gpa, "active pane title {f} does not contain {f}", .{ debug(title), debug(want) }) catch null;
            },
            .file_contains => |f| {
                const body = switch (self.readWorkspaceFile(f.rel)) {
                    .body => |b| b,
                    .err => |m| return m,
                };
                defer gpa.free(body);
                if (std.mem.indexOf(u8, body, f.text) != null) return null;
                // The first 200 chars, so a failure reads without a rerun.
                var end: usize = 0;
                var n: usize = 0;
                while (end < body.len and n < 200) : (n += 1) end += std.unicode.utf8ByteSequenceLength(body[end]) catch 1;
                return std.fmt.allocPrint(gpa, "file {s} does not contain {f}\n    actual: {f}", .{ f.rel, debug(f.text), debug(body[0..@min(end, body.len)]) }) catch null;
            },
            .file_lacks => |f| {
                const body = switch (self.readWorkspaceFile(f.rel)) {
                    .body => |b| b,
                    .err => |m| return m,
                };
                defer gpa.free(body);
                if (std.mem.indexOf(u8, body, f.text) == null) return null;
                return std.fmt.allocPrint(gpa, "file {s} unexpectedly contains {f}", .{ f.rel, debug(f.text) }) catch null;
            },
            .highlights_at_least => |min| {
                const count = d.highlightCount() orelse return gpa.dupe(u8, "expect highlights: no active editor pane") catch null;
                if (count >= min) return null;
                return std.fmt.allocPrint(gpa, "expected ≥ {d} highlight spans, got {d} (highlighting may be broken)", .{ min, count }) catch null;
            },
        }
    }

    const ReadResult = union(enum) { body: []u8, err: ?[]u8 };

    /// The workspace file, or the message the check reports.
    fn readWorkspaceFile(self: *Run, rel: []const u8) ReadResult {
        const gpa = self.gpa;
        const p = std.fs.path.join(gpa, &.{ self.workspace, rel }) catch return .{ .err = null };
        defer gpa.free(p);
        const body = Io.Dir.cwd().readFileAlloc(self.io, p, gpa, .unlimited) catch |e| {
            return .{ .err = std.fmt.allocPrint(gpa, "can't read {s}: {s}", .{ p, @errorName(e) }) catch null };
        };
        return .{ .body = body };
    }
};

/// Script paths must stay inside the workspace: `write /etc/passwd …`
/// would land verbatim because a join short-circuits on absolute input.
fn rejectUnsafePath(gpa: Allocator, rel: []const u8, kw: []const u8) ?[]u8 {
    if (std.fs.path.isAbsolute(rel)) {
        return std.fmt.allocPrint(gpa, "{s} {s}: absolute paths are not allowed", .{ kw, rel }) catch null;
    }
    var it = std.mem.splitAny(u8, rel, "/\\");
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, "..")) {
            return std.fmt.allocPrint(gpa, "{s} {s}: `..` components are not allowed (would escape workspace)", .{ kw, rel }) catch null;
        }
    }
    return null;
}

/// `<tmp_root>/mnml-e2e-<random>`, created.
/// `mnml-e2e-` and six hex digits: fifteen characters, near the ten of
/// Rust's `tempfile::tempdir()` (`.tmpXXXXXX`) the corpus was written
/// against. The name is the statusline's workspace chip; a 41-character
/// one was 45 cells of every 120-column row, and with the now-playing
/// cluster beside it the row overflowed and clipped the mode chip
/// (`vim_gv_mode.test` read `V-LI…`) where Rust's runner never does.
pub fn makeTempDir(gpa: Allocator, io: Io, tmp_root: []const u8) ![]u8 {
    var bytes: [3]u8 = undefined;
    io.random(&bytes);
    const name = try std.fmt.allocPrint(gpa, "{s}/mnml-e2e-{s}", .{ std.mem.trimEnd(u8, tmp_root, "/"), &std.fmt.bytesToHex(bytes, .lower) });
    errdefer gpa.free(name);
    try Io.Dir.cwd().createDirPath(io, name);
    return name;
}

/// Rust `{:?}` for a string: quoted, with `" \ \n \r \t` escaped and other
/// controls as `\u{X}`.
const Debug = struct {
    s: []const u8,
    pub fn format(self: Debug, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeByte('"');
        for (self.s) |c| switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => if (c < 0x20 or c == 0x7f) try w.print("\\u{{{x}}}", .{c}) else try w.writeByte(c),
        };
        try w.writeByte('"');
    }
};

fn debug(s: []const u8) Debug {
    return .{ .s = s };
}

// ─── a file under a deadline ────────────────────────────────────────────

const Job = struct {
    gpa: Allocator,
    io: Io,
    factory: Factory,
    path: []const u8,
    size: Size,
    opts: Options,
    outcome: Outcome = undefined,
    done: Io.Event = .unset,
    /// Who owns the job once the file finishes: whichever side moves
    /// this off `running` first. `finished` — the caller takes the
    /// outcome; `abandoned` — the worker frees everything itself.
    state: std.atomic.Value(State) = .init(.running),

    const State = enum(u8) { running, finished, abandoned };

    fn work(job: *Job) void {
        var outcome = runFile(job.gpa, job.io, job.factory, job.path, job.size, job.opts);
        if (job.state.cmpxchgStrong(.running, .finished, .acq_rel, .acquire) == null) {
            job.outcome = outcome;
            job.done.set(job.io);
        } else {
            outcome.deinit(job.gpa);
            std.heap.page_allocator.destroy(job);
        }
    }
};

/// `runFile` on a worker thread with a wall-clock deadline. On timeout the
/// worker is abandoned (it dies with the process) and a failing outcome
/// is synthesized so the suite keeps going.
pub fn runFileWithTimeout(gpa: Allocator, io: Io, factory: Factory, path: []const u8, size: Size, opts: Options) Outcome {
    // The job outlives this call when abandoned, so it cannot come from
    // the leak-checked gpa: page_allocator, and deliberately never freed
    // on the timeout path.
    const job = std.heap.page_allocator.create(Job) catch return runFile(gpa, io, factory, path, size, opts);
    job.* = .{ .gpa = gpa, .io = io, .factory = factory, .path = path, .size = size, .opts = opts };
    const thread = std.Thread.spawn(.{}, Job.work, .{job}) catch {
        std.heap.page_allocator.destroy(job);
        return runFile(gpa, io, factory, path, size, opts);
    };
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(@intCast(opts.file_timeout_secs)), .clock = .awake } };
    const timed_out = if (job.done.waitTimeout(io, timeout)) |_| false else |_| job.state.cmpxchgStrong(.running, .abandoned, .acq_rel, .acquire) == null;
    if (!timed_out) {
        // Either the file finished in time, or it finished in the instant
        // between the timeout and the hand-off; both are the worker's outcome.
        thread.join();
        const outcome = job.outcome;
        std.heap.page_allocator.destroy(job);
        return outcome;
    } else {
        thread.detach();
        const name = outcomeName(gpa, path, size) catch @constCast("");
        return .{
            .name = name,
            .passed = false,
            .message = std.fmt.allocPrint(gpa, "TIMEOUT after {d}s (worker abandoned — a step never returned; override via MNML_E2E_FILE_TIMEOUT_SECS)", .{opts.file_timeout_secs}) catch null,
        };
    }
}

// ─── a path ─────────────────────────────────────────────────────────────

/// Every `*.test` under `root` (recursively, hidden entries skipped,
/// sorted), or `root` itself when it is a file. Owned paths.
pub fn collectFiles(gpa: Allocator, io: Io, root: []const u8) Allocator.Error![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    const st = Io.Dir.cwd().statFile(io, root, .{}) catch return out.toOwnedSlice(gpa);
    if (st.kind != .directory) {
        try out.append(gpa, try gpa.dupe(u8, root));
        return out.toOwnedSlice(gpa);
    }
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return out.toOwnedSlice(gpa);
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.basename.len > 0 and entry.basename[0] == '.') continue;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".test")) continue;
        try out.append(gpa, try std.fs.path.join(gpa, &.{ root, entry.path }));
    }
    std.mem.sort([]u8, out.items, {}, lessThan);
    return out.toOwnedSlice(gpa);
}

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Run a root, reporting as Rust `mnml test` does: `▶ e2e: <name>` before
/// each file, `⊘ e2e SKIP …` for gated files, then one `  ok   <name>` /
/// `  FAIL <name> — <message>` per outcome.
pub fn runPath(gpa: Allocator, io: Io, factory: Factory, root: []const u8, opts: Options, out: *Io.Writer) !Stats {
    const files = try collectFiles(gpa, io, root);
    defer {
        for (files) |p| gpa.free(p);
        gpa.free(files);
    }
    if (files.len == 0) {
        try out.print("mnml-zig test: no .test files under {s}\n", .{root});
        try out.flush();
    }
    var outcomes: std.ArrayList(Outcome) = .empty;
    defer {
        for (outcomes.items) |*o| o.deinit(gpa);
        outcomes.deinit(gpa);
    }
    for (files) |path| {
        const stem = stemOf(path);
        if (opts.name_filter) |f| if (std.mem.indexOf(u8, stem, f) == null) continue;
        var skipped = false;
        for (opts.skip) |s| skipped = skipped or std.mem.eql(u8, s, stem);
        if (skipped) {
            try out.print("⊘ e2e SKIP (--skip): {s}\n", .{path});
            try out.flush();
            continue;
        }
        const header = readHeader(gpa, io, path);
        if (header.requires_network and !opts.network) {
            try out.print("⊘ e2e SKIP (network opt-in): {s}\n", .{path});
            try out.flush();
            continue;
        }
        var one: [1]Size = undefined;
        const sizes: []const Size = if (header.width) |w| blk: {
            one[0] = .{ .cols = w, .rows = content_size.rows };
            break :blk &one;
        } else opts.sizes;
        for (sizes) |size| {
            try out.print("▶ e2e: {s}\n", .{std.fs.path.basename(path)});
            try out.flush();
            try outcomes.append(gpa, runFileWithTimeout(gpa, io, factory, path, size, opts));
        }
    }
    var stats: Stats = .{};
    for (outcomes.items) |o| {
        stats.total += 1;
        if (o.passed) {
            try out.print("  ok   {s}\n", .{o.name});
        } else {
            stats.failed += 1;
            try out.print("  FAIL {s} — {s}\n", .{ o.name, o.message orelse "" });
        }
    }
    try out.flush();
    return stats;
}

fn readHeader(gpa: Allocator, io: Io, path: []const u8) parser.Header {
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch return .{};
    defer gpa.free(text);
    return parser.parseHeader(text);
}

/// Run several roots and print the `N/M passed` trailer. Returns the
/// number of failures — the exit status is 1 when it is not zero.
pub fn runPaths(gpa: Allocator, io: Io, factory: Factory, roots: []const []const u8, opts: Options, out: *Io.Writer) !Stats {
    var total: Stats = .{};
    for (roots) |root| {
        const s = try runPath(gpa, io, factory, root, opts, out);
        total.total += s.total;
        total.failed += s.failed;
    }
    try out.print("\n{d}/{d} passed\n", .{ total.total - total.failed, total.total });
    try out.flush();
    return total;
}

/// `$NAME` / `${NAME}` in `text` from `env`; an unset name is empty. Owned.
pub fn expandEnv(gpa: Allocator, text: []const u8, env: *const std.process.Environ.Map) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '$' and i + 1 < text.len) {
            const braced = text[i + 1] == '{';
            const start = if (braced) i + 2 else i + 1;
            var end = start;
            while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
            const name = text[start..end];
            const closed = !braced or (end < text.len and text[end] == '}');
            if (name.len > 0 and closed) {
                if (env.get(name)) |v| try out.appendSlice(gpa, v);
                i = if (braced) end + 1 else end;
                continue;
            }
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

test "expandEnv: a name and a braced name from the map, an unset name is empty, a lone dollar stays" {
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try env.put("MNML_SHIMS", "/s");
    try env.put("PATH", "/usr/bin");
    const v = try expandEnv(t.allocator, "${MNML_SHIMS}:$PATH:${NOPE}:$ 5", &env);
    defer t.allocator.free(v);
    try t.expectEqualStrings("/s:/usr/bin::$ 5", v);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const StubFactory = driver_mod.StubFactory;

const fast: Timing = .{ .step_settle_ms = 1, .expect_budget_ms = 60, .expect_poll_ms = 5, .wait_slice_ms = 2 };

const TestEnv = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    data_root: []u8,

    fn init() !TestEnv {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &buf);
        const root = try t.allocator.dupe(u8, buf[0..n]);
        errdefer t.allocator.free(root);
        const data_root = try std.fs.path.join(t.allocator, &.{ root, "data" });
        return .{ .tmp = tmp, .root = root, .data_root = data_root };
    }

    fn deinit(self: *TestEnv) void {
        t.allocator.free(self.data_root);
        t.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn opts(self: *const TestEnv) Options {
        return .{ .tmp_root = self.root, .data_root = self.data_root, .timing = fast, .file_timeout_secs = 5, .quiet_leak_report = true };
    }

    fn script(self: *TestEnv, name: []const u8, src: []const u8) ![]u8 {
        try self.tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = src });
        return std.fs.path.join(t.allocator, &.{ self.root, name });
    }
};

fn expectPassed(o: *Outcome) !void {
    defer o.deinit(t.allocator);
    if (!o.passed) {
        std.debug.print("unexpected FAIL {s} — {s}\n", .{ o.name, o.message orelse "" });
        return error.TestUnexpectedResult;
    }
}

fn expectFailed(o: *Outcome, want_msg: []const u8) !void {
    defer o.deinit(t.allocator);
    try t.expect(!o.passed);
    try t.expectEqualStrings(want_msg, o.message orelse "");
}

test "shipped defaults: 120×40, 50 ms settle, 3 s expect budget at 40 ms, 25 ms wait slices, 120 s timeout, shell refused" {
    const o: Options = .{ .data_root = "" };
    try t.expectEqual(@as(u16, 120), content_size.cols);
    try t.expectEqual(@as(u16, 40), content_size.rows);
    try t.expectEqual(@as(usize, 1), o.sizes.len);
    try t.expect(o.sizes[0].eql(content_size));
    try t.expectEqual(@as(u64, 50), o.timing.step_settle_ms);
    try t.expectEqual(@as(u64, 3000), o.timing.expect_budget_ms);
    try t.expectEqual(@as(u64, 40), o.timing.expect_poll_ms);
    try t.expectEqual(@as(u64, 25), o.timing.wait_slice_ms);
    try t.expectEqual(@as(u64, 120), o.file_timeout_secs);
    try t.expect(!o.allow_shell);
    try t.expect(!o.network);
}

test "a passing script: every step is followed by tick/settle/expire/tick/render" {
    var env = try TestEnv.init();
    defer env.deinit();
    const path = try env.script("a.test", "write notes.txt first line\nopen notes.txt\nexpect screen contains \"first line\"\ntype \"T\"\nkey ctrl+s\nexpect dirty false\nexpect pane notes.txt\n");
    defer t.allocator.free(path);
    var sf: StubFactory = .{ .proto = .{ .text = "row0\nfirst line here", .dirty = false, .title = "notes.txt" } };
    var o = runFile(t.allocator, t.io, sf.factory(), path, content_size, env.opts());
    try expectPassed(&o);
    try t.expectEqual(@as(usize, 1), sf.made);
}

test "the step order and the driver calls are exactly the Rust runner's" {
    var env = try TestEnv.init();
    defer env.deinit();
    const path = try env.script("b.test", "open a.txt\nkey ctrl+s\n");
    defer t.allocator.free(path);
    // Keep the stub alive past the run to read its call log: a factory
    // that records into a caller-owned stub.
    const Keep = struct {
        stub: driver_mod.Stub,
        fn create(p: *anyopaque, _: Allocator, _: Io, _: driver_mod.Config) anyerror!Driver {
            const self: *@This() = @ptrCast(@alignCast(p));
            return .{ .ptr = &self.stub, .vtable = &noDeinit };
        }
        const noDeinit: Driver.VTable = blk: {
            var v = @as(*const Driver.VTable, driver_mod.Stub.vtablePtr()).*;
            v.deinit = struct {
                fn f(_: *anyopaque) void {}
            }.f;
            break :blk v;
        };
    };
    var keep: Keep = .{ .stub = try driver_mod.Stub.init(t.allocator, 120, 40) };
    defer keep.stub.deinit();
    keep.stub.text = "";
    var o = runFile(t.allocator, t.io, .{ .ptr = &keep, .create = Keep.create }, path, content_size, env.opts());
    try expectPassed(&o);
    const calls = try keep.stub.callsJoined(t.allocator);
    defer t.allocator.free(calls);
    const ws_open = std.mem.indexOf(u8, calls, "open ").?;
    const open_line_end = std.mem.indexOfScalarPos(u8, calls, ws_open, '\n').?;
    try t.expect(std.mem.endsWith(u8, calls[ws_open..open_line_end], "/a.txt"));
    try t.expect(std.mem.indexOf(u8, calls[ws_open..open_line_end], "mnml-e2e-") != null);
    const before = calls[0..ws_open];
    const after = calls[open_line_end + 1 ..];
    try t.expectEqualStrings("tick\nexpire\ntick\nrender\n", before);
    try t.expectEqualStrings("tick\nexpire\ntick\nrender\nkey ctrl+s\ntick\nexpire\ntick\nrender", after);
}

test "an expectation is polled until the screen catches up, and reports the screen when it never does" {
    var env = try TestEnv.init();
    defer env.deinit();
    const path = try env.script("c.test", "open a.txt\nexpect screen contains late\n");
    defer t.allocator.free(path);
    // Two renders happen before the check (initial + post-step); the third
    // render — the first poll retry — reveals the text.
    var sf: StubFactory = .{ .proto = .{ .text = "early", .late_after = 2, .late_text = "late" } };
    var o = runFile(t.allocator, t.io, sf.factory(), path, content_size, env.opts());
    try expectPassed(&o);
    try t.expect(sf.stats.renders >= 3);

    var never: StubFactory = .{ .proto = .{ .text = "early" } };
    var o2 = runFile(t.allocator, t.io, never.factory(), path, content_size, env.opts());
    defer o2.deinit(t.allocator);
    try t.expect(!o2.passed);
    try t.expect(std.mem.startsWith(u8, o2.message.?, "line 2: screen does not contain \"late\"\n── rendered screen ──\nearly"));
    // Polled: more than the two baseline renders happened before giving up.
    try t.expect(never.stats.renders > 2);
}

test "every check kind and its failure message" {
    var env = try TestEnv.init();
    defer env.deinit();
    const Case = struct { src: []const u8, proto: driver_mod.Stub.Proto, msg: ?[]const u8, prefix: bool = false };
    const cases = [_]Case{
        // The screen dump that follows is the whole 120×40 grid.
        .{ .src = "expect screen lacks gone\n", .proto = .{ .text = "all gone" }, .msg = "line 1: screen unexpectedly contains \"gone\"\n── rendered screen ──\nall gone ", .prefix = true },
        .{ .src = "expect dirty true\n", .proto = .{ .dirty = false }, .msg = "line 1: active editor dirty == false, expected true" },
        .{ .src = "expect dirty false\n", .proto = .{ .dirty = null }, .msg = null },
        .{ .src = "expect pane x.rs\n", .proto = .{ .title = "y.rs" }, .msg = "line 1: active pane title \"y.rs\" does not contain \"x.rs\"" },
        .{ .src = "expect pane x.rs\n", .proto = .{ .title = null }, .msg = "line 1: no active pane (expected one whose title contains \"x.rs\")" },
        .{ .src = "expect highlights at_least 3\n", .proto = .{ .highlights = 2 }, .msg = "line 1: expected ≥ 3 highlight spans, got 2 (highlighting may be broken)" },
        .{ .src = "expect highlights at_least 3\n", .proto = .{ .highlights = null }, .msg = "line 1: expect highlights: no active editor pane" },
        .{ .src = "expect highlights at_least 3\n", .proto = .{ .highlights = 3 }, .msg = null },
        .{ .src = "write out.txt \"a\\nb\"\nexpect file out.txt contains b\nexpect file out.txt lacks z\n", .proto = .{}, .msg = null },
        .{ .src = "write out.txt hello\nexpect file out.txt contains \"bye\"\n", .proto = .{}, .msg = "line 2: file out.txt does not contain \"bye\"\n    actual: \"hello\"" },
        .{ .src = "write out.txt hello\nexpect file out.txt lacks ell\n", .proto = .{}, .msg = "line 2: file out.txt unexpectedly contains \"ell\"" },
    };
    for (cases, 0..) |c, i| {
        var name_buf: [16]u8 = undefined;
        const path = try env.script(try std.fmt.bufPrint(&name_buf, "k{d}.test", .{i}), c.src);
        defer t.allocator.free(path);
        var sf: StubFactory = .{ .proto = c.proto };
        var o = runFile(t.allocator, t.io, sf.factory(), path, content_size, env.opts());
        if (c.msg) |m| {
            if (c.prefix) {
                defer o.deinit(t.allocator);
                try t.expect(!o.passed);
                try t.expect(std.mem.startsWith(u8, o.message orelse "", m));
            } else try expectFailed(&o, m);
        } else try expectPassed(&o);
    }
}

test "a missing file's expect file names the path" {
    var env = try TestEnv.init();
    defer env.deinit();
    const path = try env.script("m.test", "expect file nope.txt contains x\n");
    defer t.allocator.free(path);
    var sf: StubFactory = .{};
    var o = runFile(t.allocator, t.io, sf.factory(), path, content_size, env.opts());
    defer o.deinit(t.allocator);
    try t.expect(!o.passed);
    try t.expect(std.mem.startsWith(u8, o.message.?, "line 1: can't read "));
    try t.expect(std.mem.endsWith(u8, o.message.?, "/nope.txt: FileNotFound"));
}

test "step failures: unknown command, ghost without an editor, unsafe paths, refused shell" {
    var env = try TestEnv.init();
    defer env.deinit();
    const Case = struct { src: []const u8, msg: []const u8 };
    const cases = [_]Case{
        .{ .src = "command nope.nope\n", .msg = "line 1: no such command `nope.nope`" },
        .{ .src = "ghost hi\n", .msg = "line 1: ghost: no active editor pane" },
        .{ .src = "write /etc/passwd x\n", .msg = "line 1: write /etc/passwd: absolute paths are not allowed" },
        .{ .src = "open ../../x\n", .msg = "line 1: open ../../x: `..` components are not allowed (would escape workspace)" },
        .{ .src = "write a/../b x\n", .msg = "line 1: write a/../b: `..` components are not allowed (would escape workspace)" },
        .{ .src = "shell true\n", .msg = "line 1: shell `true`: refused. .test `shell` steps run unsandboxed; set MNML_E2E_ALLOW_SHELL=1 to opt in (only for trusted repos)." },
    };
    for (cases, 0..) |c, i| {
        var name_buf: [16]u8 = undefined;
        const path = try env.script(try std.fmt.bufPrint(&name_buf, "s{d}.test", .{i}), c.src);
        defer t.allocator.free(path);
        var sf: StubFactory = .{ .proto = .{ .has_editor = false, .known_commands = &.{"editor.use_vim"} } };
        var o = runFile(t.allocator, t.io, sf.factory(), path, content_size, env.opts());
        try expectFailed(&o, c.msg);
    }
}

test "shell steps run in the workspace when allowed, and a non-zero exit fails with stderr" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var env = try TestEnv.init();
    defer env.deinit();
    var opts = env.opts();
    opts.allow_shell = true;
    const ok_path = try env.script("sh1.test", "shell printf hi > made.txt\nexpect file made.txt contains hi\n");
    defer t.allocator.free(ok_path);
    var sf: StubFactory = .{};
    var o = runFile(t.allocator, t.io, sf.factory(), ok_path, content_size, opts);
    try expectPassed(&o);

    const bad_path = try env.script("sh2.test", "shell echo oops >&2; exit 3\n");
    defer t.allocator.free(bad_path);
    var o2 = runFile(t.allocator, t.io, sf.factory(), bad_path, content_size, opts);
    try expectFailed(&o2, "line 1: shell `echo oops >&2; exit 3` exited exit status: 3: oops");
}

test "parse errors and unreadable files are outcomes, never panics" {
    var env = try TestEnv.init();
    defer env.deinit();
    const path = try env.script("p.test", "open a\nfrob\n");
    defer t.allocator.free(path);
    var sf: StubFactory = .{};
    var o = runFile(t.allocator, t.io, sf.factory(), path, content_size, env.opts());
    try expectFailed(&o, "line 2: unknown statement `frob`");
    var o2 = runFile(t.allocator, t.io, sf.factory(), "/nonexistent/x.test", content_size, env.opts());
    try t.expectEqualStrings("x.test", o2.name);
    try expectFailed(&o2, "can't read: FileNotFound");
}

test "wait ticks the driver while the clock runs" {
    var env = try TestEnv.init();
    defer env.deinit();
    const path = try env.script("w.test", "wait 30\n");
    defer t.allocator.free(path);
    var sf: StubFactory = .{};
    var o = runFile(t.allocator, t.io, sf.factory(), path, content_size, env.opts());
    try expectPassed(&o);
    // 30 ms in 2 ms slices: many ticks beyond the render cycles' four.
    try t.expect(sf.stats.ticks > 8);
}

test "a leaking App fails the file" {
    var env = try TestEnv.init();
    defer env.deinit();
    const path = try env.script("l.test", "wait 1\n");
    defer t.allocator.free(path);
    const Leaky = struct {
        fn create(_: *anyopaque, gpa: Allocator, _: Io, cfg: driver_mod.Config) anyerror!Driver {
            const s = try gpa.create(driver_mod.Stub);
            s.* = try driver_mod.Stub.init(gpa, cfg.cols, cfg.rows);
            _ = try gpa.alloc(u8, 16); // never freed
            return s.driver();
        }
    };
    var dummy: u8 = 0;
    var o = runFile(t.allocator, t.io, .{ .ptr = &dummy, .create = Leaky.create }, path, content_size, env.opts());
    try expectFailed(&o, "leak: the App leaked memory (DebugAllocator reported leaks)");
}

test "a hung file times out, is abandoned, and the suite continues" {
    var env = try TestEnv.init();
    defer env.deinit();
    const path = try env.script("h.test", "wait 1\n");
    defer t.allocator.free(path);
    const Hang = struct {
        var finished: Io.Event = .unset;
        var hung_once = false;
        fn create(_: *anyopaque, gpa: Allocator, _: Io, cfg: driver_mod.Config) anyerror!Driver {
            const s = try gpa.create(driver_mod.Stub);
            s.* = try driver_mod.Stub.init(gpa, cfg.cols, cfg.rows);
            return .{ .ptr = s, .vtable = &hung };
        }
        const hung: Driver.VTable = blk: {
            var v = @as(*const Driver.VTable, driver_mod.Stub.vtablePtr()).*;
            v.tick = struct {
                fn f(_: *anyopaque) driver_mod.Error!void {
                    // The first tick outlives the deadline; later ones return.
                    if (hung_once) return;
                    hung_once = true;
                    std.testing.io.sleep(.fromMilliseconds(2500), .awake) catch {};
                }
            }.f;
            v.deinit = struct {
                fn f(p: *anyopaque) void {
                    driver_mod.Stub.vtablePtr().deinit(p);
                    finished.set(std.testing.io);
                }
            }.f;
            break :blk v;
        };
    };
    var dummy: u8 = 0;
    var opts = env.opts();
    opts.file_timeout_secs = 1;
    var o = runFileWithTimeout(t.allocator, t.io, .{ .ptr = &dummy, .create = Hang.create }, path, content_size, opts);
    try expectFailed(&o, "TIMEOUT after 1s (worker abandoned — a step never returned; override via MNML_E2E_FILE_TIMEOUT_SECS)");
    // Let the abandoned worker finish and free its own outcome before the
    // test allocator checks for leaks.
    try Hang.finished.wait(std.testing.io);
    std.testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
}

test "runPath: skips, sizes, names, and the ok/FAIL/N-M report" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.tmp.dir.createDirPath(t.io, "suite/sub");
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "suite/b_pass.test", .data = "expect screen contains ok\n" });
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "suite/a_fail.test", .data = "expect screen contains nope\n" });
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "suite/sub/c_net.test", .data = "# requires: network\nexpect screen contains x\n" });
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "suite/sub/e_wide.test", .data = "# width: 80\nexpect screen contains nope\n" });
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "suite/.hidden.test", .data = "expect screen contains nope\n" });
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "suite/notes.txt", .data = "not a test\n" });
    const root = try std.fs.path.join(t.allocator, &.{ env.root, "suite" });
    defer t.allocator.free(root);

    var sf: StubFactory = .{ .proto = .{ .text = "ok" } };
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var opts = env.opts();
    opts.sizes = &.{ content_size, .{ .cols = 80, .rows = 24 } };
    const stats = try runPaths(t.allocator, t.io, sf.factory(), &.{root}, opts, &out.writer);
    try t.expectEqual(@as(usize, 5), stats.total);
    try t.expectEqual(@as(usize, 1), stats.failed);
    const report = out.written();
    // Sorted by path; a hidden file and a non-.test file are ignored; the
    // width header pins e_wide to 80 columns where the miss is not asserted.
    const expected =
        "▶ e2e: a_fail.test\n▶ e2e: a_fail.test\n▶ e2e: b_pass.test\n▶ e2e: b_pass.test\n" ++
        "⊘ e2e SKIP (network opt-in): " ++ "SUITE/sub/c_net.test\n" ++
        "▶ e2e: e_wide.test\n" ++
        "  FAIL a_fail.test — line 1: screen does not contain \"nope\"\n── rendered screen ──\n" ++ "SCREEN" ++
        "\n  ok   a_fail.test @80x24\n  ok   b_pass.test\n  ok   b_pass.test @80x24\n  ok   e_wide.test @80x40\n\n4/5 passed\n";
    // Compare piecewise around the parts that carry paths / the screen dump.
    const head = std.mem.indexOf(u8, expected, "SUITE").?;
    try t.expectEqualStrings(expected[0..head], report[0..head]);
    try t.expect(std.mem.indexOf(u8, report, "⊘ e2e SKIP (network opt-in): ") != null);
    try t.expect(std.mem.indexOf(u8, report, "/suite/sub/c_net.test\n") != null);
    try t.expect(std.mem.indexOf(u8, report, "▶ e2e: e_wide.test\n  FAIL a_fail.test — line 1: screen does not contain \"nope\"\n── rendered screen ──\nok") != null);
    try t.expect(std.mem.endsWith(u8, report, "\n  ok   a_fail.test @80x24\n  ok   b_pass.test\n  ok   b_pass.test @80x24\n  ok   e_wide.test @80x40\n\n4/5 passed\n"));
    try t.expectEqual(@as(usize, 5), sf.made);

    // A network-opted-in run includes the gated file.
    var out2: Io.Writer.Allocating = .init(t.allocator);
    defer out2.deinit();
    opts.network = true;
    opts.sizes = &.{content_size};
    const s2 = try runPaths(t.allocator, t.io, sf.factory(), &.{root}, opts, &out2.writer);
    try t.expectEqual(@as(usize, 4), s2.total);
    try t.expect(std.mem.indexOf(u8, out2.written(), "  FAIL c_net.test — ") != null);
}

test "runPath: --filter keeps the matching names silently, --skip announces the cut" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.tmp.dir.createDirPath(t.io, "suite");
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "suite/alpha_one.test", .data = "expect screen contains ok\n" });
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "suite/alpha_two.test", .data = "expect screen contains nope\n" });
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "suite/beta.test", .data = "expect screen contains ok\n" });
    const root = try std.fs.path.join(t.allocator, &.{ env.root, "suite" });
    defer t.allocator.free(root);
    var sf: StubFactory = .{ .proto = .{ .text = "ok" } };
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var opts = env.opts();
    opts.name_filter = "alpha";
    opts.skip = &.{"alpha_two"};
    const s = try runPath(t.allocator, t.io, sf.factory(), root, opts, &out.writer);
    try t.expectEqual(@as(usize, 1), s.total);
    try t.expectEqual(@as(usize, 0), s.failed);
    const skip_line = try std.fmt.allocPrint(t.allocator, "\u{2298} e2e SKIP (--skip): {s}/alpha_two.test\n", .{root});
    defer t.allocator.free(skip_line);
    const expected = try std.mem.concat(t.allocator, u8, &.{ "\u{25b6} e2e: alpha_one.test\n", skip_line, "  ok   alpha_one.test\n" });
    defer t.allocator.free(expected);
    try t.expectEqualStrings(expected, out.written());
    try t.expectEqualStrings("alpha_one", stemOf("/x/alpha_one.test"));
    try t.expectEqualStrings("notes", stemOf("notes"));
}

test "runPath on a single file and on an empty directory" {
    var env = try TestEnv.init();
    defer env.deinit();
    const path = try env.script("one.test", "expect screen contains ok\n");
    defer t.allocator.free(path);
    var sf: StubFactory = .{ .proto = .{ .text = "ok" } };
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    const s = try runPath(t.allocator, t.io, sf.factory(), path, env.opts(), &out.writer);
    try t.expectEqual(@as(usize, 1), s.total);
    try t.expectEqualStrings("▶ e2e: one.test\n  ok   one.test\n", out.written());

    try env.tmp.dir.createDirPath(t.io, "empty");
    const empty = try std.fs.path.join(t.allocator, &.{ env.root, "empty" });
    defer t.allocator.free(empty);
    var out2: Io.Writer.Allocating = .init(t.allocator);
    defer out2.deinit();
    const s2 = try runPath(t.allocator, t.io, sf.factory(), empty, env.opts(), &out2.writer);
    try t.expectEqual(@as(usize, 0), s2.total);
    try t.expect(std.mem.startsWith(u8, out2.written(), "mnml-zig test: no .test files under "));
}

test "debug quoting matches Rust's {:?} for the characters that appear in scripts" {
    var a: Io.Writer.Allocating = .init(t.allocator);
    defer a.deinit();
    try a.writer.print("{f}", .{debug("a\"b\\c\nd\te\x01")});
    try t.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\u{1}\"", a.written());
}
