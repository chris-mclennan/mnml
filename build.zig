const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── terminal core: ghostty-vt ──
    // The emulator is ghostty's `ghostty-vt` Zig module, used as a plain
    // zon dependency (not the C ABI). `emit-lib-vt` keeps ghostty's build
    // in library-only mode. `simd` pulls in simdutf/highway C++ for the
    // UTF-8 fast path; it is a build option so the cross-compile story can
    // be measured both ways (`-Dpty-simd=true`).
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

    // ghostty instantiates exactly ONE `uucode` module (tables generated
    // from its `src/build/uucode_config.zig`) and imports it into
    // `ghostty-vt`. vaxis's `Parser.zig` also `@import("uucode")`. Two
    // uucode instances sharing one `root.zig` on disk is a compile error
    // (`file exists in modules 'uucode' and 'uucode0'`), so vaxis is built
    // with `external_uucode = true` and handed ghostty's module — exactly
    // what ghostty's own `SharedDeps.zig` does for its vaxis import.
    const uucode_mod = ghostty_vt.import_table.get("uucode") orelse
        @panic("ghostty-vt no longer imports 'uucode'; update the vaxis uucode wiring");

    // ── terminal layer: libvaxis ──
    // Screen (cell store), Parser, Vaxis.render (diff + output) and
    // Capabilities. We drive it on our own std.Io.Writer instead of its
    // Tty/Loop, so only the module is wired here.
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
        .external_uucode = true,
    });
    const vaxis_mod = vaxis_dep.module("vaxis");
    vaxis_mod.addImport("uucode", uucode_mod);

    // ── pty ──
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

    // ── main executable ──
    const exe = b.addExecutable(.{
        .name = "mnml-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // Io.Threaded can only interrupt a blocked tty read (cancelation
            // via pthread_kill(SIGIO)) when libc is linked.
            .link_libc = true,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis_mod },
                .{ .name = "pty", .module = pty_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run mnml-zig");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // ── tests ──
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // src/ui is reached through its barrel so every primitive's tests run
    // under `zig build test` on std.testing.allocator (leak = failure).
    const ui_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui/ui.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(ui_tests).step);

    const pty_tests = b.addTest(.{ .root_module = pty_mod });
    const pty_test_run = b.addRunArtifact(pty_tests);
    const pty_test_step = b.step("pty-test", "Run the pty module tests");
    pty_test_step.dependOn(&pty_test_run.step);
    test_step.dependOn(&pty_test_run.step);

    // ── pty-demo ──
    // The spike's proving ground: a login shell in a ghostty-vt Terminal,
    // painted with plain ANSI. Throwaway once vaxis hosts the pane.
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("src/pty_demo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    demo_mod.addImport("pty", pty_mod);
    const demo = b.addExecutable(.{ .name = "pty-demo", .root_module = demo_mod });
    const demo_install = b.addInstallArtifact(demo, .{});
    const demo_run = b.addRunArtifact(demo);
    demo_run.step.dependOn(&demo_install.step);
    if (b.args) |args| demo_run.addArgs(args);
    const demo_step = b.step("pty-demo", "Run the pty demo (a shell in a ghostty-vt Terminal)");
    demo_step.dependOn(&demo_run.step);

    const pty_step = b.step("pty", "Build the pty module, its tests and the demo without running");
    pty_step.dependOn(&pty_tests.step);
    pty_step.dependOn(&demo_install.step);
}
