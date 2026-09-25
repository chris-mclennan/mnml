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
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        }
        // Anything else (`--listen=-`, `--cache-dir=`) is the build runner's; ignored.
    }
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
        if (filter) |f| if (std.mem.indexOf(u8, test_fn.name, f) == null) continue;
        ran += 1;
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
