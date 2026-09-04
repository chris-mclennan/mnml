const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "mnml-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run mnml-zig");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // ── pty ──
    // The terminal emulator core is ghostty's `ghostty-vt` Zig module, used
    // as a plain zon dependency (not the C ABI). `emit-lib-vt` keeps
    // ghostty's build in library-only mode (no app, no xcframework, no docs).
    // `simd` pulls in simdutf/highway C++ for the UTF-8 fast path; it is a
    // build option here so the cross-compile story can be measured with it
    // both ways (`-Dpty-simd=true`).
    //
    // ghostty instantiates exactly one `uucode` module and imports it into
    // `ghostty-vt`. When vaxis joins this build, vaxis must be handed that
    // same `*Module` (`external_uucode = true`) — two uucode instances
    // sharing one root.zig on disk is a compile error (`'uucode' and
    // 'uucode0'`). ghostty's `src/build/SharedDeps.zig` documents the trap.
    const pty_simd = b.option(
        bool,
        "pty-simd",
        "Build ghostty-vt with its simdutf/highway C++ fast paths (default: false)",
    ) orelse false;
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
        .simd = pty_simd,
    });
    const ghostty_vt = ghostty_dep.module("ghostty-vt");

    // `pty` is the reusable library module: ring, session, grid read-out.
    // It links libc for openpty/fork/execve/ioctl — Zig 0.16's std.posix
    // does not declare those, so they are reached through std.c and a local
    // extern (see src/pty/session.zig).
    const pty_mod = b.addModule("pty", .{
        .root_source_file = b.path("src/pty/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    pty_mod.addImport("ghostty-vt", ghostty_vt);

    const pty_tests = b.addTest(.{ .root_module = pty_mod });
    const pty_test_run = b.addRunArtifact(pty_tests);
    const pty_test_step = b.step("pty-test", "Run the pty module tests");
    pty_test_step.dependOn(&pty_test_run.step);
    test_step.dependOn(&pty_test_run.step);

    const pty_step = b.step("pty", "Build the pty module (and its tests) without running");
    pty_step.dependOn(&pty_tests.step);
}
