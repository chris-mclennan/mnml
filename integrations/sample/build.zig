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
    llvmForX86Debug(b, target, optimize);
}

/// The twin of the root build.zig's `llvmForX86Debug`: every x86_64
/// Debug compile goes through LLVM, because Zig 0.16's own x86_64 code
/// generator crashes on this tree. Sub-builds cannot import the root's
/// helper, so the fifteen lines live here too.
fn llvmForX86Debug(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    if (optimize != .Debug or target.result.cpu.arch != .x86_64) return;
    var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    var it = b.top_level_steps.iterator();
    while (it.next()) |e| walkForLlvm(b, &e.value_ptr.*.step, &seen);
}

fn walkForLlvm(b: *std.Build, step: *std.Build.Step, seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void)) void {
    if (seen.contains(step)) return;
    seen.put(b.allocator, step, {}) catch @panic("OOM");
    if (step.cast(std.Build.Step.Compile)) |c| {
        if (c.root_module.resolved_target.?.result.cpu.arch == .x86_64) c.use_llvm = true;
    }
    for (step.dependencies.items) |d| walkForLlvm(b, d, seen);
}
