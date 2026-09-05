//! A stand-alone build for the sample, the shape an integration's own
//! repo uses: the SDK is a path (or URL) dependency in build.zig.zon.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdk = b.dependency("mnml_sdk", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "mnml-hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mnml_sdk", .module = sdk.module("mnml_sdk") }},
        }),
    });
    b.installArtifact(exe);
}
