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
