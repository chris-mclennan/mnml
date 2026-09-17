//! A stand-alone build for the Jira integration — the shape an
//! integration's own folder uses: the SDK is a path (or URL) dependency
//! in build.zig.zon. `zig build` puts `mnml-jira` in zig-out/bin (and
//! `mnml-fake-jira`, the offline server the tests drive); `zig build
//! test` runs the unit suite. mnml's root build.zig builds the same
//! sources itself so `zig build` at the repo root picks the integration
//! up the way it picks up the sample.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdk = b.dependency("mnml_sdk", .{ .target = target, .optimize = optimize });
    const sdk_mod = sdk.module("mnml_sdk");

    const mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "mnml_sdk", .module = sdk_mod }},
    });
    const exe = b.addExecutable(.{ .name = "mnml-jira", .root_module = mod });
    b.installArtifact(exe);

    // The fake server: a deterministic Jira on the loopback, so every
    // test — unit and corpus — runs offline.
    const fake_mod = b.createModule(.{
        .root_source_file = b.path("tools/fake_jira/main.zig"),
        .target = target,
        .optimize = optimize,
        // `--pid-file` writes `std.c.getpid()`: libc, spelled out for every
        // target but macOS.
        .link_libc = true,
    });
    const fake = b.addExecutable(.{ .name = "mnml-fake-jira", .root_module = fake_mod });
    b.installArtifact(fake);

    const test_step = b.step("test", "Run the Jira integration's tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = fake_mod })).step);
}
