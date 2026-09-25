//! `zig build unit -Dtest-trace`'s last step: print what each unit-test
//! binary's trace runner wrote, binary by binary, in the order given.
//!
//! The binaries run in parallel with their output captured. A test run
//! that inherits the terminal takes the build runner's stderr lock for
//! its whole run, so under the trace runner the binaries used to run one
//! after another — the suite took half as long again as under the default
//! runner. A binary that FAILS has its trace printed by the build runner
//! itself (and this step, which depends on every run, does not run);
//! a green one's trace — the FLAKY lines, the `filter …` and summary lines
//! `tools/break-check.sh` reads — is printed here. `-Dtest-trace-live`
//! keeps the old live, one-binary-at-a-time output for hunting a hang.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var buf: [64 * 1024]u8 = undefined;
    var out: Io.File.Writer = .initStreaming(.stderr(), init.io, &buf);
    const w = &out.interface;
    defer w.flush() catch {};
    for (args[1..]) |path| {
        const text = Io.Dir.cwd().readFileAlloc(init.io, path, arena, .unlimited) catch |err| {
            try w.print("trace-report: cannot read {s}: {t}\n", .{ path, err });
            return 1;
        };
        try w.writeAll(text);
    }
    return 0;
}
