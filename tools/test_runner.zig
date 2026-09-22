//! A tracing unit-test runner: `zig build test -Dtest-trace`.
//!
//! The default runner is silent until the suite ends, so a test that
//! wedges the process leaves no name behind. This one prints each test's
//! name *before* it runs (and its outcome + wall time after), and honours
//! a runtime substring filter — `MNML_TEST_FILTER=<substring>` — so one
//! test can be looped on the built binary without a rebuild (the build-time
//! `-Dtest-filter` has reported "passed" while running nothing).
//!
//! The verdict lines carry the test's name, not just its outcome. The
//! suite is read through `grep -E "FAIL|passed;"` far more often than in
//! full, and a bare `  FAIL (...)` line leaves the grep window to pair it
//! with whatever name happened to survive the same filter — which for
//! years was "runPath: skips, sizes, names, and the ok/FAIL/N-M report",
//! the one test name in the repo that contains the word FAIL. Three
//! separate investigations blamed that innocent test.
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

    const test_fns = builtin.test_functions;
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var leaks: usize = 0;
    var ran: usize = 0;
    for (test_fns, 0..) |test_fn, i| {
        if (filter) |f| if (std.mem.indexOf(u8, test_fn.name, f) == null) continue;
        ran += 1;
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        defer {
            testing.io_instance.deinit();
            if (testing.allocator_instance.deinit() == .leak) {
                leaks += 1;
                std.debug.print("  LEAK {s}\n", .{test_fn.name});
            }
        }
        testing.log_level = .warn;
        testing.environ = init.environ;

        std.debug.print("▶ {d}/{d} {s}\n", .{ i + 1, test_fns.len, test_fn.name });
        const t0 = Io.Clock.awake.now(testing.io);
        const result = test_fn.func();
        const ms = @divTrunc(Io.Clock.awake.now(testing.io).nanoseconds - t0.nanoseconds, std.time.ns_per_ms);
        if (result) |_| {
            ok_count += 1;
            std.debug.print("  ok   {d} ms\n", .{ms});
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
                std.debug.print("  SKIP {s}\n", .{test_fn.name});
            },
            else => {
                fail_count += 1;
                std.debug.print("  FAIL {s} ({t}) {d} ms\n", .{ test_fn.name, err, ms });
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
    }
    if (filter) |f| std.debug.print("filter {s}: {d} of {d} tests matched\n", .{ f, ran, test_fns.len });
    std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ ok_count, skip_count, fail_count });
    if (log_err_count != 0) std.debug.print("{d} errors were logged.\n", .{log_err_count});
    if (leaks != 0) std.debug.print("{d} tests leaked memory.\n", .{leaks});
    if (leaks != 0 or log_err_count != 0 or fail_count != 0) std.process.exit(1);
}

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
