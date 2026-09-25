//! The trace runner's retry (`tools/test_runner.zig`), kept apart so it
//! can be tested: the runner is the root of every test binary and has no
//! tests of its own.
//!
//! A test that fails is run once more, as a fresh invocation — its own
//! testing allocator and `Io` again, as the first run had. A pass then is
//! a FLAKE: the verdict depended on something other than the code, which
//! is a bug to go and find, so it is named — `FLAKY <test> — first run:
//! <error>` as it happens and again under the summary — and counted in
//! the summary's last field, never folded into `passed`. It does not fail
//! the run. What the corpus runner does for a `.test` file
//! (`src/e2e/runner.zig`, `retry_flaky`), for a unit test.
//!
//! `MNML_TEST_STRICT=1` retries nothing: the first failure stands (what
//! `tools/break-check.sh` runs under — a break has to fail the first
//! time). A test that PANICS is not retried: the panic takes the process
//! down, and the exit code says so.

const std = @import("std");

/// How one invocation of a test ended.
pub const Attempt = union(enum) {
    ok,
    skip,
    fail: anyerror,

    pub fn of(result: anyerror!void) Attempt {
        if (result) |_| return .ok else |err| return switch (err) {
            error.SkipZigTest => .skip,
            else => .{ .fail = err },
        };
    }
};

/// A test's verdict over its one or two runs.
pub const Verdict = union(enum) {
    ok,
    skip,
    /// Failed, and failed again on the retry (or was not retried): the
    /// error the last run returned.
    fail: anyerror,
    /// Failed, then passed on the retry: the error the FIRST run returned.
    flaky: anyerror,
};

/// Whether the environment turns the retry off (`MNML_TEST_STRICT=1`).
pub fn strictFrom(value: ?[]const u8) bool {
    const v = value orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// Run a test through `ctx.attempt()` — one fresh invocation per call —
/// retrying one failure unless `strict`. `ctx.retrying(err)` is called
/// between the two runs (the runner prints its `↻` line there).
pub fn run(ctx: anytype, strict: bool) Verdict {
    const first = Attempt.of(ctx.attempt());
    switch (first) {
        .ok => return .ok,
        .skip => return .skip,
        .fail => |err| {
            if (strict) return .{ .fail = err };
            ctx.retrying(err);
            return switch (Attempt.of(ctx.attempt())) {
                .ok => .{ .flaky = err },
                // A skip on the retry is not a pass: the first run's
                // failure stands.
                .skip => .{ .fail = err },
                .fail => |again| .{ .fail = again },
            };
        },
    }
}

/// The line a flake is reported by, as it happens and in the trailer.
pub fn writeFlaky(w: *std.Io.Writer, name: []const u8, first: anyerror) std.Io.Writer.Error!void {
    try w.print("FLAKY {s} — first run: {t}\n", .{ name, first });
}

pub const Counts = struct { ok: usize = 0, skip: usize = 0, fail: usize = 0, flaky: usize = 0 };

/// The summary: `N passed; S skipped; F failed; K FLAKY.` The first three
/// fields keep the shape scripts grep for (`tools/break-check.sh`); a
/// flake counts in K and not in N.
pub fn writeSummary(w: *std.Io.Writer, c: Counts) std.Io.Writer.Error!void {
    try w.print("{d} passed; {d} skipped; {d} failed; {d} FLAKY.\n", .{ c.ok, c.skip, c.fail, c.flaky });
}

// ── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

/// A test that fails its first `fails` runs, then passes (or skips).
const Scripted = struct {
    fails: usize,
    then_skip: bool = false,
    runs: usize = 0,
    retried: ?anyerror = null,

    fn attempt(s: *Scripted) anyerror!void {
        s.runs += 1;
        if (s.runs <= s.fails) return error.TimedOut;
        if (s.then_skip) return error.SkipZigTest;
    }

    fn retrying(s: *Scripted, err: anyerror) void {
        s.retried = err;
    }
};

test "a test that fails once then passes is FLAKY with the first run's error; one that fails twice is a FAIL; a pass or a skip runs once" {
    var once: Scripted = .{ .fails = 1 };
    try testing.expectEqual(Verdict{ .flaky = error.TimedOut }, run(&once, false));
    try testing.expectEqual(@as(usize, 2), once.runs);
    try testing.expectEqual(@as(?anyerror, error.TimedOut), once.retried);

    var twice: Scripted = .{ .fails = 2 };
    try testing.expectEqual(Verdict{ .fail = error.TimedOut }, run(&twice, false));
    try testing.expectEqual(@as(usize, 2), twice.runs);

    var good: Scripted = .{ .fails = 0 };
    try testing.expectEqual(Verdict.ok, run(&good, false));
    try testing.expectEqual(@as(usize, 1), good.runs);
    try testing.expectEqual(@as(?anyerror, null), good.retried);

    var skip: Scripted = .{ .fails = 0, .then_skip = true };
    try testing.expectEqual(Verdict.skip, run(&skip, false));
    try testing.expectEqual(@as(usize, 1), skip.runs);

    // Failed, then skipped: not a pass.
    var fail_skip: Scripted = .{ .fails = 1, .then_skip = true };
    try testing.expectEqual(Verdict{ .fail = error.TimedOut }, run(&fail_skip, false));
}

test "strict (MNML_TEST_STRICT=1): the first failure stands, nothing is rerun" {
    var once: Scripted = .{ .fails = 1 };
    try testing.expectEqual(Verdict{ .fail = error.TimedOut }, run(&once, true));
    try testing.expectEqual(@as(usize, 1), once.runs);
    try testing.expectEqual(@as(?anyerror, null), once.retried);
    try testing.expect(strictFrom("1"));
    try testing.expect(!strictFrom(null));
    try testing.expect(!strictFrom(""));
    try testing.expect(!strictFrom("0"));
}

test "the report: the FLAKY line names the test and the first run's error; the summary ends with the flake count" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeFlaky(&w, "app.pty_search.test.survives output", error.TestUnexpectedResult);
    try writeSummary(&w, .{ .ok = 10, .skip = 2, .fail = 0, .flaky = 1 });
    try testing.expectEqualStrings(
        "FLAKY app.pty_search.test.survives output — first run: TestUnexpectedResult\n" ++
            "10 passed; 2 skipped; 0 failed; 1 FLAKY.\n",
        w.buffered(),
    );
}
