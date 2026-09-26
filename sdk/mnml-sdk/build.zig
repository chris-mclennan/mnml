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
