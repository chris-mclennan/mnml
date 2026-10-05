const std = @import("std");

// `zig build run -Dghostty=pinned` or `-Dghostty=main`. Each name is a lazy
// dependency in build.zig.zon, so only the selected one is fetched.
// `-Dexpect=broken` or `-Dexpect=fixed` makes the run a check: it exits 0
// only when what it observed is what was expected (see src/main.zig).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const which = b.option([]const u8, "ghostty", "Which ghostty dependency to build against (pinned | main)") orelse "pinned";

    const dep_name = if (std.mem.eql(u8, which, "main"))
        "ghostty_main"
    else if (std.mem.eql(u8, which, "pinned"))
        "ghostty_pinned"
    else
        @panic("-Dghostty must be 'pinned' or 'main'");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Library-only mode: `emit-lib-vt` keeps ghostty's build from
    // configuring the app, the same way a libghostty-vt embedder uses it.
    if (b.lazyDependency(dep_name, .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
        // No simdutf/highway C++ (the default links libc++).
        .simd = false,
    })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const exe = b.addExecutable(.{ .name = "resize-repro", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.option([]const u8, "expect", "Exit 0 only when the observed state is this (broken | fixed)")) |e| {
        if (!std.mem.eql(u8, e, "broken") and !std.mem.eql(u8, e, "fixed"))
            @panic("-Dexpect must be 'broken' or 'fixed'");
        run.addArg(b.fmt("--expect={s}", .{e}));
    }
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the repro").dependOn(&run.step);
}
