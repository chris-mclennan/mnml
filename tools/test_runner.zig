//! A tracing unit-test runner: `zig build test -Dtest-trace`.
//!
//! The default runner is silent until the suite ends, so a test that
//! wedges the process leaves no name behind. This one prints each test's
//! name *before* it runs (and its outcome + wall time after), and honours
//! a runtime substring filter — `MNML_TEST_FILTER=<substring>` — so one
//! test can be looped on the built binary without a rebuild (the build-time
//! `-Dtest-filter` has reported "passed" while running nothing), and a
//! runtime seed — `MNML_TEST_SEED=<n>`, what `--seed` sets under the
//! default runner — for the tests seeded from `std.testing.random_seed`.
//!
//! The verdict lines carry the test's name, not just its outcome. The
//! suite is read through `grep -E "FAIL|passed;"` far more often than in
//! full, and a bare `  FAIL (...)` line leaves the grep window to pair it
//! with whatever name happened to survive the same filter — which for
//! years was "runPath: skips, sizes, names, and the ok/FAIL/N-M report",
//! the one test name in the repo that contains the word FAIL. Three
//! separate investigations blamed that innocent test.
//!
//! A test that fails is run once more, afresh (`tools/test_retry.zig`):
//! a pass then prints `FLAKY <test> — first run: <error>` and counts in
//! the summary's last field (`N passed; S skipped; F failed; K FLAKY.`)
//! instead of failing the run — a timing flake is named, not a red
//! chain. `MNML_TEST_STRICT=1` retries nothing. A test that panics takes
//! the process down and is not retried.
//!
//! A test that WEDGES — no progress for `MNML_TEST_WEDGE_SECS` (300 by
//! default; 0 turns it off) — is named too: the supervising parent watches
//! the child's progress file, and when it stops moving it samples the
//! child's threads (`/usr/bin/sample` on macOS: the stacks of every thread,
//! which is what a wedge needs and what a timeout throws away), kills it,
//! prints `WEDGED <test>`, and goes on from the next test; the run fails.
//! The macOS runner sat on one broker test for forty minutes with nothing
//! but its name in the log before this existed.
//!
//! Per test it does what `lib/compiler/test_runner.zig` does: a fresh
//! `testing.allocator_instance` (a leak is a failure) and a fresh
//! `testing.io_instance` (`Io.Threaded`, its worker pool joined in
//! `deinit`). "simple" mode: outcome is the exit code, no build-server
//! protocol.

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const retry = @import("test_retry.zig");

pub const std_options: std.Options = .{ .logFn = log };

/// How a test tells it is running under this runner: `@import("root")`
/// is the runner in a test build. A test that has a table worth
/// printing (`src/glyph/builder.zig`'s placed boxes) prints it here,
/// where stderr is already streaming names, and stays quiet under the
/// default runner, where any output makes the build runner report
/// `failed command:` beside a step that passed.
pub const traces = true;

var log_err_count: usize = 0;
var fba_buffer: [8192]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);

pub fn main(init: std.process.Init.Minimal) void {
    const args = init.args.toSlice(fba.allocator()) catch |err| std.debug.panic("unable to parse command line args: {t}", .{err});
    var child = false;
    var from: usize = 1;
    var progress: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else if (std.mem.eql(u8, arg, "--child")) {
            child = true;
        } else if (std.mem.startsWith(u8, arg, "--from=")) {
            from = std.fmt.parseUnsigned(usize, arg["--from=".len..], 10) catch @panic("unable to parse --from");
        } else if (std.mem.startsWith(u8, arg, "--progress=")) {
            progress = arg["--progress=".len..];
        }
        // Anything else (`--listen=-`, `--cache-dir=`) is the build runner's; ignored.
    }
    if (!child) return supervise(init, args);
    runner_io = .init(std.heap.page_allocator, .{});
    const filter: ?[]const u8 = if (builtin.os.tag == .windows) null else init.environ.getPosix("MNML_TEST_FILTER");
    // The build runner hands `--seed=` only to a runner in its protocol
    // mode, never to this one, so `testing.random_seed` is 0 here unless
    // `MNML_TEST_SEED=<n>` names one: how a seed a seeded test printed
    // (the undo property's rounds) is rerun under the trace.
    if (builtin.os.tag != .windows) if (init.environ.getPosix("MNML_TEST_SEED")) |text| {
        testing.random_seed = std.fmt.parseUnsigned(u32, text, 0) catch
            @panic("unable to parse MNML_TEST_SEED");
    };
    // Named up front, so a test that panics — no error to catch and
    // print — still leaves the seed it ran under in the log.
    if (testing.random_seed != 0) std.debug.print("seed 0x{x}\n", .{testing.random_seed});

    const test_fns = builtin.test_functions;
    const strict = if (builtin.os.tag == .windows) false else retry.strictFrom(init.environ.getPosix("MNML_TEST_STRICT"));
    var counts: retry.Counts = .{};
    var leaks: usize = 0;
    var ran: usize = 0;
    // The flakes, named again under the summary; a fixed table, as the
    // runner allocates from nothing that outlives a test.
    var flaky_idx: [64]usize = undefined;
    var flaky_err: [64]anyerror = undefined;
    for (test_fns, 0..) |test_fn, i| {
        if (i + 1 < from) continue;
        if (filter) |f| if (std.mem.indexOf(u8, test_fn.name, f) == null) continue;
        ran += 1;
        if (progress) |p| markProgress(runner_io.io(), p, i + 1);
        std.debug.print("▶ {d}/{d} {s}\n", .{ i + 1, test_fns.len, test_fn.name });
        var one: One = .{ .init = init, .test_fn = test_fn, .leaks = &leaks };
        const errors_before = log_err_count;
        const verdict = retry.run(&one, strict);
        switch (verdict) {
            .ok => {
                counts.ok += 1;
                std.debug.print("  ok   {d} ms\n", .{one.ms});
            },
            .skip => {
                counts.skip += 1;
                std.debug.print("  SKIP {s}\n", .{test_fn.name});
            },
            .fail => |err| {
                counts.fail += 1;
                std.debug.print("  FAIL {s} ({t}) {d} ms\n", .{ test_fn.name, err, one.ms });
                if (one.trace()) |trace| std.debug.dumpErrorReturnTrace(&trace);
            },
            .flaky => |err| {
                // Errors the failed run logged were part of its failure;
                // the retry's own still count.
                log_err_count = errors_before + one.errors_on_retry;
                if (counts.flaky < flaky_idx.len) {
                    flaky_idx[counts.flaky] = i;
                    flaky_err[counts.flaky] = err;
                }
                counts.flaky += 1;
                std.debug.print("  ok   {d} ms (retry)\n  ", .{one.ms});
                reportFlaky(test_fn.name, err);
            },
        }
    }
    if (filter) |f| std.debug.print("filter {s}: {d} of {d} tests matched\n", .{ f, ran, test_fns.len });
    {
        var buf: [256]u8 = undefined;
        const stderr = std.debug.lockStderr(&buf);
        defer std.debug.unlockStderr();
        const w = &stderr.file_writer.interface;
        retry.writeSummary(w, counts) catch {};
        for (0..@min(counts.flaky, flaky_idx.len)) |k| retry.writeFlaky(w, test_fns[flaky_idx[k]].name, flaky_err[k]) catch {};
        w.flush() catch {};
    }
    if (log_err_count != 0) std.debug.print("{d} errors were logged.\n", .{log_err_count});
    if (leaks != 0) std.debug.print("{d} tests leaked memory.\n", .{leaks});
    if (leaks != 0 or log_err_count != 0 or counts.fail != 0) std.process.exit(1);
}

/// The runner proper runs in a child; this parent only restarts it. A
/// test that panics takes its process down, and with it every test after
/// it: one crash hid 2280 of the main binary's 2536 tests on the suite's
/// first Windows run. So the parent starts the child again just past the
/// test that crashed, names that test `CRASH`, and fails the run at the
/// end. The child writes the number of the test it is about to run to a
/// progress file beside the binary, which is how the parent knows where
/// it died.
fn supervise(init: std.process.Init.Minimal, args: []const [:0]const u8) void {
    const gpa = std.heap.page_allocator;
    // The child's environment is this process's: an Io made without one
    // spawns on Windows with an empty block — no PATH, so no `git`, no
    // `cmd.exe`, in any test.
    var threaded: Io.Threaded = .init(gpa, .{ .argv0 = .init(init.args), .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();
    const test_fns = builtin.test_functions;

    var name_buf: [64]u8 = undefined;
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const progress = std.fmt.bufPrint(&name_buf, "test-progress-{x}", .{std.mem.readInt(u64, &nonce, .little)}) catch unreachable;
    // Beside the test binary, in the build's cache: nowhere a checkout sees.
    const progress_path = std.fs.path.join(gpa, &.{ std.fs.path.dirname(args[0]) orelse ".", progress }) catch @panic("OOM");
    defer Io.Dir.cwd().deleteFile(io, progress_path) catch {};

    const wedge_secs = wedgeSecs(init);
    var from: usize = 1;
    var crashes: usize = 0;
    var code: u8 = 0;
    while (from <= test_fns.len) {
        var argv: std.ArrayList([]const u8) = .empty;
        for (args) |a| {
            if (std.mem.startsWith(u8, a, "--from=") or std.mem.startsWith(u8, a, "--progress=")) continue;
            argv.append(gpa, a) catch @panic("OOM");
        }
        argv.append(gpa, "--child") catch @panic("OOM");
        argv.append(gpa, std.fmt.allocPrint(gpa, "--from={d}", .{from}) catch @panic("OOM")) catch @panic("OOM");
        argv.append(gpa, std.fmt.allocPrint(gpa, "--progress={s}", .{progress_path}) catch @panic("OOM")) catch @panic("OOM");
        Io.Dir.cwd().deleteFile(io, progress_path) catch {};
        var proc = std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .inherit, .stderr = .inherit }) catch |err|
            std.debug.panic("test runner: cannot start the suite: {t}", .{err});
        var watch: Watchdog = .{
            .io = io,
            .progress_path = progress_path,
            .pid = undefined,
            .started = Io.Clock.awake.now(io),
            .limit_ns = @as(i96, wedge_secs) * std.time.ns_per_s,
        };
        // Windows is left out at comptime: `Child.Id` is a handle there,
        // and the watchdog signals a pid. (Its Debug step streams names
        // live, and that is what named the first Windows wedge.)
        const watcher: ?std.Thread = if (builtin.os.tag != .windows and wedge_secs > 0) blk: {
            watch.pid = proc.id orelse break :blk null;
            break :blk std.Thread.spawn(.{}, Watchdog.run, .{&watch}) catch null;
        } else null;
        const term = proc.wait(io) catch |err| std.debug.panic("test runner: lost the suite: {t}", .{err});
        watch.done.store(true, .release);
        if (watcher) |th| th.join();
        // The child ends its own run with 0 or 1; anything else — a
        // signal, or Windows' exit code 3 from a panic — is a crash.
        switch (term) {
            .exited => |c| if (c <= 1) {
                code = c;
                break;
            },
            else => {},
        }
        var buf: [32]u8 = undefined;
        const text = Io.Dir.cwd().readFile(io, progress_path, &buf) catch "";
        const at = std.fmt.parseUnsigned(usize, std.mem.trim(u8, text, " \n"), 10) catch {
            std.debug.print("  CRASH before the first test ran ({any}); giving up\n", .{term});
            std.process.exit(1);
        };
        crashes += 1;
        if (watch.fired.load(.acquire)) {
            std.debug.print("  WEDGED {s} — no progress for {d} s, killed; the suite goes on from the next test\n", .{ test_fns[at - 1].name, wedge_secs });
        } else {
            std.debug.print("  CRASH {s} ({any}) — the suite goes on from the next test\n", .{ test_fns[at - 1].name, term });
        }
        from = at + 1;
    }
    if (crashes != 0) {
        std.debug.print("{d} tests crashed the process.\n", .{crashes});
        std.process.exit(1);
    }
    std.process.exit(code);
}

/// `MNML_TEST_WEDGE_SECS`: how long one test may run before the parent
/// calls it wedged. 300 unless set; 0 turns the watchdog off.
fn wedgeSecs(init: std.process.Init.Minimal) u32 {
    if (builtin.os.tag == .windows) return 0;
    const text = init.environ.getPosix("MNML_TEST_WEDGE_SECS") orelse return 300;
    return std.fmt.parseUnsigned(u32, std.mem.trim(u8, text, " \n"), 10) catch 300;
}

/// The parent's watch on the child: the progress file's mtime is when the
/// current test started. Stalled past the limit, the child's threads are
/// sampled (macOS) and it is killed; `wait` in the parent then sees a
/// signal and the crash path names the test, as `WEDGED` rather than
/// `CRASH`. A plain thread, not a task: it has to outlive any Io wedge.
const Watchdog = struct {
    io: Io,
    progress_path: []const u8,
    pid: std.process.Child.Id,
    started: Io.Timestamp,
    limit_ns: i96,
    done: std.atomic.Value(bool) = .init(false),
    fired: std.atomic.Value(bool) = .init(false),

    fn run(w: *Watchdog) void {
        // The awake clock, not the wall clock and not the file's mtime: a
        // laptop that slept for an hour mid-suite wakes with every test
        // "stalled" by an hour on either of those, and the first night
        // this ran it called a 2.5-second test WEDGED that way.
        var last_text: [24]u8 = undefined;
        var last_len: usize = 0;
        var last_change = w.started;
        //
        // Through the Io, never `std.c`: this runner is the root of every
        // test binary, and on Linux most of those do not link libc — a
        // direct libc call fails them all at compile time.
        while (!w.done.load(.acquire)) {
            w.io.sleep(.fromSeconds(1), .awake) catch {};
            if (w.done.load(.acquire)) return;
            var buf: [24]u8 = undefined;
            const text = Io.Dir.cwd().readFile(w.io, w.progress_path, &buf) catch "";
            const now = Io.Clock.awake.now(w.io);
            if (!std.mem.eql(u8, text, last_text[0..last_len])) {
                last_len = @min(text.len, last_text.len);
                @memcpy(last_text[0..last_len], text[0..last_len]);
                last_change = now;
                continue;
            }
            if (now.nanoseconds - last_change.nanoseconds < w.limit_ns) continue;
            w.fired.store(true, .release);
            std.debug.print("  WEDGED: no progress for {d} s; sampling pid {d} before killing it\n", .{ @divTrunc(w.limit_ns, std.time.ns_per_s), w.pid });
            w.sample();
            // The sample took a second; a test that finished meanwhile is
            // slow, not wedged, and its pid is not ours to signal.
            if (w.done.load(.acquire)) return;
            std.posix.kill(w.pid, .KILL) catch {};
            return;
        }
    }

    /// Every thread's stack, from the outside: what a wedge needs and a
    /// step timeout throws away. macOS only; elsewhere the name is all.
    /// lldb first — it unwinds by the binary's own unwind tables, where
    /// `sample`'s first runner report was fifty frames of dyld noise —
    /// then `sample` as the fallback. Both to stderr, where the build
    /// runner forwards a test step's output (its stdout it keeps), and
    /// never to `sample`'s default file under /tmp.
    fn sample(w: *Watchdog) void {
        if (builtin.os.tag != .macos) return;
        var pid_buf: [16]u8 = undefined;
        const pid = std.fmt.bufPrint(&pid_buf, "{d}", .{w.pid}) catch return;
        // lldb prints to stdout; `1>&2` moves it where the log is.
        if (std.process.spawn(w.io, .{
            .argv = &.{ "/bin/sh", "-c", "exec /usr/bin/xcrun lldb --batch -p \"$1\" -o 'thread backtrace all' -o detach -o quit 1>&2", "sh", pid },
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        })) |proc| {
            var p = proc;
            const term = p.wait(w.io) catch null;
            if (term) |t| if (t == .exited and t.exited == 0) return;
        } else |_| {}
        var proc = std.process.spawn(w.io, .{
            .argv = &.{ "/usr/bin/sample", pid, "1", "-mayDie", "-file", "/dev/stderr" },
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch return;
        _ = proc.wait(w.io) catch {};
    }
};

/// The runner's own Io, for the progress file: `testing.io` belongs to
/// the test and is torn down between them.
var runner_io: Io.Threaded = undefined;

fn markProgress(io: Io, path: []const u8, index: usize) void {
    var buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{index}) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch {};
}

fn reportFlaky(name: []const u8, err: anyerror) void {
    var buf: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buf);
    defer std.debug.unlockStderr();
    const w = &stderr.file_writer.interface;
    retry.writeFlaky(w, name, err) catch {};
    w.flush() catch {};
}

/// One test, invoked afresh per `attempt`: what `lib/compiler/test_runner.zig`
/// sets up per test — a fresh `testing.allocator_instance` (a leak is a
/// failure) and a fresh `testing.io_instance` (`Io.Threaded`, its worker
/// pool joined in `deinit`) — so a retry starts from what the first run
/// started from.
const One = struct {
    init: std.process.Init.Minimal,
    test_fn: std.builtin.TestFn,
    leaks: *usize,
    runs: usize = 0,
    ms: i64 = 0,
    errors_on_retry: usize = 0,
    /// The last failed run's error return trace, copied while it still
    /// holds the test's frames (the retry logic handles the error, and
    /// the trace is gone by the time the verdict is printed).
    trace_addrs: [32]usize = undefined,
    trace_len: usize = 0,
    trace_index: usize = 0,

    fn trace(o: *One) ?std.builtin.StackTrace {
        if (o.trace_len == 0) return null;
        return .{ .index = o.trace_index, .instruction_addresses = o.trace_addrs[0..o.trace_len] };
    }

    pub fn attempt(o: *One) anyerror!void {
        o.runs += 1;
        const errors_before = log_err_count;
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(o.init.args),
            .environ = o.init.environ,
        });
        defer {
            testing.io_instance.deinit();
            if (testing.allocator_instance.deinit() == .leak) {
                o.leaks.* += 1;
                std.debug.print("  LEAK {s}\n", .{o.test_fn.name});
            }
            if (o.runs > 1) o.errors_on_retry = log_err_count - errors_before;
        }
        testing.log_level = .warn;
        testing.environ = o.init.environ;
        const t0 = Io.Clock.awake.now(testing.io);
        defer o.ms = @intCast(@divTrunc(Io.Clock.awake.now(testing.io).nanoseconds - t0.nanoseconds, std.time.ns_per_ms));
        o.test_fn.func() catch |err| {
            o.trace_len = 0;
            if (@errorReturnTrace()) |t| {
                const n = @min(t.instruction_addresses.len, o.trace_addrs.len);
                @memcpy(o.trace_addrs[0..n], t.instruction_addresses[0..n]);
                o.trace_len = n;
                o.trace_index = t.index;
            }
            return err;
        };
    }

    /// Between the runs: the first one's failure, by name. (Its error
    /// return trace is gone by here — the retry logic handled the error.)
    pub fn retrying(o: *One, err: anyerror) void {
        std.debug.print("  ↻    {s} — failed ({t}) in {d} ms; retrying once\n", .{ o.test_fn.name, err, o.ms });
    }
};

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) log_err_count +|= 1;
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n", args);
    }
}

/// `std.testing.fuzz` calls `@import("root").fuzz`. This runner is never
/// built in fuzz mode, so it does what the default runner does outside
/// one: run the corpus, then an empty input as a smoke test.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), *testing.Smith) anyerror!void,
    options: testing.FuzzInputOptions,
) anyerror!void {
    for (options.corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
    var smith: testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}
