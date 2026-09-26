//! Runs `.test` scripts against a `Driver`. The oracle for the port: the
//! same files drive Rust mnml, so every timing and every message here is
//! the one that runner uses.
//!
//! Per file: a fresh temp workspace, a fresh data root, a driver on its
//! own leak-checking allocator, a fixed 120×40 screen. The data root is
//! per file because it is what persists — an integration a file installs
//! and does not uninstall used to stay installed for every later file,
//! so one file skipping a step under load turned into six unrelated
//! failures. A file that genuinely wants the run's shared root says
//! `# shared-data-root`. Every step is followed by a render
//! cycle — tick, 50 ms, expire any pending chord chain, tick, draw — so
//! async work started by the step has a chance to land before the next
//! statement. An expectation that fails is retried every 40 ms for up to
//! 3 s (a tick and a draw between tries) before it counts. `wait <ms>`
//! ticks every 25 ms while the clock runs so background work progresses.
//!
//! Once the App asks to quit (`status.json`'s `quit`), the runner stops
//! stepping it: no more ticks, no more frames. It used to keep drawing,
//! so a failure after the quit showed a session that was already over
//! and only `status.json` told the truth. A script that ends in a quit
//! says `expect quit true`; a step or a screen check after one fails
//! with `app has quit`.
//!
//! A file runs on its own thread under a wall-clock deadline (120 s,
//! `MNML_E2E_FILE_TIMEOUT_SECS`); on timeout the thread is abandoned and
//! the suite continues. Leaked memory fails the file.
//!
//! Both of those figures are the SHIPPED build's, and an unoptimized one
//! runs the app an order of magnitude slower — so they are multiplied by
//! `debug_slowdown` there. Without that, the corpus passed 668/668
//! against ReleaseSafe and failed its four heaviest files against Debug,
//! which is what `zig build e2e` produces by default.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parser = @import("parser.zig");
const mock = @import("../http/mock.zig");
const child_os = @import("../core/child.zig");
const driver_mod = @import("driver.zig");
const key = @import("../core/key.zig");
const screen_mod = @import("../ipc/screen.zig");
const ipc_command = @import("../ipc/command.zig");
const build_options = @import("build_options");

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

/// `--sizes ladder`: the widths where mnml's chrome is known to change
/// shape, so a sweep brackets every breakpoint instead of the two ends.
/// Each rung is here because something switches form at or near it:
///
///   80x24    the smallest terminal anyone runs. The dock's labels are
///            gone, the menu bar is down to `»`, the sidebar is at its
///            floor.
///   100x30   between the two: the menu bar has started to overflow but
///            the dock still has room for its counts.
///   120x40   the corpus size. Every `.test` content assertion was
///            written here, so a difference at this rung is a real
///            regression rather than a reflow.
///   135x42   the Bitbucket PR row swaps its icons for labelled buttons
///            around here; the settings strip leaves its initials form.
///   160x48   wide enough for the full menu word list and the right
///            panel at once — where two-column layouts first fit.
///   200x60   the widest sweep size the gate already uses. Nothing
///            should be clipped; anything that still is, is a bug in the
///            layout rather than in the space it was given.
///
/// A size-only bug hides between two rungs, which is the whole reason
/// the list is not just its ends (`docs/DRIVE.md`, "the ladder").
pub const ladder: []const Size = &.{
    .{ .cols = 80, .rows = 24 },
    .{ .cols = 100, .rows = 30 },
    .{ .cols = 120, .rows = 40 },
    .{ .cols = 135, .rows = 42 },
    .{ .cols = 160, .rows = 48 },
    .{ .cols = 200, .rows = 60 },
};

/// How much slower this build is at the work the wall-clock budgets
/// below are waiting on — 1 for the shipped build, more for a Debug
/// one. Set in `build.zig`, where the reasoning lives. The script
/// budget (`src/scripting/lua.zig`) moves with the build for the same
/// reason but not by this factor: there the Debug figure stops being a
/// frame budget at all, so it is stated on its own terms.
pub const debug_slowdown: u64 = build_options.debug_slowdown;

/// The wall clock one file gets by default, and what
/// `MNML_E2E_FILE_TIMEOUT_SECS` overrides. Scaled with the build for the
/// same reason the expect budget is — a file whose every expectation now
/// waits twenty times as long must not be cut off by a deadline that did
/// not move — but capped, because this one is also the guard against a
/// WEDGED file, and a wedge has to be abandoned in minutes rather than in
/// half an hour.
pub const default_file_timeout_secs: u64 = @min(120 * debug_slowdown, 600);

pub const Timing = struct {
    /// Sleep inside every post-step render cycle. Not scaled: it is a
    /// settle, not a deadline — the retry below is what waits.
    step_settle_ms: u64 = 50,
    /// How long a failing expectation is retried.
    expect_budget_ms: u64 = 3000 * debug_slowdown,
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
    /// The wall clock one file gets (`default_file_timeout_secs`).
    file_timeout_secs: u64 = default_file_timeout_secs,
    /// While a file is in flight, every this many seconds the runner
    /// prints `⏳ <name> still running (Ns)` with the process's children,
    /// so a long file is distinguishable from a wedged one before the
    /// timeout fires (`MNML_E2E_HEARTBEAT_SECS`; 0 = off).
    heartbeat_secs: u64 = 60,
    /// Screen sizes to SWEEP each file at. A sweep exists to prove
    /// nothing panics or leaks at an unusual size, so its assertions
    /// count only at `content_size`: a file written for 120×40 says
    /// things about 120×40. A rung where they did not count is reported
    /// as `ok*  <name> (structure only)`, never as plain `ok` — the same
    /// word for both is what let a green sweep read as "the chrome is
    /// fine at 376x92" when it meant "nothing crashed".
    sizes: []const Size = &.{content_size},
    /// The size came from the file's own `# width:` / `# height:`
    /// rather than from the sweep. Then it is the size the file was
    /// WRITTEN at, and its assertions count THERE — a `# width: 80`
    /// script whose every check is ignored is a script that proves
    /// nothing while reading green.
    sized_by_file: bool = false,
    /// The file said `# sizes: all`: its assertions are size-independent
    /// and count at every rung of the sweep, not only at `content_size`.
    assert_every_size: bool = false,
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
    /// A file that fails is run once more; one that passes then is
    /// reported `FLAKY` — on its own line as it happens and again in
    /// the trailer — and does not fail the run. `mnml-zig test` turns
    /// this on unless `--strict`; off here, so the library's own
    /// callers see every failure as a failure.
    retry_flaky: bool = false,
    /// `mnml-zig test`'s `git` guard (`installGitGuard`): every `git` a
    /// file's App or `shell` steps run goes through it, and one whose
    /// repository is outside the run's temp root fails the file.
    git_guard: ?GitGuard = null,
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
    /// Were this run's content assertions actually evaluated? False at a
    /// sweep rung that is not the file's own size — there the run proves
    /// no panic, no leak and no rect outside its parent, and nothing
    /// about what was on the screen. The report says `ok*` and
    /// `(structure only)` for those, so a pass names what it earned.
    asserted: bool = true,

    pub fn deinit(self: *Outcome, gpa: Allocator) void {
        gpa.free(self.name);
        if (self.message) |m| gpa.free(m);
        self.* = undefined;
    }
};

pub const Stats = struct {
    total: usize = 0,
    failed: usize = 0,
    /// Runs whose content assertions were NOT evaluated (a sweep rung
    /// other than the file's own size). `total - structure_only` is how
    /// many runs actually checked what was on the screen.
    structure_only: usize = 0,
    /// Runs that failed, were retried once (`Options.retry_flaky`) and
    /// passed. Counted in `total` and NOT in `failed` — but never as a
    /// plain pass: each is named in the trailer with what its first run
    /// said, so a flake is a thing somebody reads rather than a green
    /// run that hid it.
    flaky: std.ArrayListUnmanaged(Flaky) = .empty,

    pub const Flaky = struct {
        /// `name — <the first run's message, first line>`. Owned.
        line: []u8,
    };

    pub fn deinit(self: *Stats, gpa: Allocator) void {
        for (self.flaky.items) |f| gpa.free(f.line);
        self.flaky.deinit(gpa);
        self.* = undefined;
    }
};

// ─── one file ───────────────────────────────────────────────────────────

/// Do this run's content assertions count? Only at the size the file
/// was WRITTEN at — `content_size` by default, the file's own
/// `# width:` / `# height:` when it names one, every size when it says
/// `# sizes: all`. Everywhere else the run proves no panic and no leak
/// and its checks are evaluated but not believed.
pub fn assertsAt(size: Size, opts: Options) bool {
    return opts.sized_by_file or opts.assert_every_size or size.eql(content_size);
}

/// Run one file at one size. Never errors: every failure is an Outcome.
pub fn runFile(gpa: Allocator, io: Io, factory: Factory, path: []const u8, size: Size, opts: Options) Outcome {
    const name = outcomeName(gpa, path, size) catch return oom(gpa, path);
    var run: Run = .{ .gpa = gpa, .io = io, .factory = factory, .path = path, .size = size, .opts = opts, .name = name };
    var outcome = run.go();
    outcome.asserted = assertsAt(size, opts);
    return outcome;
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
    /// How much of the workspace's `command` file has been read. The
    /// file is a mounted integration's Tier-2 line channel
    /// (`statusline-set-segment`, `set-activity-badge`, …); the host
    /// makes its directory when a pane is spawned and the runner reads
    /// it on every tick, so a `.test` can assert the chip a pane
    /// published. Nothing is created here: a script that never mounts a
    /// pane keeps a workspace with no `.mnml/` in it.
    cmd_offset: u64 = 0,
    /// // changed (sessions-card): the file's environment — the run's
    /// plus `MNML_E2E_WORKSPACE` and the `# env:` lines — for its
    /// `shell` steps too, so a step can name the workspace the App sees
    /// (`$MNML_E2E_WORKSPACE`, the path a transcript's `cwd` must match).
    shell_env: ?*const std.process.Environ.Map = null,
    /// The file's process group: a `sleep` the runner starts as its
    /// leader before the App, so the group exists for the whole file.
    /// Every `shell` step joins it, the App's session scan is limited
    /// to it (`MNML_AGENTS_PGID`), and the file's end kills it — so
    /// nothing a file starts (a fake `claude`, a fake server left in
    /// the background) outlives the file or is seen by another run's.
    /// Null on Windows and when shell steps are refused.
    group_leader: ?std.process.Child = null,
    /// Where the git guard's log stood when the file started.
    git_log_start: u64 = 0,
    /// `serve` steps' servers, stopped after the script; their canned
    /// answers live on `serve_arena`.
    servers: std.ArrayListUnmanaged(*mock.Server) = .empty,
    serve_arena: ?std.heap.ArenaAllocator = null,
    /// `serve 0` servers, bound when the file starts (`prebind`) and
    /// handed their answer by their step, in file order.
    prebound: std.ArrayListUnmanaged(*mock.Server) = .empty,
    next_prebound: usize = 0,
    /// The App has asked to quit. From there the runner stops stepping
    /// it: a quit app that keeps being ticked and drawn paints a live
    /// session, so a failure AFTER the quit showed a screen that no
    /// longer exists and `status.json`'s `quit` was the only honest
    /// oracle in the room. Only `expect quit`, `expect status` and
    /// `expect file` still mean anything here; everything else fails
    /// with `app has quit`.
    quit: bool = false,

    fn fail(self: *Run, comptime fmt: []const u8, args: anytype) Outcome {
        const msg = std.fmt.allocPrint(self.gpa, fmt, args) catch null;
        return .{ .name = self.name, .passed = false, .message = msg };
    }

    fn go(self: *Run) Outcome {
        const gpa = self.gpa;
        const io = self.io;

        const raw_text = Io.Dir.cwd().readFileAlloc(io, self.path, gpa, .unlimited) catch |e| return self.fail("can't read: {s}", .{@errorName(e)});
        defer gpa.free(raw_text);
        // `serve 0`: every such server is bound now, before the App and
        // before the header is read, so `${SERVE_PORT}` can be spelled
        // anywhere in the file — a `# env:` line included — and no file
        // ever picks a port another run might hold.
        defer self.stopServers();
        const text = self.prebind(raw_text) catch |e| return self.fail("serve 0: {s}", .{@errorName(e)});
        defer if (text.ptr != raw_text.ptr) gpa.free(text);
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
        self.cmd_offset = 0;

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
        // The data root is what OUTLIVES the file: an integration a
        // script installs stays installed in it. Shared across the run,
        // one file that skipped its uninstall changed what every later
        // file counted, so a single flake became a cascade. Each file
        // gets its own directory under the run's root — which is still
        // the one tree `mnml-zig test` creates and removes — unless the
        // file asks for the shared one by name.
        const data_root: []const u8 = if (header.shared_data_root or self.opts.data_root.len == 0)
            self.opts.data_root
        else
            makeDataRoot(gpa, io, self.opts.data_root, stemOf(self.path)) catch |e| return self.fail("data root: {s}", .{@errorName(e)});
        defer if (data_root.ptr != self.opts.data_root.ptr) {
            Io.Dir.cwd().deleteTree(io, data_root) catch {};
            gpa.free(@constCast(data_root));
        };
        var file_env: std.process.Environ.Map = (if (self.opts.env) |e| e.clone(gpa) else std.process.Environ.Map.init(gpa)) catch return self.fail("out of memory", .{});
        defer file_env.deinit();
        file_env.put("MNML_E2E_WORKSPACE", self.workspace) catch return self.fail("out of memory", .{});
        // The workspace is a fresh directory under `TMPDIR`, and `TMPDIR`
        // is wherever the person running the corpus put it — inside a
        // checkout, often. Git must not walk up out of the workspace into
        // that repository: a file written against "not a git repo" would
        // find the checkout's branches, and one that `git init`s its own
        // is unaffected.
        file_env.put("GIT_CEILING_DIRECTORIES", std.mem.trimEnd(u8, self.opts.tmp_root, "/")) catch return self.fail("out of memory", .{});
        // The terminal the corpus was written in, whatever terminal (or
        // none — CI, `env -i`) the run happens in. A shell pane is named
        // after `$TERM_PROGRAM` (`Terminal (sh)`, `ghostty (sh)`), so a
        // file that says `expect pane Terminal` passed in one emulator
        // and failed in every other. A file that means another terminal
        // says so in its own `# env:` lines, which come after these.
        pinTerminal(&file_env) catch return self.fail("out of memory", .{});
        if (self.opts.git_guard) |g| {
            g.putEnv(gpa, &file_env) catch return self.fail("out of memory", .{});
            self.git_log_start = fileSize(io, g.log);
        }
        for (self.prebound.items, 1..) |srv, i| {
            var nbuf: [32]u8 = undefined;
            var vbuf: [8]u8 = undefined;
            const name = portVarName(&nbuf, i);
            const value = std.fmt.bufPrint(&vbuf, "{d}", .{srv.port}) catch unreachable;
            file_env.put(name, value) catch return self.fail("out of memory", .{});
        }
        // The same root the driver persists into, so a `shell` step and
        // any child can name it — and so a child that resolves its own
        // data root from the environment lands in this file's, not the
        // run's.
        file_env.put("MNML_DATA_ROOT", data_root) catch return self.fail("out of memory", .{});
        // The SDK's cross-process rate limiter adopts a machine-wide
        // state file when one exists (the developer's own bucket), and
        // a pane in a test then waits on tokens the developer's live
        // instance is spending. Each file gets private buckets under
        // its own root, so a first fetch against the offline server is
        // never parked behind the real API's budget.
        for ([_][]const u8{ "JIRA", "BITBUCKET" }) |service| {
            const var_name = std.fmt.allocPrint(gpa, "{s}_RATELIMIT_STATE", .{service}) catch return self.fail("out of memory", .{});
            defer gpa.free(var_name);
            const path = std.fmt.allocPrint(gpa, "{s}/{s}-ratelimit.json", .{ data_root, service }) catch return self.fail("out of memory", .{});
            defer gpa.free(path);
            file_env.put(var_name, path) catch return self.fail("out of memory", .{});
        }
        // The SESSIONS scan reads the file's own data root unless the
        // file names a HOME to seed a fake one under: the start surface
        // lists the workspace's sessions on every empty layout, and a
        // test's screen must not carry the developer's own transcripts.
        var names_home = false;
        for (header.envPairs()) |pair| if (std.mem.eql(u8, pair.key, "HOME")) {
            names_home = true;
        };
        if (!names_home) file_env.put("MNML_SESSIONS_HOME", data_root) catch return self.fail("out of memory", .{});
        // Before the header's own lines, so a file can still name a
        // scope of its own.
        if (self.startGroup()) |pgid| {
            var pbuf: [16]u8 = undefined;
            const text_pgid = std.fmt.bufPrint(&pbuf, "{d}", .{pgid}) catch unreachable;
            file_env.put(agents_scope_env, text_pgid) catch return self.fail("out of memory", .{});
        }
        defer self.endGroup();
        for (header.envPairs()) |pair| {
            const value = expandEnv(gpa, pair.value, &file_env) catch return self.fail("out of memory", .{});
            defer gpa.free(value);
            file_env.put(pair.key, value) catch return self.fail("out of memory", .{});
        }
        self.shell_env = &file_env;
        defer self.shell_env = null;
        const outcome = blk: {
            var cfg = driver_mod.e2e_defaults;
            // `# ascii`: the same switch `mnml-zig --ascii` throws, so
            // the file runs against the whole no-Nerd-Font mode rather
            // than against one function's opinion of it.
            if (header.ascii) cfg.ui.ascii_icons = true;
            const d = self.factory.make(dbg.allocator(), io, .{
                .workspace = self.workspace,
                .data_root = data_root,
                .cols = self.size.cols,
                .rows = self.size.rows,
                .cfg = cfg,
                .env = &file_env,
            }) catch |e| break :blk self.fail("App::new: {s}", .{@errorName(e)});
            self.driver = d;
            var result = self.runScript(&script);
            d.deinit();
            self.stopServers();
            if (result.passed) if (self.gitGuardViolation()) |msg| {
                result = .{ .name = self.name, .passed = false, .message = msg };
            };
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
        const asserting = assertsAt(self.size, self.opts);
        if (self.renderCycle()) |msg| return self.failMsg(msg);
        self.noteQuit();
        for (script.lines) |line| switch (line.stmt) {
            .step => |step| {
                if (self.quit) return self.fail("line {d}: {s}", .{ line.ln, after_quit_msg });
                if (self.runStep(step)) |msg| {
                    defer self.gpa.free(msg);
                    return self.fail("line {d}: {s}", .{ line.ln, msg });
                }
                // The step may BE the quit (the palette's `app.quit`, a
                // click on the confirm box's Quit). Then nothing is
                // ticked or drawn again: the last frame stays the frame
                // the app quit on.
                self.noteQuit();
                if (self.quit) continue;
                if (self.renderCycle()) |msg| return self.failMsg(msg);
                self.noteQuit();
            },
            .check => |check| {
                if (self.quit and !meaningfulAfterQuit(check)) {
                    return self.fail("line {d}: {s}", .{ line.ln, after_quit_msg });
                }
                if (self.pollCheck(check, asserting, line.budget_ms)) |msg| {
                    defer self.gpa.free(msg);
                    if (std.mem.startsWith(u8, msg, "render: ")) return self.fail("{s}", .{msg});
                    return self.fail("line {d}: {s}", .{ line.ln, msg });
                }
            },
        };
        return .{ .name = self.name, .passed = true, .message = null };
    }

    /// Ask the App whether it has quit, and latch it. `status.json`'s
    /// `quit` is the flag the headless loop reads to stop, so it is the
    /// same answer the real host acts on.
    fn noteQuit(self: *Run) void {
        if (self.quit) return;
        const d = self.driver orelse return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const st = d.status(arena.allocator()) catch return;
        if (st.quit) self.quit = true;
    }

    fn failMsg(self: *Run, msg: []u8) Outcome {
        return .{ .name = self.name, .passed = false, .message = msg };
    }

    /// tick → settle → expire chords → tick → draw. Returns an owned
    /// message on driver failure.
    fn renderCycle(self: *Run) ?[]u8 {
        if (self.quit) return null;
        const d = self.driver.?;
        d.tick() catch |e| return self.errMsg("render: {s}", e);
        self.drainIpc();
        self.sleepMs(self.opts.timing.step_settle_ms);
        d.expireChords() catch |e| return self.errMsg("render: {s}", e);
        d.tick() catch |e| return self.errMsg("render: {s}", e);
        d.render() catch |e| return self.errMsg("render: {s}", e);
        return null;
    }

    fn errMsg(self: *Run, comptime fmt: []const u8, e: anyerror) ?[]u8 {
        return std.fmt.allocPrint(self.gpa, fmt, .{@errorName(e)}) catch null;
    }

    /// Every complete line appended to the workspace's `command` file
    /// since the last look, into the driver (the channel's own `poll`,
    /// without the channel: opening one would create the directory).
    fn drainIpc(self: *Run) void {
        const d = self.driver orelse return;
        const io = self.io;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const path = std.fs.path.join(a, &.{ self.workspace, ".mnml", build_options.ipc_subdir, "command" }) catch return;
        const file = Io.Dir.cwd().openFile(io, path, .{}) catch return;
        defer file.close(io);
        const len = file.length(io) catch return;
        if (len < self.cmd_offset) self.cmd_offset = 0;
        if (len == self.cmd_offset) return;
        const buf = a.alloc(u8, @intCast(len - self.cmd_offset)) catch return;
        const n = file.readPositionalAll(io, buf, self.cmd_offset) catch return;
        const text = buf[0..n];
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |nl| {
            const line = text[start .. nl + 1];
            start = nl + 1;
            self.cmd_offset += line.len;
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            const cmd = ipc_command.parse(a, trimmed) catch continue;
            d.ipcCommand(&cmd) catch {};
        }
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
    /// Once the app has quit there is nothing left to retry AGAINST (the
    /// runner stops ticking it), so the check is evaluated once and
    /// answered.
    /// `expect within <ms>` widens the budget for that one check; it
    /// never narrows it below the runner's own.
    fn pollCheck(self: *Run, check: parser.Check, asserting: bool, budget_ms: ?u64) ?[]u8 {
        const d = self.driver.?;
        const budget = @max(self.opts.timing.expect_budget_ms, budget_ms orelse 0);
        const deadline = self.nowMs() + @as(i64, @intCast(budget));
        while (true) {
            const screen = screen_mod.toTestText(self.gpa, d.screen()) catch return self.errMsg("render: {s}", error.OutOfMemory);
            defer self.gpa.free(screen);
            const err = self.runCheck(screen, check) orelse return null;
            if (!asserting) {
                self.gpa.free(err);
                return null;
            }
            if (self.quit or self.nowMs() >= deadline) return err;
            self.gpa.free(err);
            d.tick() catch |e| return self.errMsg("render: {s}", e);
            self.drainIpc();
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
            .command_fails => |id| if (d.command(id)) |_| {
                return std.fmt.allocPrint(gpa, "command! `{s}` succeeded; the step expects it to fail", .{id}) catch null;
            } else |e| switch (e) {
                error.NoSuchCommand => return std.fmt.allocPrint(gpa, "no such command `{s}`", .{id}) catch null,
                error.OutOfMemory => return self.errMsg("command!: {s}", e),
                else => {},
            },
            .ex => |line| d.ex(line) catch |e| return self.errMsg("ex: {s}", e),
            .wait => |ms| {
                // Tick throughout the sleep so async work makes progress
                // while the clock runs, then once more so anything queued
                // by the last slice is drained before the next step.
                const deadline = self.nowMs() + @as(i64, @intCast(ms));
                while (self.nowMs() < deadline) {
                    d.tick() catch |e| return self.errMsg("wait: {s}", e);
                    self.drainIpc();
                    const remaining: u64 = @intCast(@max(deadline - self.nowMs(), 0));
                    self.sleepMs(@min(remaining, self.opts.timing.wait_slice_ms));
                }
                d.tick() catch |e| return self.errMsg("wait: {s}", e);
            },
            .snippet => |s| d.snippet(s.scope, s.trigger, s.expansion) catch |e| return self.errMsg("snippet: {s}", e),
            .shot => |name| d.shot(name) catch |e| return self.errMsg("shot: {s}", e),
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
                    // One deliberate notch per step (`Driver.wheelNotch`).
                    .scroll_up => blk: {
                        d.wheelNotch();
                        break :blk d.mouse(.{ .x = m.x, .y = m.y, .kind = .scroll_up });
                    },
                    .scroll_down => blk: {
                        d.wheelNotch();
                        break :blk d.mouse(.{ .x = m.x, .y = m.y, .kind = .scroll_down });
                    },
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
        if (sv.port == 0) {
            // Bound when the file started; `${SERVE_PORT}` already names it.
            if (self.next_prebound >= self.prebound.items.len) return gpa.dupe(u8, "serve 0: no server was bound for this step") catch null;
            const srv = self.prebound.items[self.next_prebound];
            self.next_prebound += 1;
            srv.serve(canned) catch |e| return std.fmt.allocPrint(gpa, "serve 127.0.0.1:{d}: {s}", .{ srv.port, @errorName(e) }) catch null;
            return null;
        }
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
        for (self.prebound.items) |s| s.stop(self.io);
        self.prebound.deinit(self.gpa);
        self.prebound = .empty;
        self.next_prebound = 0;
        if (self.serve_arena) |*ar| ar.deinit();
        self.serve_arena = null;
    }

    /// Bind one loopback listener per `serve 0` line and return `text`
    /// with `${SERVE_PORT}` (the first) and `${SERVE_PORT_<n>}` (the
    /// n-th) replaced by the ports they got — `text` itself when the
    /// file has none. Owned otherwise.
    fn prebind(self: *Run, text: []const u8) ![]const u8 {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const l = std.mem.trimStart(u8, raw, " \t");
            if (!std.mem.startsWith(u8, l, "serve 0 ")) continue;
            const srv = try mock.Server.listenOn(self.gpa, self.io, 0);
            self.prebound.append(self.gpa, srv) catch |e| {
                srv.stop(self.io);
                return e;
            };
        }
        if (self.prebound.items.len == 0) return text;
        var ports: [16]u16 = undefined;
        const n = @min(self.prebound.items.len, ports.len);
        for (self.prebound.items[0..n], 0..) |srv, i| ports[i] = srv.port;
        return substitutePorts(self.gpa, text, ports[0..n]);
    }

    /// The first `git` this file ran against a repository outside the
    /// run's temp root, as the guard wrote it down — an owned message —
    /// or null.
    fn gitGuardViolation(self: *Run) ?[]u8 {
        const g = self.opts.git_guard orelse return null;
        const file = Io.Dir.cwd().openFile(self.io, g.log, .{}) catch return null;
        defer file.close(self.io);
        const len = file.length(self.io) catch return null;
        if (len <= self.git_log_start) return null;
        var buf: [1024]u8 = undefined;
        const n = file.readPositionalAll(self.io, buf[0..@min(buf.len, len - self.git_log_start)], self.git_log_start) catch return null;
        const text = buf[0..n];
        const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse line.len;
        return std.fmt.allocPrint(self.gpa, "git ran against a repository outside the run's temp root ({s}): {s} — a test must never reach the checkout it runs in", .{ line[0..tab], if (tab < line.len) line[tab + 1 ..] else "" }) catch null;
    }

    /// Start the file's process group (`group_leader`). Returns its id.
    fn startGroup(self: *Run) ?i32 {
        if (builtin.os.tag == .windows or !self.opts.allow_shell) return null;
        var child = std.process.spawn(self.io, .{
            .argv = &.{ "/bin/sh", "-c", "exec sleep 86400" },
            .pgid = 0,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return null;
        const pid = child.id orelse {
            child.kill(self.io);
            return null;
        };
        self.group_leader = child;
        return @intCast(pid);
    }

    /// Kill everything in the file's group, the leader last, and reap
    /// the leader. A background process a `shell` step left running —
    /// `( nohup fake &)` — is in the group too, reparented or not.
    fn endGroup(self: *Run) void {
        if (builtin.os.tag == .windows) return;
        const leader = if (self.group_leader) |*l| l else return;
        if (leader.id) |pid| std.posix.kill(-pid, .KILL) catch {};
        leader.kill(self.io);
        self.group_leader = null;
    }

    fn groupId(self: *const Run) ?std.posix.pid_t {
        if (builtin.os.tag == .windows) return null;
        const leader = self.group_leader orelse return null;
        return leader.id;
    }

    /// `shell <cmd>` runs unsandboxed in the user's account, so it is
    /// default-deny: a cloned repo's `.test` files must not be arbitrary
    /// code execution under `zig build test`.
    fn runShell(self: *Run, cmd: []const u8) ?[]u8 {
        const gpa = self.gpa;
        if (!self.opts.allow_shell) {
            return std.fmt.allocPrint(gpa, "shell `{s}`: refused. .test `shell` steps run unsandboxed; set MNML_E2E_ALLOW_SHELL=1 to opt in (only for trusted repos).", .{cmd}) catch null;
        }
        const result = runIn(gpa, self.io, .{
            .argv = &.{ self.opts.shell, "-c", cmd },
            .cwd = .{ .path = self.workspace },
            .environ_map = self.shell_env,
        }, self.groupId()) catch |e| return std.fmt.allocPrint(gpa, "shell spawn: {s}", .{@errorName(e)}) catch null;
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
            .status_contains, .status_lacks => |want| {
                var arena: std.heap.ArenaAllocator = .init(gpa);
                defer arena.deinit();
                const st = d.status(arena.allocator()) catch return std.fmt.allocPrint(gpa, "expect status: the driver could not build status.json", .{}) catch null;
                const json = screen_mod.statusJson(arena.allocator(), st) catch return std.fmt.allocPrint(gpa, "expect status: out of memory", .{}) catch null;
                const hit = std.mem.indexOf(u8, json, want) != null;
                if (hit == (check == .status_contains)) return null;
                return std.fmt.allocPrint(gpa, "status.json {s} {f}\n── status.json ──\n{s}", .{
                    if (check == .status_contains) "does not contain" else "unexpectedly contains",
                    debug(want),
                    json,
                }) catch null;
            },
            .quit => |want| {
                var arena: std.heap.ArenaAllocator = .init(gpa);
                defer arena.deinit();
                const st = d.status(arena.allocator()) catch return std.fmt.allocPrint(gpa, "expect quit: the driver could not build status.json", .{}) catch null;
                if (st.quit == want) return null;
                return std.fmt.allocPrint(gpa, "the app has {s}quit, expected {s}", .{
                    if (st.quit) "" else "not ",
                    if (want) "it to have quit" else "it still running",
                }) catch null;
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
            .color => |c| {
                const scr = d.screen();
                if (c.x >= scr.width or c.y >= scr.height) {
                    return std.fmt.allocPrint(gpa, "expect color: cell {d},{d} is off a {d}x{d} screen", .{ c.x, c.y, scr.width, scr.height }) catch null;
                }
                const cell = scr.buf[@as(usize, c.y) * scr.width + c.x];
                const got = if (c.bg) cell.style.bg else cell.style.fg;
                const hit = switch (c.want) {
                    .rgb => |want| switch (got) {
                        .rgb => |v| std.mem.eql(u8, &v, &want),
                        else => false,
                    },
                    .index => |want| switch (got) {
                        .index => |i| i == want,
                        else => false,
                    },
                };
                if (hit != c.negated) return null;
                var got_buf: [32]u8 = undefined;
                const got_text = switch (got) {
                    .rgb => |v| std.fmt.bufPrint(&got_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ v[0], v[1], v[2] }) catch "?",
                    .index => |i| std.fmt.bufPrint(&got_buf, "index {d}", .{i}) catch "?",
                    .default => "default",
                };
                var want_buf: [32]u8 = undefined;
                const want_text = switch (c.want) {
                    .rgb => |v| std.fmt.bufPrint(&want_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ v[0], v[1], v[2] }) catch "?",
                    .index => |i| std.fmt.bufPrint(&want_buf, "index {d}", .{i}) catch "?",
                };
                return std.fmt.allocPrint(gpa, "cell {d},{d} {s} is {s}, expected {s}{s}", .{ c.x, c.y, if (c.bg) "bg" else "fg", got_text, if (c.negated) "not " else "", want_text }) catch null;
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

/// What a step or a screen check reports once the app has quit. The
/// runner stops ticking and drawing a quit app, so the frame on screen
/// is the one it died on and every later `expect screen` would be
/// asserting on a ghost. A script that means to end there says so with
/// `expect quit true` and stops.
const after_quit_msg = "app has quit — the runner stopped stepping it here; only `expect quit`, `expect status` and `expect file` still mean anything after a quit";

/// Checks that survive a quit: they read the App's own state or the
/// disk, neither of which needs another frame.
fn meaningfulAfterQuit(check: parser.Check) bool {
    return switch (check) {
        .quit, .status_contains, .status_lacks, .file_contains, .file_lacks => true,
        else => false,
    };
}

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

/// `SERVE_PORT` for the first `serve 0`, `SERVE_PORT_<n>` after it.
fn portVarName(buf: []u8, n: usize) []const u8 {
    if (n == 1) return "SERVE_PORT";
    return std.fmt.bufPrint(buf, "SERVE_PORT_{d}", .{n}) catch "SERVE_PORT_X";
}

/// `text` with every `${SERVE_PORT}` / `${SERVE_PORT_<n>}` whose server
/// exists replaced by its port. A name past the servers is left as
/// written, so the failure it causes names it. Owned.
pub fn substitutePorts(gpa: Allocator, text: []const u8, ports: []const u16) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    const open = "${SERVE_PORT";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, open)) |at| {
        try out.appendSlice(gpa, text[i..at]);
        const rest = text[at + open.len ..];
        var n: usize = 0;
        var used: usize = 0;
        if (std.mem.startsWith(u8, rest, "}")) {
            n = 1;
            used = 1;
        } else if (std.mem.startsWith(u8, rest, "_")) {
            const close = std.mem.indexOfScalar(u8, rest, '}') orelse 0;
            if (close > 1) {
                n = std.fmt.parseInt(usize, rest[1..close], 10) catch 0;
                used = close + 1;
            }
        }
        if (n >= 1 and n <= ports.len) {
            try out.print(gpa, "{d}", .{ports[n - 1]});
            i = at + open.len + used;
        } else {
            try out.appendSlice(gpa, open);
            i = at + open.len;
        }
    }
    try out.appendSlice(gpa, text[i..]);
    return out.toOwnedSlice(gpa);
}

/// Names a file's environment keeps from the environment `mnml-zig test`
/// was started in. Everything else — a developer's tokens, a
/// `CLAUDECODE` from the agent that launched the run, the `MNML_IPC_DIR`
/// of the mnml whose terminal pane it runs in (an integration under test
/// would have written into that live instance's channel), an
/// `XDG_CONFIG_HOME` pointing at the real config — stays out, so a file
/// sees the same environment on every machine: a developer's shell, a
/// CI runner, `env -i`.
const kept_vars = [_][]const u8{
    "PATH",                "TMPDIR",                  "TEMP",                       "TMP",                 "USER",                   "LOGNAME",
    "USERNAME",            "LANG",                    "TZ",                         "SYSTEMROOT",          "SystemRoot",             "WINDIR",
    "COMSPEC",             "PATHEXT",                 "USERPROFILE",                "APPDATA",             "LOCALAPPDATA",           "PROGRAMDATA",
    "HOMEDRIVE",           "HOMEPATH",                "ProgramFiles",               "OS",                  "PROCESSOR_ARCHITECTURE", "ZIG_GLOBAL_CACHE_DIR",
    "ZIG_LOCAL_CACHE_DIR",
    // What `mnml-zig test` itself exports for the scripts (an operator's
    // own value of any of them wins, so they pass through by name).
    "MNML_SHIMS",              "MNML_LAUNCHERS",             "MNML_REPO",           "MNML_FAKE_DAP",          "MNML_FAKE_LSP",
    "MNML_FAKE_COPILOT",   "MNML_SAMPLE_INTEGRATION", "MNML_BITBUCKET_INTEGRATION", "MNML_FAKE_BITBUCKET", "MNML_JIRA",              "MNML_FAKE_JIRA",
};

/// A file's base environment, built from the one the run was started in
/// (`kept_vars`, `LC_*`, `MNML_E2E_*`) with `HOME` set to `home` — a
/// directory of the run's own, never the developer's: the real one
/// carries their git identity, their `~/.config/mnml`, their Claude
/// transcripts and their shared rate-limit buckets. `PATH` gets
/// `$MNML_SHIMS/ai` in front, so the `claude` and `codex` a file finds
/// are the sleeping stand-ins on every machine: the tab bar's AI chip
/// shows only when one is on `PATH`, the corpus was written where both
/// were, and a runner with neither laid its strips out differently — and
/// no file ever starts a real session. A file that means another `PATH`
/// says so in its `# env:` lines.
pub fn hermeticEnv(gpa: Allocator, host: *const std.process.Environ.Map, home: []const u8) Allocator.Error!std.process.Environ.Map {
    var out = std.process.Environ.Map.init(gpa);
    errdefer out.deinit();
    var it = host.iterator();
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        const keep = for (kept_vars) |k| {
            if (std.mem.eql(u8, k, name)) break true;
        } else std.mem.startsWith(u8, name, "LC_") or std.mem.startsWith(u8, name, "MNML_E2E_");
        if (keep) try out.put(name, kv.value_ptr.*);
    }
    try out.put("HOME", home);
    // The shell a terminal pane runs (`pty.shellArgv`). Without it every
    // pty file got `/bin/sh` — no bracketed paste, so a pasted block ran
    // line by line (`pty_paste_sanitized` had to name zsh itself). On
    // macOS it is pinned to the platform's login shell, the one the
    // corpus was written in, whatever the developer runs; elsewhere the
    // host's passes through. A file's own `# env: SHELL=` still wins.
    if (builtin.os.tag == .macos) {
        try out.put("SHELL", "/bin/zsh");
    } else if (host.get("SHELL")) |sh| try out.put("SHELL", sh);
    if (host.get("MNML_SHIMS")) |shims| {
        const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
        const ai = try std.fs.path.join(gpa, &.{ shims, "ai" });
        defer gpa.free(ai);
        const path = if (host.get("PATH")) |p| try std.fmt.allocPrint(gpa, "{s}{c}{s}", .{ ai, sep, p }) else try gpa.dupe(u8, ai);
        defer gpa.free(path);
        try out.put("PATH", path);
    }
    return out;
}

/// The host terminal's fingerprints, removed from a file's environment
/// so none of them reaches the App (`pinTerminal`).
const host_terminal_vars = [_][]const u8{
    "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",   "LC_TERMINAL",                 "LC_TERMINAL_VERSION",
    "WT_SESSION",           "KITTY_WINDOW_ID",   "KITTY_PID",                   "GHOSTTY_RESOURCES_DIR",
    "GHOSTTY_BIN_DIR",      "ITERM_SESSION_ID",  "WEZTERM_PANE",                "WEZTERM_EXECUTABLE",
    "VTE_VERSION",          "KONSOLE_VERSION",   "TMUX",                        "TMUX_PANE",
    "ALACRITTY_WINDOW_ID",  "TERMINAL_EMULATOR", "WARP_IS_LOCAL_SHELL_SESSION",
};

/// A file's terminal: the one the corpus was written in (Apple's
/// Terminal, 256 colours, truecolor), with every other emulator's marks
/// taken off. Deterministic on every host — a developer's ghostty, a CI
/// runner with no terminal at all, an `env -i` run.
pub fn pinTerminal(env: *std.process.Environ.Map) Allocator.Error!void {
    for (host_terminal_vars) |name| _ = env.swapRemove(name);
    try env.put("TERM_PROGRAM", "Apple_Terminal");
    try env.put("TERM", "xterm-256color");
    try env.put("COLORTERM", "truecolor");
}

/// `mnml-zig test`'s `git` guard. A shim named `git`, first on every
/// file's PATH (and the runner's own, for the App's spawns that inherit
/// it), hands every call to the real git and writes down — to `log` —
/// any whose repository is outside `tmp_root`: the checkout the run
/// was started in, above all. A test that reached it was how the
/// checkout's `index.lock` went stale under a killed run. The file that
/// did it fails, naming the command.
pub const GitGuard = struct {
    /// The directory holding the shim.
    shim_dir: []const u8,
    /// Where the shim writes `<repo root>\tgit <args>` lines.
    log: []const u8,
    /// Everything a test may touch is under here.
    tmp_root: []const u8,

    /// The shim first on `env`'s PATH, and the two variables it reads.
    pub fn putEnv(g: GitGuard, gpa: Allocator, env: *std.process.Environ.Map) Allocator.Error!void {
        const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
        const path = if (env.get("PATH")) |p| try std.fmt.allocPrint(gpa, "{s}{c}{s}", .{ g.shim_dir, sep, p }) else try gpa.dupe(u8, g.shim_dir);
        defer gpa.free(path);
        try env.put("PATH", path);
        try env.put("MNML_E2E_GIT_LOG", g.log);
        try env.put("MNML_E2E_TMP_ROOT", std.mem.trimEnd(u8, g.tmp_root, "/"));
    }
};

/// The shim, with the real git's path in place of `@REAL@`. POSIX sh:
/// the leading options that move git elsewhere (`-C dir`) are followed
/// to the directory git will act in; one outside the temp root that
/// resolves to a repository is written down; the call then runs as it
/// was made.
const git_shim_template =
    \\#!/bin/sh
    \\# mnml-zig test's git guard (src/e2e/runner.zig, GitGuard).
    \\real='@REAL@'
    \\dir=$PWD
    \\n=$#
    \\i=1
    \\while [ $i -le $n ]; do
    \\  eval "a=\${$i}"
    \\  case "$a" in
    \\    -C) [ $i -lt $n ] || break; i=$((i+1)); eval "b=\${$i}"; case "$b" in /*) dir=$b ;; *) dir=$dir/$b ;; esac ;;
    \\    -c) i=$((i+1)) ;;
    \\    --*) ;;
    \\    *) break ;;
    \\  esac
    \\  i=$((i+1))
    \\done
    \\case "$dir/" in
    \\  "${MNML_E2E_TMP_ROOT:-}"/*) ;;
    \\  *)
    \\    top=$(cd "$dir" 2>/dev/null && "$real" rev-parse --show-toplevel 2>/dev/null)
    \\    if [ -n "$top" ] && [ -n "${MNML_E2E_GIT_LOG:-}" ]; then
    \\      printf '%s\tgit %s\n' "$top" "$*" >> "$MNML_E2E_GIT_LOG"
    \\    fi ;;
    \\esac
    \\exec "$real" "$@"
    \\
;

/// Write the guard's shim under `run_root` and name its log there.
/// Null on Windows and when no `git` is on `path` (nothing to guard).
/// The returned strings are owned (`deinitGitGuard`).
pub fn installGitGuard(gpa: Allocator, io: Io, run_root: []const u8, tmp_root: []const u8, path: ?[]const u8) !?GitGuard {
    if (builtin.os.tag == .windows) return null;
    const real = (try findOnPath(gpa, io, path orelse return null, "git")) orelse return null;
    defer gpa.free(real);
    const dir = try std.fs.path.join(gpa, &.{ run_root, "git-guard" });
    errdefer gpa.free(dir);
    try Io.Dir.cwd().createDirPath(io, dir);
    const script = try std.mem.replaceOwned(u8, gpa, git_shim_template, "@REAL@", real);
    defer gpa.free(script);
    const shim = try std.fs.path.join(gpa, &.{ dir, "git" });
    defer gpa.free(shim);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = shim, .data = script });
    try Io.Dir.cwd().setFilePermissions(io, shim, .fromMode(0o755), .{});
    const log = try std.fs.path.join(gpa, &.{ run_root, "git-guard.log" });
    errdefer gpa.free(log);
    return .{ .shim_dir = dir, .log = log, .tmp_root = try gpa.dupe(u8, tmp_root) };
}

pub fn deinitGitGuard(gpa: Allocator, g: GitGuard) void {
    gpa.free(g.shim_dir);
    gpa.free(g.log);
    gpa.free(g.tmp_root);
}

/// The first `<dir>/<name>` on `path` that exists. Owned.
fn findOnPath(gpa: Allocator, io: Io, path: []const u8, name: []const u8) Allocator.Error!?[]u8 {
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |d| {
        if (d.len == 0) continue;
        const p = try std.fs.path.join(gpa, &.{ d, name });
        if (Io.Dir.cwd().access(io, p, .{})) |_| return p else |_| gpa.free(p);
    }
    return null;
}

fn fileSize(io: Io, path: []const u8) u64 {
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer f.close(io);
    return f.length(io) catch 0;
}

/// What the App's session scan reads for its process-group scope
/// (`app/agents.zig`'s `scope_env`; the runner cannot import the App).
pub const agents_scope_env = "MNML_AGENTS_PGID";

/// `std.process.run`, with the child put in process group `pgid` when
/// one is given — the file's group, so whatever the step leaves running
/// in the background is the file's to kill.
fn runIn(gpa: Allocator, io: Io, options: std.process.RunOptions, pgid: ?std.posix.pid_t) std.process.RunError!std.process.RunResult {
    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .pgid = pgid,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    // Bounded: a step that timed out may have left a child that ignores
    // SIGTERM, and `Child.kill` would wait on it forever.
    defer child_os.terminate(io, &child, .{});

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    while (multi_reader.fill(options.reserve_amount, options.timeout)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();
    const term = try child.wait(io);
    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer gpa.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    return .{ .stdout = stdout_slice, .stderr = stderr_slice, .term = term };
}

/// `<tmp_root>/mnml-e2e-<random>`, created.
/// `mnml-e2e-` and six hex digits: fifteen characters, near the ten of
/// Rust's `tempfile::tempdir()` (`.tmpXXXXXX`) the corpus was written
/// against. The name is the statusline's workspace chip; a 41-character
/// one was 45 cells of every 120-column row, and with the now-playing
/// cluster beside it the row overflowed and clipped the mode chip
/// (`vim_gv_mode.test` read `V-LI…`) where Rust's runner never does.
///
/// Made with an EXCLUSIVE create, retried on a name that is taken. Six
/// hex digits are sixteen million names, and `TMPDIR` is shared by
/// every run on the machine — ten corpus runs at once, and the dirs of
/// any file a timeout abandoned — so a name that already exists is
/// somebody else's workspace, never one to move into.
pub fn makeTempDir(gpa: Allocator, io: Io, tmp_root: []const u8) ![]u8 {
    const root = std.mem.trimEnd(u8, tmp_root, "/");
    Io.Dir.cwd().createDirPath(io, root) catch {};
    var tries: usize = 0;
    while (true) : (tries += 1) {
        var bytes: [3]u8 = undefined;
        io.random(&bytes);
        const name = try std.fmt.allocPrint(gpa, "{s}/mnml-e2e-{s}", .{ root, &std.fmt.bytesToHex(bytes, .lower) });
        if (createFresh(io, name)) |_| return name else |err| {
            gpa.free(name);
            if (err != error.PathAlreadyExists or tries >= 64) return err;
        }
    }
}

/// `mkdir`, failing when the directory is already there.
fn createFresh(io: Io, path: []const u8) !void {
    try Io.Dir.cwd().createDir(io, path, .default_dir);
}

/// `<run_root>/<stem>-<random>`, created. One file's private
/// `MNML_DATA_ROOT`: it sits inside the run's root, so the run still
/// creates and removes exactly one tree, and the name says which file
/// owns it when a run is inspected after the fact.
fn makeDataRoot(gpa: Allocator, io: Io, run_root: []const u8, stem: []const u8) ![]u8 {
    Io.Dir.cwd().createDirPath(io, run_root) catch {};
    var tries: usize = 0;
    while (true) : (tries += 1) {
        var bytes: [4]u8 = undefined;
        io.random(&bytes);
        const name = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}", .{ std.mem.trimEnd(u8, run_root, "/"), stem, &std.fmt.bytesToHex(bytes, .lower) });
        if (createFresh(io, name)) |_| return name else |err| {
            gpa.free(name);
            if (err != error.PathAlreadyExists or tries >= 64) return err;
        }
    }
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
/// is synthesized so the suite keeps going. With `out`, a heartbeat
/// line names the file every `opts.heartbeat_secs` while it runs.
pub fn runFileWithTimeout(gpa: Allocator, io: Io, factory: Factory, path: []const u8, size: Size, opts: Options, out: ?*Io.Writer) Outcome {
    // The job outlives this call when abandoned, so it cannot come from
    // the leak-checked gpa: page_allocator, and deliberately never freed
    // on the timeout path.
    const job = std.heap.page_allocator.create(Job) catch return runFile(gpa, io, factory, path, size, opts);
    job.* = .{ .gpa = gpa, .io = io, .factory = factory, .path = path, .size = size, .opts = opts };
    const thread = std.Thread.spawn(.{}, Job.work, .{job}) catch {
        std.heap.page_allocator.destroy(job);
        return runFile(gpa, io, factory, path, size, opts);
    };
    // Wait in heartbeat-sized slices: each one that lapses without the
    // file finishing prints its name and elapsed time, so a run that is
    // merely long (the corpus takes minutes) is never mistaken for a
    // hang, and a real hang names its file before the timeout fires.
    var elapsed_secs: u64 = 0;
    const timed_out = blk: while (true) {
        const remaining = opts.file_timeout_secs - elapsed_secs;
        const slice = if (out != null and opts.heartbeat_secs > 0) @min(remaining, opts.heartbeat_secs) else remaining;
        const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(@intCast(slice)), .clock = .awake } };
        if (job.done.waitTimeout(io, timeout)) |_| break :blk false else |_| {}
        elapsed_secs += slice;
        if (elapsed_secs >= opts.file_timeout_secs) {
            break :blk job.state.cmpxchgStrong(.running, .abandoned, .acq_rel, .acquire) == null;
        }
        if (out) |w| {
            w.print("  ⏳ {s} still running ({d}s)", .{ std.fs.path.basename(path), elapsed_secs }) catch {};
            if (childrenSummary(gpa, io)) |kids| {
                defer gpa.free(kids);
                w.print(" — children: {s}", .{kids}) catch {};
            }
            w.writeAll("\n") catch {};
            w.flush() catch {};
        }
    };
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
            .asserted = assertsAt(size, opts),
        };
    }
}

/// `pid name` for each live child of this process, space-joined — what
/// a heartbeat shows so a stuck file's child (a git that never exits, a
/// shell that outlived its pane) is named without a second terminal.
/// Best-effort: null on Windows, when `pgrep` is missing, or when there
/// are no children. Owned.
fn childrenSummary(gpa: Allocator, io: Io) ?[]u8 {
    if (builtin.os.tag == .windows) return null;
    var pid_buf: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&pid_buf, "{d}", .{std.c.getpid()}) catch return null;
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "pgrep", "-lP", pid },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    }) catch return null;
    defer gpa.free(res.stderr);
    defer gpa.free(res.stdout);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        // pgrep lists itself as our child; nobody is stuck on pgrep.
        if (std.mem.endsWith(u8, line, " pgrep")) continue;
        if (out.items.len > 0) out.append(gpa, ' ') catch return null;
        out.appendSlice(gpa, line) catch return null;
    }
    if (out.items.len == 0) return null;
    return gpa.dupe(u8, out.items) catch null;
}

// ─── a path ─────────────────────────────────────────────────────────────

/// A root the filesystem does not have. It used to come back as an
/// empty list, which read exactly like a directory with no scripts in
/// it: the run printed `0/0 passed` and exited **0**. A shell that
/// builds a path list and forgets to word-split it hands the runner one
/// argument of 44 joined paths, and that green run tested nothing.
pub const CollectError = Allocator.Error || error{PathNotFound};

/// Every `*.test` under `root` (recursively, hidden entries skipped,
/// sorted), or `root` itself when it is a file. Owned paths.
pub fn collectFiles(gpa: Allocator, io: Io, root: []const u8) CollectError![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    const st = Io.Dir.cwd().statFile(io, root, .{}) catch return error.PathNotFound;
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

/// Run a root, reporting in Rust `mnml test`'s line formats: `▶ e2e:
/// <name>` before each file, `⊘ e2e SKIP …` for gated files, and one
/// `  ok   <name>` / `  ok*  <name> (structure only)` / `  FAIL <name> —
/// <message>` per outcome. `ok*` is a run whose content assertions were
/// never evaluated — a sweep rung that is not the size the file was
/// written at. It passed the structural checks (no panic, no leak, no
/// rect outside its parent) and nothing more. Unlike
/// Rust, each verdict is printed the moment its file finishes rather
/// than after the whole root: a 500-file corpus takes ten minutes, and
/// a run that prints only start lines for that long reads as a hang.
pub fn runPath(gpa: Allocator, io: Io, factory: Factory, root: []const u8, opts: Options, out: *Io.Writer) !Stats {
    const files = collectFiles(gpa, io, root) catch |err| switch (err) {
        error.PathNotFound => {
            try out.print("mnml-zig test: no such path: {s}\n", .{root});
            try out.flush();
            return err;
        },
        else => return err,
    };
    defer {
        for (files) |p| gpa.free(p);
        gpa.free(files);
    }
    if (files.len == 0) {
        try out.print("mnml-zig test: no .test files under {s}\n", .{root});
        try out.flush();
    }
    var stats: Stats = .{};
    errdefer stats.deinit(gpa);
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
        // `# requires: macos` and friends: a screen only one platform can
        // paint is announced as skipped elsewhere, not failed.
        if (header.requires_os) |os| if (os != builtin.os.tag) {
            try out.print("⊘ e2e SKIP (needs {t}): {s}\n", .{ os, path });
            try out.flush();
            continue;
        };
        // `# requires: optimized`: the file's deadlines are pinned
        // outside the runner — the `wait <ms>` it spells out, and the
        // `--life-secs` it gives the offline server it starts itself —
        // so against an unoptimized build it fails on the clock and says
        // nothing about the app. Skipped with the reason and the
        // command, rather than failing `zig build e2e` (which builds
        // Debug by default) on something the shipped build passes.
        if (header.requires_optimized and debug_slowdown != 1) {
            try out.print("⊘ e2e SKIP (needs an optimized build — `zig build e2e -Doptimize=ReleaseSafe`): {s}\n", .{path});
            try out.flush();
            continue;
        }
        var one: [1]Size = undefined;
        // A file that names its own size is telling us where it was
        // written, so that is where it asserts. Only the sweep's sizes
        // are the run-it-and-see-nothing-breaks kind.
        var file_opts = opts;
        // `# sizes: all`: the file says its assertions are
        // size-independent, so every rung of the sweep evaluates them.
        file_opts.assert_every_size = header.sizes_all;
        const sizes: []const Size = if (header.width != null or header.height != null) blk: {
            one[0] = .{ .cols = header.width orelse content_size.cols, .rows = header.height orelse content_size.rows };
            file_opts.sized_by_file = true;
            break :blk &one;
        } else opts.sizes;
        for (sizes) |size| {
            try out.print("▶ e2e: {s}\n", .{std.fs.path.basename(path)});
            try out.flush();
            var o = runFileWithTimeout(gpa, io, factory, path, size, file_opts, out);
            defer o.deinit(gpa);
            stats.total += 1;
            if (!o.asserted) stats.structure_only += 1;
            if (!o.passed and opts.retry_flaky) {
                // Once more, from scratch. A pass now is a FLAKE — the
                // file's verdict depends on something other than the
                // code, which is a bug to go and find — so it is named
                // with what the first run said, never folded into `ok`.
                const first = firstLine(o.message orelse "");
                try out.print("  ↻    {s} — failed; retrying once: {s}\n", .{ o.name, first });
                try out.print("▶ e2e: {s} (retry)\n", .{std.fs.path.basename(path)});
                try out.flush();
                var again = runFileWithTimeout(gpa, io, factory, path, size, file_opts, out);
                if (again.passed) {
                    const line = try std.fmt.allocPrint(gpa, "{s} — first run: {s}", .{ o.name, first });
                    errdefer gpa.free(line);
                    try stats.flaky.append(gpa, .{ .line = line });
                    try out.print("  FLAKY {s}\n", .{line});
                    again.deinit(gpa);
                    try out.flush();
                    continue;
                }
                o.deinit(gpa);
                o = again;
            }
            if (o.passed) {
                // `ok` is what a file that PASSED ITS CHECKS gets. A
                // sweep rung that never evaluated them gets `ok*` and
                // says so: the same word for both is what made a green
                // sweep indistinguishable from one that proved nothing.
                if (o.asserted) {
                    try out.print("  ok   {s}\n", .{o.name});
                } else {
                    try out.print("  ok*  {s} (structure only)\n", .{o.name});
                }
            } else {
                stats.failed += 1;
                try out.print("  FAIL {s} — {s}\n", .{ o.name, o.message orelse "" });
            }
            try out.flush();
        }
    }
    return stats;
}

fn readHeader(gpa: Allocator, io: Io, path: []const u8) parser.Header {
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch return .{};
    defer gpa.free(text);
    return parser.parseHeader(text);
}

/// Run several roots and print the `N/M passed` trailer. Returns the
/// number of failures — the exit status is 1 when it is not zero.
///
/// The trailer keeps `N/M passed` as its first bytes (scripts grep for
/// it) and then breaks M down by what the runs actually checked:
/// `141/141 passed (141 content, 0 structure-only)`. The two numbers sum
/// to M — content runs evaluated the file's assertions, structure-only
/// runs (a sweep rung that is not the file's own size) proved no panic
/// and no leak and nothing else.
pub fn runPaths(gpa: Allocator, io: Io, factory: Factory, roots: []const []const u8, opts: Options, out: *Io.Writer) !Stats {
    var total: Stats = .{};
    errdefer total.deinit(gpa);
    for (roots) |root| {
        var s = try runPath(gpa, io, factory, root, opts, out);
        defer s.flaky.deinit(gpa);
        total.total += s.total;
        total.failed += s.failed;
        total.structure_only += s.structure_only;
        try total.flaky.appendSlice(gpa, s.flaky.items);
    }
    try out.print("\n{d}/{d} passed ({d} content, {d} structure-only)", .{
        total.total - total.failed,
        total.total,
        total.total - total.structure_only,
        total.structure_only,
    });
    // The flakes are in the count, and named right under it: a run that
    // only passed because of the retry says so in its last lines.
    if (total.flaky.items.len > 0) try out.print(", {d} FLAKY (passed only on a retry)", .{total.flaky.items.len});
    try out.writeAll("\n");
    for (total.flaky.items) |f| try out.print("FLAKY {s}\n", .{f.line});
    try out.flush();
    return total;
}

/// The first line of a failure message — the rest is a screen dump.
fn firstLine(msg: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, msg, '\n') orelse msg.len;
    return msg[0..end];
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
const sdk_testing = @import("mnml_sdk").testing;
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

test "shipped defaults: 120×40, 50 ms settle, 3 s expect budget at 40 ms, 25 ms wait slices, 120 s timeout, 60 s heartbeat, shell refused" {
    const o: Options = .{ .data_root = "" };
    try t.expectEqual(@as(u64, 60), o.heartbeat_secs);
    try t.expectEqual(@as(u16, 120), content_size.cols);
    try t.expectEqual(@as(u16, 40), content_size.rows);
    try t.expectEqual(@as(usize, 1), o.sizes.len);
    try t.expect(o.sizes[0].eql(content_size));
    try t.expectEqual(@as(u64, 50), o.timing.step_settle_ms);
    // The two deadlines are the shipped build's; an unoptimized one runs
    // the app `debug_slowdown` times slower and gets that much more wall
    // clock for the same work.
    try t.expectEqual(@as(u64, 3000 * debug_slowdown), o.timing.expect_budget_ms);
    try t.expectEqual(@as(u64, 40), o.timing.expect_poll_ms);
    try t.expectEqual(@as(u64, 25), o.timing.wait_slice_ms);
    try t.expectEqual(default_file_timeout_secs, o.file_timeout_secs);
    try t.expect(!o.allow_shell);
    try t.expect(!o.network);
}

test "debug_slowdown is 1 in the shipped build and scales the deadlines in Debug" {
    try t.expectEqual(@as(u64, if (builtin.mode == .Debug) 20 else 1), debug_slowdown);
    const o: Options = .{ .data_root = "" };
    if (builtin.mode == .Debug) {
        try t.expect(o.timing.expect_budget_ms > 3000);
        try t.expect(o.file_timeout_secs > 120 and o.file_timeout_secs <= 600);
    } else {
        try t.expectEqual(@as(u64, 3000), o.timing.expect_budget_ms);
        try t.expectEqual(@as(u64, 120), o.file_timeout_secs);
    }
    // The script budget moves with the build too, and out of the same
    // measurement — it stops being a frame budget in a Debug build and
    // becomes a runaway budget derived from this factor (`lua.zig`).
    const lua_budget = @import("../scripting/lua.zig");
    if (debug_slowdown == 1)
        try t.expectEqual(lua_budget.frame_budget_ms, lua_budget.budget_ms)
    else
        try t.expect(lua_budget.budget_ms >= lua_budget.frame_budget_ms * @as(i64, @intCast(debug_slowdown)));
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
    try t.expect(sdk_testing.pathEndsWith(calls[ws_open..open_line_end], "/a.txt"));
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
    try t.expect(sdk_testing.pathEndsWith(o.message.?, "/nope.txt: FileNotFound"));
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

test "command! passes only when the command fails: a success, or no such command, fails the step" {
    var env = try TestEnv.init();
    defer env.deinit();
    const cases = [_]struct { src: []const u8, msg: []const u8 }{
        .{ .src = "command! a.ok\n", .msg = "line 1: command! `a.ok` succeeded; the step expects it to fail" },
        .{ .src = "command! a.nope\n", .msg = "line 1: no such command `a.nope`" },
    };
    for (cases, 0..) |c, i| {
        var name_buf: [16]u8 = undefined;
        const path = try env.script(try std.fmt.bufPrint(&name_buf, "cf{d}.test", .{i}), c.src);
        defer t.allocator.free(path);
        var sf: StubFactory = .{ .proto = .{ .known_commands = &.{"a.ok"} } };
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

test "each file persists into its own data root, so one that leaves something installed cannot reach the next" {
    var env = try TestEnv.init();
    defer env.deinit();
    var opts = env.opts();
    opts.allow_shell = true;
    var sf: StubFactory = .{};
    // The first file "installs" and never cleans up.
    const installs = try env.script("d1.test", "shell mkdir -p \"$MNML_DATA_ROOT/integrations\" && touch \"$MNML_DATA_ROOT/integrations/left-behind\"\n");
    defer t.allocator.free(installs);
    var o1 = runFile(t.allocator, t.io, sf.factory(), installs, content_size, opts);
    try expectPassed(&o1);
    // The second asserts a clean panel. Sharing a root, it would find
    // the first file's leftovers and fail.
    const clean = try env.script("d2.test", "shell test ! -e \"$MNML_DATA_ROOT/integrations/left-behind\"\n");
    defer t.allocator.free(clean);
    var o2 = runFile(t.allocator, t.io, sf.factory(), clean, content_size, opts);
    try expectPassed(&o2);
    // Both directories lived under the run's one root and were removed.
    var dir = try Io.Dir.cwd().openDir(t.io, env.data_root, .{ .iterate = true });
    defer dir.close(t.io);
    var it = dir.iterate();
    try t.expect((try it.next(t.io)) == null);
    // A file's panes get rate-limit buckets of their own, under its
    // root — never the machine-wide file a developer's live instance
    // is spending from.
    const bucket = try env.script("d5.test", "shell test \"${JIRA_RATELIMIT_STATE#$MNML_DATA_ROOT/}\" = \"JIRA-ratelimit.json\" && test \"${BITBUCKET_RATELIMIT_STATE#$MNML_DATA_ROOT/}\" = \"BITBUCKET-ratelimit.json\"\n");
    defer t.allocator.free(bucket);
    var o5 = runFile(t.allocator, t.io, sf.factory(), bucket, content_size, opts);
    try expectPassed(&o5);
    // `# shared-data-root` opts back in: the file sees the run's root,
    // where the same `shell` line left nothing, so the marker it makes
    // there is still there for the next shared-root file.
    const shared_a = try env.script("d3.test", "# shared-data-root\nshell touch \"$MNML_DATA_ROOT/shared-marker\"\n");
    defer t.allocator.free(shared_a);
    var o3 = runFile(t.allocator, t.io, sf.factory(), shared_a, content_size, opts);
    try expectPassed(&o3);
    const shared_b = try env.script("d4.test", "# shared-data-root\nshell test -e \"$MNML_DATA_ROOT/shared-marker\"\n");
    defer t.allocator.free(shared_b);
    var o4 = runFile(t.allocator, t.io, sf.factory(), shared_b, content_size, opts);
    try expectPassed(&o4);
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
    const path = try env.script("w.test", "wait 100\n");
    defer t.allocator.free(path);
    // Every tick is stamped. A `wait` that slept its whole clock and
    // ticked once after would leave one gap as long as the wait; one that
    // ticks between slices leaves no gap longer than a slice took. The
    // assertion is relative to what the clock actually did, so a runner
    // that oversleeps each 2 ms slice tenfold still passes, and only a
    // single sleep swallowing half the file's span fails it.
    const Stamped = struct {
        var at: [4096]i64 = undefined;
        var n: usize = 0;
        fn create(_: *anyopaque, gpa: Allocator, _: Io, cfg: driver_mod.Config) anyerror!Driver {
            const s = try gpa.create(driver_mod.Stub);
            s.* = try driver_mod.Stub.init(gpa, cfg.cols, cfg.rows);
            return .{ .ptr = s, .vtable = &stamped };
        }
        const stamped: Driver.VTable = blk: {
            var v = @as(*const Driver.VTable, driver_mod.Stub.vtablePtr()).*;
            v.tick = struct {
                fn f(p: *anyopaque) driver_mod.Error!void {
                    if (n < at.len) {
                        at[n] = Io.Timestamp.now(std.testing.io, .awake).toMilliseconds();
                        n += 1;
                    }
                    return driver_mod.Stub.vtablePtr().tick(p);
                }
            }.f;
            break :blk v;
        };
    };
    Stamped.n = 0;
    var dummy: u8 = 0;
    var o = runFile(t.allocator, t.io, .{ .ptr = &dummy, .create = Stamped.create }, path, content_size, env.opts());
    try expectPassed(&o);
    const stamps = Stamped.at[0..Stamped.n];
    try t.expect(stamps.len >= 2);
    const span = stamps[stamps.len - 1] - stamps[0];
    // The clock ran: the ticks span the whole wait.
    try t.expect(span >= 100);
    var widest: i64 = 0;
    for (stamps[1..], stamps[0 .. stamps.len - 1]) |b, a| widest = @max(widest, b - a);
    // And it was ticked through: no single gap is half of it.
    if (widest * 2 > span) {
        std.debug.print("wait ticks: {d} over {d} ms, widest gap {d} ms\n", .{ stamps.len, span, widest });
        return error.TestUnexpectedResult;
    }
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
    var o = runFileWithTimeout(t.allocator, t.io, .{ .ptr = &dummy, .create = Hang.create }, path, content_size, opts, null);
    try expectFailed(&o, "TIMEOUT after 1s (worker abandoned — a step never returned; override via MNML_E2E_FILE_TIMEOUT_SECS)");
    // Let the abandoned worker finish and free its own outcome before the
    // test allocator checks for leaks.
    try Hang.finished.wait(std.testing.io);
    std.testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
}

test "a root that is not there is an error, not a green 0/0 — including a joined path list" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.tmp.dir.createDirPath(t.io, "suite");
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "suite/a.test", .data = "expect screen contains ok\n" });
    const real = try std.fs.path.join(t.allocator, &.{ env.root, "suite" });
    defer t.allocator.free(real);
    const missing = try std.fs.path.join(t.allocator, &.{ env.root, "nope" });
    defer t.allocator.free(missing);
    // A path list a shell forgot to word-split arrives as ONE argument.
    const joined = try std.mem.join(t.allocator, " ", &.{ real, real });
    defer t.allocator.free(joined);

    try t.expectError(error.PathNotFound, collectFiles(t.allocator, t.io, missing));
    try t.expectError(error.PathNotFound, collectFiles(t.allocator, t.io, joined));
    const found = try collectFiles(t.allocator, t.io, real);
    defer {
        for (found) |f| t.allocator.free(f);
        t.allocator.free(found);
    }
    try t.expectEqual(@as(usize, 1), found.len);

    // And the runner says which path, rather than reporting a pass.
    var sf: StubFactory = .{ .proto = .{ .text = "ok" } };
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try t.expectError(error.PathNotFound, runPaths(t.allocator, t.io, sf.factory(), &.{joined}, env.opts(), &out.writer));
    try t.expect(std.mem.indexOf(u8, out.written(), "no such path: ") != null);
    try t.expect(std.mem.indexOf(u8, out.written(), "passed") == null);
}

test "runPath: skips, sizes, names, and the ok/ok*/FAIL/N-M report" {
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
    try t.expectEqual(@as(usize, 2), stats.failed);
    const report = out.written();
    // Sorted by path; a hidden file and a non-.test file are ignored. The
    // sweep's own second size is the not-asserted one: a_fail's miss is
    // reported at 120×40 and ignored at 80×24 — and the 80×24 verdict
    // says `ok*  … (structure only)` rather than `ok`, because nothing
    // it could have checked was checked. e_wide names ITS OWN size, so
    // 80 columns is where it was written and where its miss counts.
    // Each verdict follows its own start line — the rendered-screen dump of
    // the miss sits between a_fail's first start and its 80x24 start.
    const expected =
        "▶ e2e: a_fail.test\n" ++
        "  FAIL a_fail.test — line 1: screen does not contain \"nope\"\n── rendered screen ──\n" ++ "SCREEN" ++
        "\n▶ e2e: a_fail.test\n  ok*  a_fail.test @80x24 (structure only)\n" ++
        "▶ e2e: b_pass.test\n  ok   b_pass.test\n▶ e2e: b_pass.test\n  ok*  b_pass.test @80x24 (structure only)\n" ++
        "⊘ e2e SKIP (network opt-in): " ++ "SUITE/sub/c_net.test\n" ++
        "▶ e2e: e_wide.test\n  FAIL e_wide.test @80x40 — line 2: screen does not contain \"nope\"\n";
    // Compare piecewise around the parts that carry paths / the screen dump.
    const head = std.mem.indexOf(u8, expected, "SCREEN").?;
    try t.expectEqualStrings(expected[0..head], report[0..head]);
    const middle = expected[head + "SCREEN".len .. std.mem.indexOf(u8, expected, "SUITE").?];
    try t.expect(std.mem.indexOf(u8, report, middle) != null);
    try t.expect(sdk_testing.pathContains(report, "/suite/sub/c_net.test\n"));
    try t.expect(std.mem.indexOf(u8, report, "  FAIL e_wide.test @80x40 — line 2: screen does not contain \"nope\"\n") != null);
    // The tally keeps `N/M passed` as its first bytes — scripts grep for
    // it — and then says how much of M actually checked anything.
    try t.expect(std.mem.endsWith(u8, report, "\n3/5 passed (3 content, 2 structure-only)\n"));
    try t.expectEqual(@as(usize, 2), stats.structure_only);
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

test "a file that names its own size asserts AT that size; only a sweep's extra sizes are the silent ones" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.tmp.dir.createDirPath(t.io, "sized");
    // The stub paints `ok`. Each of these asks for something else, so
    // each miss is real — what differs is whether anyone is listening.
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "sized/narrow.test", .data = "# width: 80\nexpect screen contains nope\n" });
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "sized/short.test", .data = "# height: 14\nexpect screen contains nope\n" });
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "sized/plain.test", .data = "expect screen contains nope\n" });
    const root = try std.fs.path.join(t.allocator, &.{ env.root, "sized" });
    defer t.allocator.free(root);
    var sf: StubFactory = .{ .proto = .{ .text = "ok" } };
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    const stats = try runPaths(t.allocator, t.io, sf.factory(), &.{root}, env.opts(), &out.writer);
    // All three miss, all three fail — the two sized ones no longer
    // read green while proving nothing.
    try t.expectEqual(@as(usize, 3), stats.total);
    try t.expectEqual(@as(usize, 3), stats.failed);
    const report = out.written();
    try t.expect(std.mem.indexOf(u8, report, "  FAIL narrow.test @80x40 — line 2: screen does not contain") != null);
    try t.expect(std.mem.indexOf(u8, report, "  FAIL short.test @120x14 — line 2: screen does not contain") != null);

    // The sweep's own extra sizes stay silent: a run at 200×60 exists to
    // prove nothing panics, and `plain.test` was written at 120×40.
    var out2: Io.Writer.Allocating = .init(t.allocator);
    defer out2.deinit();
    var opts = env.opts();
    opts.sizes = &.{.{ .cols = 200, .rows = 60 }};
    _ = try runPaths(t.allocator, t.io, sf.factory(), &.{root}, opts, &out2.writer);
    try t.expect(std.mem.indexOf(u8, out2.written(), "  ok*  plain.test @200x60 (structure only)\n") != null);
    // A file with its own header keeps it even under a sweep, and keeps
    // asserting there.
    try t.expect(std.mem.indexOf(u8, out2.written(), "  FAIL narrow.test @80x40 —") != null);
}

test "`# sizes: all` makes a file's assertions count at every rung of the sweep" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.tmp.dir.createDirPath(t.io, "allsizes");
    // The stub paints `ok` at every size, so the assertion is genuinely
    // size-independent — which is the only kind `# sizes: all` is for.
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "allsizes/any.test", .data = "# sizes: all\nexpect screen contains ok\n" });
    // The same file without the header, and a miss that only the corpus
    // size will hear.
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "allsizes/plain.test", .data = "# sizes: all\nexpect screen contains nope\n" });
    const root = try std.fs.path.join(t.allocator, &.{ env.root, "allsizes" });
    defer t.allocator.free(root);
    var sf: StubFactory = .{ .proto = .{ .text = "ok" } };
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var opts = env.opts();
    opts.sizes = &.{ content_size, .{ .cols = 80, .rows = 24 }, .{ .cols = 200, .rows = 60 } };
    const stats = try runPaths(t.allocator, t.io, sf.factory(), &.{root}, opts, &out.writer);
    const report = out.written();
    // Six runs, none of them structure-only: the header opted every rung
    // in, so every rung says plain `ok` or FAILs on its own evidence.
    try t.expectEqual(@as(usize, 6), stats.total);
    try t.expectEqual(@as(usize, 0), stats.structure_only);
    try t.expectEqual(@as(usize, 3), stats.failed);
    try t.expect(std.mem.indexOf(u8, report, "  ok   any.test\n") != null);
    try t.expect(std.mem.indexOf(u8, report, "  ok   any.test @80x24\n") != null);
    try t.expect(std.mem.indexOf(u8, report, "  ok   any.test @200x60\n") != null);
    try t.expect(std.mem.indexOf(u8, report, "(structure only)") == null);
    // The miss is reported at all three rungs, not only at 120×40.
    try t.expect(std.mem.indexOf(u8, report, "  FAIL plain.test — line 2:") != null);
    try t.expect(std.mem.indexOf(u8, report, "  FAIL plain.test @80x24 — line 2:") != null);
    try t.expect(std.mem.indexOf(u8, report, "  FAIL plain.test @200x60 — line 2:") != null);
    try t.expect(std.mem.endsWith(u8, report, "\n3/6 passed (6 content, 0 structure-only)\n"));

    // And without the header the same three rungs go back to two silent
    // ones — the header is what changed the answer.
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "allsizes/any.test", .data = "expect screen contains ok\n" });
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "allsizes/plain.test", .data = "expect screen contains nope\n" });
    var out2: Io.Writer.Allocating = .init(t.allocator);
    defer out2.deinit();
    const s2 = try runPaths(t.allocator, t.io, sf.factory(), &.{root}, opts, &out2.writer);
    try t.expectEqual(@as(usize, 4), s2.structure_only);
    try t.expectEqual(@as(usize, 1), s2.failed);
    try t.expect(std.mem.endsWith(u8, out2.written(), "\n5/6 passed (2 content, 4 structure-only)\n"));
}

test "expect quit reads the app's own flag, true and false, and retries until it lands" {
    var env = try TestEnv.init();
    defer env.deinit();
    const path = try env.script("q.test", "expect quit false\ncommand app.quit\nexpect quit true\n");
    defer t.allocator.free(path);
    var sf: StubFactory = .{ .proto = .{ .text = "ok", .quit_command = "app.quit" } };
    var o = runFile(t.allocator, t.io, sf.factory(), path, content_size, env.opts());
    try expectPassed(&o);

    // The other way round: a script that says the app is still running
    // after it quit is told what the flag actually says.
    const bad = try env.script("q2.test", "command app.quit\nexpect quit false\n");
    defer t.allocator.free(bad);
    var o2 = runFile(t.allocator, t.io, sf.factory(), bad, content_size, env.opts());
    try expectFailed(&o2, "line 2: the app has quit, expected it still running");

    // And a quit that never comes is a failure naming the same flag.
    const never = try env.script("q3.test", "expect quit true\n");
    defer t.allocator.free(never);
    var o3 = runFile(t.allocator, t.io, sf.factory(), never, content_size, env.opts());
    try expectFailed(&o3, "line 1: the app has not quit, expected it to have quit");
}

test "once the app has quit the runner stops stepping it: only quit/status/file checks still mean anything" {
    var env = try TestEnv.init();
    defer env.deinit();
    var sf: StubFactory = .{ .proto = .{ .text = "ok", .quit_command = "app.quit" } };

    // A screen check after the quit is the trap the runner used to set:
    // it kept drawing, so the dead session still painted `ok`. Now it
    // says what happened instead of answering from a ghost frame.
    const screen_after = try env.script("after_screen.test", "command app.quit\nexpect screen contains ok\n");
    defer t.allocator.free(screen_after);
    var o = runFile(t.allocator, t.io, sf.factory(), screen_after, content_size, env.opts());
    try expectFailed(&o, "line 2: " ++ after_quit_msg);

    // So is another step.
    const step_after = try env.script("after_step.test", "command app.quit\nkey ctrl+s\n");
    defer t.allocator.free(step_after);
    var o2 = runFile(t.allocator, t.io, sf.factory(), step_after, content_size, env.opts());
    try expectFailed(&o2, "line 2: " ++ after_quit_msg);

    // `expect status` and `expect file` read the app's state and the
    // disk, neither of which needs another frame — they still run, and
    // so does `expect quit`.
    const ok_after = try env.script(
        "after_ok.test",
        "write notes.txt saved\ncommand app.quit\nexpect quit true\nexpect status contains \"\\\"quit\\\":true\"\nexpect file notes.txt contains saved\n",
    );
    defer t.allocator.free(ok_after);
    var o3 = runFile(t.allocator, t.io, sf.factory(), ok_after, content_size, env.opts());
    try expectPassed(&o3);

    // The app is not ticked or drawn after the quit: a script that quits
    // on its second step renders for the first step and no more.
    var counting: StubFactory = .{ .proto = .{ .text = "ok", .quit_command = "app.quit" } };
    const counted = try env.script("after_count.test", "command app.quit\nexpect quit true\n");
    defer t.allocator.free(counted);
    var o4 = runFile(t.allocator, t.io, counting.factory(), counted, content_size, env.opts());
    try expectPassed(&o4);
    // One render cycle before the script's first line, and none after
    // the quit: a second render would mean the runner drew the dead app.
    try t.expectEqual(@as(usize, 1), counting.stats.renders);
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
    const expected = try std.mem.concat(t.allocator, u8, &.{ "\u{25b6} e2e: alpha_one.test\n  ok   alpha_one.test\n", skip_line });
    defer t.allocator.free(expected);
    try sdk_testing.expectPath(expected, out.written());
    try t.expectEqualStrings("alpha_one", stemOf("/x/alpha_one.test"));
    try t.expectEqualStrings("notes", stemOf("notes"));
}

test "`# requires: optimized` runs against a shipped build and is announced as skipped against a Debug one" {
    var env = try TestEnv.init();
    defer env.deinit();
    const path = try env.script("pinned.test", "# requires: optimized\nexpect screen contains ok\n");
    defer t.allocator.free(path);
    var sf: StubFactory = .{ .proto = .{ .text = "ok" } };
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    const s = try runPath(t.allocator, t.io, sf.factory(), path, env.opts(), &out.writer);
    if (debug_slowdown == 1) {
        // The shipped build runs it like any other file.
        try t.expectEqual(@as(usize, 1), s.total);
        try t.expectEqual(@as(usize, 0), s.failed);
        try t.expectEqualStrings("▶ e2e: pinned.test\n  ok   pinned.test\n", out.written());
    } else {
        // Debug: not run, not failed, and the line says why and what to
        // type — the whole point is that it stops reading as a bug in
        // the app.
        try t.expectEqual(@as(usize, 0), s.total);
        try t.expectEqual(@as(usize, 0), s.failed);
        try t.expect(std.mem.startsWith(u8, out.written(), "⊘ e2e SKIP (needs an optimized build — `zig build e2e -Doptimize=ReleaseSafe`): "));
        try t.expect(std.mem.endsWith(u8, out.written(), "pinned.test\n"));
    }
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

test "runPath: a verdict lands right after its own start line, not after the whole root" {
    // A ten-minute corpus that prints only start lines until the end reads
    // as a hang (2026-09-13: four runs killed mid-flight for exactly that).
    var env = try TestEnv.init();
    defer env.deinit();
    try env.tmp.dir.createDirPath(t.io, "suite");
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "suite/a_fail.test", .data = "expect screen contains nope\n" });
    try env.tmp.dir.writeFile(t.io, .{ .sub_path = "suite/b_pass.test", .data = "expect screen contains ok\n" });
    const root = try std.fs.path.join(t.allocator, &.{ env.root, "suite" });
    defer t.allocator.free(root);
    var sf: StubFactory = .{ .proto = .{ .text = "ok" } };
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    const s = try runPath(t.allocator, t.io, sf.factory(), root, env.opts(), &out.writer);
    try t.expectEqual(@as(usize, 2), s.total);
    const report = out.written();
    // a_fail's verdict is out before b_pass even starts.
    try t.expect(std.mem.startsWith(u8, report, "▶ e2e: a_fail.test\n  FAIL a_fail.test — "));
    try t.expect(std.mem.endsWith(u8, report, "▶ e2e: b_pass.test\n  ok   b_pass.test\n"));
}

test "runFileWithTimeout: a heartbeat names a file that is still running before the timeout" {
    var env = try TestEnv.init();
    defer env.deinit();
    const path = try env.script("slow.test", "wait 1\n");
    defer t.allocator.free(path);
    const Slow = struct {
        var slept_once = false;
        fn create(_: *anyopaque, gpa: Allocator, _: Io, cfg: driver_mod.Config) anyerror!Driver {
            const s = try gpa.create(driver_mod.Stub);
            s.* = try driver_mod.Stub.init(gpa, cfg.cols, cfg.rows);
            return .{ .ptr = s, .vtable = &slow };
        }
        const slow: Driver.VTable = blk: {
            var v = @as(*const Driver.VTable, driver_mod.Stub.vtablePtr()).*;
            v.tick = struct {
                fn f(_: *anyopaque) driver_mod.Error!void {
                    // One tick outlives the heartbeat but not the timeout.
                    if (slept_once) return;
                    slept_once = true;
                    std.testing.io.sleep(.fromMilliseconds(1500), .awake) catch {};
                }
            }.f;
            break :blk v;
        };
    };
    var dummy: u8 = 0;
    var opts = env.opts();
    opts.heartbeat_secs = 1;
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var o = runFileWithTimeout(t.allocator, t.io, .{ .ptr = &dummy, .create = Slow.create }, path, content_size, opts, &out.writer);
    defer o.deinit(t.allocator);
    try t.expect(o.passed);
    // The line names the file and the seconds elapsed; the children list
    // that may follow depends on the machine and is not asserted.
    try t.expect(std.mem.startsWith(u8, out.written(), "  ⏳ slow.test still running (1s)"));
    try t.expect(std.mem.endsWith(u8, out.written(), "\n"));
}

test "debug quoting matches Rust's {:?} for the characters that appear in scripts" {
    var a: Io.Writer.Allocating = .init(t.allocator);
    defer a.deinit();
    try a.writer.print("{f}", .{debug("a\"b\\c\nd\te\x01")});
    try t.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\u{1}\"", a.written());
}

test "`shot` reaches the driver and passes on one that cannot take a picture" {
    var env = try TestEnv.init();
    defer env.deinit();
    const path = try env.script("s.test", "shot before_open\nopen a.txt\nshot after_open\n");
    defer t.allocator.free(path);
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
    // The driver has no pixels, so the step is a no-op — and the file
    // still passes, which is the whole point: one script runs under
    // every driver and only the ghostty one leaves a picture.
    try expectPassed(&o);
    const calls = try keep.stub.callsJoined(t.allocator);
    defer t.allocator.free(calls);
    try t.expect(std.mem.indexOf(u8, calls, "shot before_open\n") != null);
    try t.expect(std.mem.indexOf(u8, calls, "shot after_open") != null);
}

test "the ladder brackets every known chrome breakpoint, in order, and includes the corpus size" {
    // Not just its ends: a size-only bug hides BETWEEN two rungs, and a
    // sweep of 80 and 200 has walked past several (the dock's label
    // collapse, the menu bar's `»`, the PR row's icon/label switch).
    try t.expect(ladder.len >= 6);
    var prev: u16 = 0;
    var has_corpus = false;
    for (ladder) |s| {
        try t.expect(s.cols > prev); // strictly widening, so a sweep is a ramp
        prev = s.cols;
        try t.expect(s.cols >= 80 and s.rows >= 24); // nothing below what the picker survives
        if (s.eql(content_size)) has_corpus = true;
    }
    // The corpus size has to be on it: every `.test` content assertion
    // was written there, so it is the rung where a difference means a
    // regression rather than a reflow.
    try t.expect(has_corpus);
    try t.expectEqual(@as(u16, 80), ladder[0].cols);
    try t.expectEqual(@as(u16, 200), ladder[ladder.len - 1].cols);
    // The Bitbucket PR row's icon/label switch and the settings strip's
    // initials form both sit around 135; a rung has to bracket them.
    var brackets_135 = false;
    for (ladder) |s| {
        if (s.cols >= 130 and s.cols <= 140) brackets_135 = true;
    }
    try t.expect(brackets_135);
}

test "expect within <ms> polls past the runner's budget and answers the moment the check holds" {
    var env = try TestEnv.init();
    defer env.deinit();
    // The text lands on the 80th render: far past `fast`'s 60 ms budget
    // at a 5 ms poll, well inside 5 s.
    const bare = try env.script("b.test", "open a.txt\nexpect screen contains late\n");
    defer t.allocator.free(bare);
    var slow: StubFactory = .{ .proto = .{ .text = "early", .late_after = 80, .late_text = "late" } };
    var o = runFile(t.allocator, t.io, slow.factory(), bare, content_size, env.opts());
    defer o.deinit(t.allocator);
    try t.expect(!o.passed);

    const within = try env.script("w.test", "open a.txt\nexpect within 5000 screen contains late\n");
    defer t.allocator.free(within);
    var slow2: StubFactory = .{ .proto = .{ .text = "early", .late_after = 80, .late_text = "late" } };
    var o2 = runFile(t.allocator, t.io, slow2.factory(), within, content_size, env.opts());
    try expectPassed(&o2);
    // It stopped polling once the text was there, not at the 5 s cap.
    try t.expect(slow2.stats.renders < 200);

    // A check that never holds still fails, with the screen, at the cap.
    var never: StubFactory = .{ .proto = .{ .text = "early" } };
    const short = try env.script("n.test", "open a.txt\nexpect within 100 screen contains late\n");
    defer t.allocator.free(short);
    var o3 = runFile(t.allocator, t.io, never.factory(), short, content_size, env.opts());
    defer o3.deinit(t.allocator);
    try t.expect(!o3.passed);
    try t.expect(std.mem.startsWith(u8, o3.message.?, "line 2: screen does not contain \"late\""));
}

test "substitutePorts: the first and the n-th, a name past the servers left as written" {
    const out = try substitutePorts(t.allocator, "a ${SERVE_PORT} b ${SERVE_PORT_2} c ${SERVE_PORT_3} d ${SERVE_PORTX} ${SERVE_PORT", &.{ 4101, 4102 });
    defer t.allocator.free(out);
    try t.expectEqualStrings("a 4101 b 4102 c ${SERVE_PORT_3} d ${SERVE_PORTX} ${SERVE_PORT", out);
}

test "serve 0 binds a port of its own before the file runs, and ${SERVE_PORT} names it everywhere" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var env = try TestEnv.init();
    defer env.deinit();
    var opts = env.opts();
    opts.allow_shell = true;
    var sf: StubFactory = .{};
    // A fixed port is the corpus's old shape: two runs of one file at
    // once, and the second failed `serve` with AddressInUse. Here the
    // header, a `write` and a shell step all see the port the OS gave.
    const path = try env.script("serve0.test",
        \\# env: WHERE=http://127.0.0.1:${SERVE_PORT}/x
        \\serve 0 200 hello
        \\write port.txt "${SERVE_PORT}"
        \\shell read p < port.txt; [ "$p" -gt 0 ] && [ "$p" -eq "$SERVE_PORT" ] && [ "$WHERE" = "http://127.0.0.1:$p/x" ]
        \\shell /bin/bash -c 'exec 3<>/dev/tcp/127.0.0.1/'"$SERVE_PORT"'; printf "GET / HTTP/1.0\r\n\r\n" >&3; read -r line <&3; case "$line" in *200*) exit 0;; esac; exit 1'
        \\
    );
    defer t.allocator.free(path);
    var o = runFile(t.allocator, t.io, sf.factory(), path, content_size, opts);
    try expectPassed(&o);
}

test "a process a shell step leaves behind is in the file's own group, and dies with the file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var env = try TestEnv.init();
    defer env.deinit();
    var run_env = std.process.Environ.Map.init(t.allocator);
    defer run_env.deinit();
    try run_env.put("OUT", env.root);
    var opts = env.opts();
    opts.allow_shell = true;
    opts.env = &run_env;
    var sf: StubFactory = .{};
    // The shape of `sessions_table_batch_kill.test`: a detached fake
    // left running. It is in the group the App's session scan is
    // scoped to, and the file's end takes it down — it used to live
    // on for a minute, where the next run of the same file found it.
    const path = try env.script("group.test",
        \\shell ( /bin/sleep 30 >/dev/null 2>&1 & echo $! > "$OUT/bg.pid" )
        \\shell [ "$MNML_AGENTS_PGID" -gt 1 ] && [ "$MNML_AGENTS_PGID" -eq $(/bin/ps -o pgid= -p $$) ]
        \\shell read p < "$OUT/bg.pid"; [ "$MNML_AGENTS_PGID" -eq $(/bin/ps -o pgid= -p "$p") ]
        \\
    );
    defer t.allocator.free(path);
    var o = runFile(t.allocator, t.io, sf.factory(), path, content_size, opts);
    try expectPassed(&o);
    const pid_path = try std.fs.path.join(t.allocator, &.{ env.root, "bg.pid" });
    defer t.allocator.free(pid_path);
    const pid_text = try Io.Dir.cwd().readFileAlloc(t.io, pid_path, t.allocator, .limited(64));
    defer t.allocator.free(pid_text);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_text, " \n"), 10);
    // Gone — reaped by init once the group was killed. Polled: the
    // reaping is init's, not ours.
    var alive = true;
    for (0..100) |_| {
        std.posix.kill(pid, @enumFromInt(0)) catch {
            alive = false;
            break;
        };
        t.io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    if (alive) std.posix.kill(pid, .KILL) catch {};
    try t.expect(!alive);
}

test "temp dirs are created exclusively: a name that exists is somebody else's" {
    var env = try TestEnv.init();
    defer env.deinit();
    const a = try makeTempDir(t.allocator, t.io, env.root);
    defer t.allocator.free(a);
    const b = try makeTempDir(t.allocator, t.io, env.root);
    defer t.allocator.free(b);
    try t.expect(!std.mem.eql(u8, a, b));
    try t.expectError(error.PathAlreadyExists, createFresh(t.io, a));
}

test "retry_flaky: a file that fails then passes is FLAKY by name, never a plain ok; one that fails twice is a FAIL; off, the first failure stands" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var env = try TestEnv.init();
    defer env.deinit();
    var run_env = std.process.Environ.Map.init(t.allocator);
    defer run_env.deinit();
    try run_env.put("OUT", env.root);
    var opts = env.opts();
    opts.allow_shell = true;
    opts.env = &run_env;
    var sf: StubFactory = .{};
    // Fails the first time it runs and passes every time after: the
    // shape of a file whose verdict hangs on something outside the code.
    const once = try env.script("once.test", "shell [ -e \"$OUT/ran\" ] || { : > \"$OUT/ran\"; echo first run lost the race >&2; exit 1; }\n");
    defer t.allocator.free(once);
    const always = try env.script("always.test", "shell exit 3\n");
    defer t.allocator.free(always);

    opts.retry_flaky = true;
    {
        var aw: Io.Writer.Allocating = .init(t.allocator);
        defer aw.deinit();
        var stats = try runPaths(t.allocator, t.io, sf.factory(), &.{ once, always }, opts, &aw.writer);
        defer stats.deinit(t.allocator);
        const text = aw.written();
        try t.expectEqual(@as(usize, 2), stats.total);
        try t.expectEqual(@as(usize, 1), stats.failed);
        try t.expectEqual(@as(usize, 1), stats.flaky.items.len);
        // Said as it happens…
        try t.expect(std.mem.indexOf(u8, text, "  ↻    once.test — failed; retrying once: line 1: shell") != null);
        try t.expect(std.mem.indexOf(u8, text, "  FLAKY once.test — first run: line 1: shell") != null);
        try t.expect(std.mem.indexOf(u8, text, "  ok   once.test") == null);
        // …failing twice is a failure…
        try t.expect(std.mem.indexOf(u8, text, "  FAIL always.test — line 1: shell `exit 3` exited exit status: 3: ") != null);
        // …and the trailer counts it and names it, last.
        try t.expect(std.mem.indexOf(u8, text, "\n1/2 passed (2 content, 0 structure-only), 1 FLAKY (passed only on a retry)\nFLAKY once.test — first run: line 1: shell") != null);
        try t.expect(std.mem.endsWith(u8, text, "first run lost the race\n"));
    }

    // Off (`--strict`): the first failure is the verdict.
    const ran = try std.fs.path.join(t.allocator, &.{ env.root, "ran" });
    defer t.allocator.free(ran);
    try Io.Dir.cwd().deleteFile(t.io, ran);
    opts.retry_flaky = false;
    {
        var aw: Io.Writer.Allocating = .init(t.allocator);
        defer aw.deinit();
        var stats = try runPaths(t.allocator, t.io, sf.factory(), &.{once}, opts, &aw.writer);
        defer stats.deinit(t.allocator);
        try t.expectEqual(@as(usize, 1), stats.failed);
        try t.expectEqual(@as(usize, 0), stats.flaky.items.len);
        try t.expect(std.mem.indexOf(u8, aw.written(), "FLAKY") == null);
        try t.expect(std.mem.indexOf(u8, aw.written(), "\n0/1 passed (1 content, 0 structure-only)\n") != null);
    }
}

test "a file's environment is pinned: the corpus's terminal whatever the host's, and git fenced at the temp root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var env = try TestEnv.init();
    defer env.deinit();
    // The host is some other terminal, and says so several ways.
    var run_env = std.process.Environ.Map.init(t.allocator);
    defer run_env.deinit();
    try run_env.put("TERM_PROGRAM", "ghostty");
    try run_env.put("KITTY_WINDOW_ID", "7");
    try run_env.put("TERM", "dumb");
    try run_env.put("ROOT", env.root);
    var opts = env.opts();
    opts.allow_shell = true;
    opts.env = &run_env;
    var sf: StubFactory = .{};
    const path = try env.script("pinned.test",
        \\shell [ "$TERM_PROGRAM" = Apple_Terminal ] && [ "$TERM" = xterm-256color ] && [ "$COLORTERM" = truecolor ] && [ -z "${KITTY_WINDOW_ID+x}" ]
        \\shell [ "$GIT_CEILING_DIRECTORIES" = "$ROOT" ]
        \\
    );
    defer t.allocator.free(path);
    var o = runFile(t.allocator, t.io, sf.factory(), path, content_size, opts);
    try expectPassed(&o);
    // A file that means another terminal still says so, and wins.
    const own = try env.script("own.test",
        \\# env: TERM_PROGRAM=ghostty
        \\shell [ "$TERM_PROGRAM" = ghostty ]
        \\
    );
    defer t.allocator.free(own);
    var o2 = runFile(t.allocator, t.io, sf.factory(), own, content_size, opts);
    try expectPassed(&o2);
}

test "hermeticEnv keeps what a file needs, drops the developer's, and gives it a HOME and AI stand-ins of the run's own" {
    var host = std.process.Environ.Map.init(t.allocator);
    defer host.deinit();
    try host.put("PATH", "/usr/bin:/bin");
    try host.put("HOME", "/Users/dev");
    try host.put("LC_ALL", "C.UTF-8");
    try host.put("MNML_SHIMS", "/repo/tools/shims");
    try host.put("MNML_E2E_FILE_TIMEOUT_SECS", "300");
    // The ones a file must never see.
    try host.put("BITBUCKET_ACCESS_TOKEN", "t");
    try host.put("CLAUDECODE", "1");
    try host.put("MNML_IPC_DIR", "/Users/dev/proj/.mnml/ipc-zig");
    try host.put("XDG_CONFIG_HOME", "/Users/dev/.config");
    try host.put("SHELL", "/opt/homebrew/bin/fish");
    var env = try hermeticEnv(t.allocator, &host, "/run/home");
    defer env.deinit();
    try sdk_testing.expectPath("/run/home", env.get("HOME").?);
    try sdk_testing.expectPath("/repo/tools/shims/ai:/usr/bin:/bin", env.get("PATH").?);
    try t.expectEqualStrings("C.UTF-8", env.get("LC_ALL").?);
    try t.expectEqualStrings("300", env.get("MNML_E2E_FILE_TIMEOUT_SECS").?);
    try sdk_testing.expectPath("/repo/tools/shims", env.get("MNML_SHIMS").?);
    // A terminal pane's shell: macOS's own, else the host's.
    try t.expectEqualStrings(if (builtin.os.tag == .macos) "/bin/zsh" else "/opt/homebrew/bin/fish", env.get("SHELL").?);
    for ([_][]const u8{ "BITBUCKET_ACCESS_TOKEN", "CLAUDECODE", "MNML_IPC_DIR", "XDG_CONFIG_HOME" }) |gone| {
        if (env.get(gone) != null) {
            std.debug.print("{s} leaked into a file's environment\n", .{gone});
            return error.TestUnexpectedResult;
        }
    }
}

test "SHELL reaches a file's environment: a terminal pane gets a real shell, not /bin/sh" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var env = try TestEnv.init();
    defer env.deinit();
    var host = std.process.Environ.Map.init(t.allocator);
    defer host.deinit();
    try host.put("PATH", "/usr/bin:/bin");
    try host.put("SHELL", "/usr/local/bin/some-shell");
    // What `mnml-zig test` hands every file (`main.zig`).
    var base = try hermeticEnv(t.allocator, &host, env.root);
    defer base.deinit();
    const want = if (builtin.os.tag == .macos) "/bin/zsh" else "/usr/local/bin/some-shell";
    var opts = env.opts();
    opts.allow_shell = true;
    opts.env = &base;
    var sf: StubFactory = .{};
    // Read through `env`, not `$SHELL`: the step's `/bin/sh` is bash on
    // macOS, which fills an unset SHELL from the account's login shell
    // (without exporting it) — `$SHELL` would pass with nothing passed.
    const body = try std.fmt.allocPrint(t.allocator, "shell /usr/bin/env | grep -qx 'SHELL={s}'\n", .{want});
    defer t.allocator.free(body);
    const file = try env.script("shell-var.test", body);
    defer t.allocator.free(file);
    var o = runFile(t.allocator, t.io, sf.factory(), file, content_size, opts);
    try expectPassed(&o);
}

test "the git guard fails a file whose git reaches a repository outside the temp root, and passes one that stays inside" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var env = try TestEnv.init();
    defer env.deinit();
    // The temp root is a directory of its own; beside it, "the checkout".
    const tmp_root = try std.fs.path.join(t.allocator, &.{ env.root, "runs" });
    defer t.allocator.free(tmp_root);
    try Io.Dir.cwd().createDirPath(t.io, tmp_root);
    const outside = try std.fs.path.join(t.allocator, &.{ env.root, "checkout" });
    defer t.allocator.free(outside);
    try Io.Dir.cwd().createDirPath(t.io, outside);
    var host = std.process.Environ.Map.init(t.allocator);
    defer host.deinit();
    try host.put("PATH", "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin");
    const guard = (try installGitGuard(t.allocator, t.io, env.root, tmp_root, host.get("PATH"))) orelse return error.SkipZigTest;
    defer deinitGitGuard(t.allocator, guard);
    {
        const r = try std.process.run(t.allocator, t.io, .{ .argv = &.{ "git", "-C", outside, "init", "-q" } });
        t.allocator.free(r.stdout);
        t.allocator.free(r.stderr);
    }
    try host.put("OUT", outside);
    var opts = env.opts();
    opts.tmp_root = tmp_root;
    opts.allow_shell = true;
    opts.env = &host;
    opts.git_guard = guard;
    var sf: StubFactory = .{};
    // Reaching the checkout: `git -C` into it, as a command the App ran
    // with the wrong cwd would.
    const bad = try env.script("reach.test", "shell git -C \"$OUT\" status --porcelain >/dev/null\n");
    defer t.allocator.free(bad);
    var o = runFile(t.allocator, t.io, sf.factory(), bad, content_size, opts);
    defer o.deinit(t.allocator);
    try t.expect(!o.passed);
    try t.expect(std.mem.startsWith(u8, o.message.?, "git ran against a repository outside the run's temp root ("));
    try t.expect(std.mem.indexOf(u8, o.message.?, "git -C ") != null);
    // A repository of the file's own, in its workspace: nothing to say.
    const good = try env.script("own.test", "shell git init -q . && git status --porcelain >/dev/null && git -C . log -1 >/dev/null 2>&1; true\n");
    defer t.allocator.free(good);
    var o2 = runFile(t.allocator, t.io, sf.factory(), good, content_size, opts);
    try expectPassed(&o2);
}
