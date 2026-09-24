const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdk = b.addModule("mnml_sdk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // `warm.zig` calls `std.c.kill` / `std.c.getpid`: libc, spelled
        // out for every target but macOS. Importers inherit it.
        .link_libc = true,
    });

    const tests = b.addTest(.{ .root_module = sdk });
    const test_step = b.step("test", "Run the SDK's unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
