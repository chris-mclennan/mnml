const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── vaxis ──
    // libvaxis 0.6.0 is the terminal layer: Screen (cell store), Parser,
    // Vaxis.render (diff + output) and Capabilities. We drive it on our own
    // std.Io.Writer instead of its Tty/Loop, so only the module is wired here.
    // uucode is vaxis's lazy dependency; `-Dexternal_uucode` is the seam for
    // sharing one uucode module with ghostty-vt later.
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_mod = vaxis_dep.module("vaxis");

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
            },
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
}
