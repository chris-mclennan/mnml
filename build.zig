const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── trunk ──
    // `-Dpartial` downgrades "command id has no runner" from a compile
    // error to a runtime toast. The spike ships with it ON because only
    // the todos runners exist; parity flips it OFF so a missing runner
    // fails the build (D5).
    const partial = b.option(bool, "partial", "Allow command ids without runners (spike builds)") orelse true;
    const build_options = b.addOptions();
    build_options.addOption(bool, "partial", partial);
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addOptions("build_options", build_options);
    // ── end trunk ──

    const exe = b.addExecutable(.{
        .name = "mnml-zig",
        .root_module = root_module,
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
