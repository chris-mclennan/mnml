//! A stand-alone build for the sample — the shape an integration's own
//! folder uses: the SDK is a path (or URL) dependency in build.zig.zon.
//! `zig build` puts `mnml-sample` in zig-out/bin; `zig build test` runs
//! its tests. mnml's root build.zig builds the same sources itself.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdk = b.dependency("mnml_sdk", .{ .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "mnml_sdk", .module = sdk.module("mnml_sdk") }},
    });
    const exe = b.addExecutable(.{ .name = "mnml-sample", .root_module = mod });
    b.installArtifact(exe);
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run the sample's tests").dependOn(&b.addRunArtifact(tests).step);
}
