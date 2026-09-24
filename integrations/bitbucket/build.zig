//! A stand-alone build for the Bitbucket integration — the shape an
//! integration's own folder uses: the SDK is a path (or URL) dependency
//! in build.zig.zon. `zig build` puts `mnml-bitbucket` and the fake
//! Bitbucket server (`mnml-fake-bitbucket`, `tools/fake_bitbucket/`) in
//! zig-out/bin; `zig build test` runs both their tests. mnml's root
//! build.zig builds the same sources itself.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdk = b.dependency("mnml_sdk", .{ .target = target, .optimize = optimize });
    const sdk_mod = sdk.module("mnml_sdk");

    const fake_mod = b.createModule(.{
        .root_source_file = b.path("tools/fake_bitbucket/main.zig"),
        .target = target,
        .optimize = optimize,
        // `std.c.kill(parent, 0)`: libc, spelled out for every target
        // but macOS.
        .link_libc = true,
    });
    const fake = b.addExecutable(.{ .name = "mnml-fake-bitbucket", .root_module = fake_mod });
    b.installArtifact(fake);

    const mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "mnml_sdk", .module = sdk_mod }},
    });
    const exe = b.addExecutable(.{ .name = "mnml-bitbucket", .root_module = mod });
    b.installArtifact(exe);

    const test_step = b.step("test", "Run the integration's tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = fake_mod })).step);
}
