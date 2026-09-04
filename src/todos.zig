//! TODOS — the reference module (D8). This file starts as the payload
//! definition the event queue needs; the scan worker, state, commands and
//! panel land with the module proper.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Tag = enum { todo, fixme, xxx, hack, review };

/// One marker hit. Slices borrow from `ScanResult.arena`.
pub const Item = struct {
    tag: Tag,
    /// Workspace-relative path.
    path: []const u8,
    /// 1-based.
    line: u32,
    title: []const u8,
    /// File mtime in seconds; 0 when unknown. Drives Newest/Oldest.
    mtime: i64,
};

/// A finished scan, built by the worker on its own arena and posted as
/// `.todos`. The handler adopts the arena wholesale (snapshot tier).
pub const ScanResult = struct {
    arena: std.heap.ArenaAllocator,
    items: []Item = &.{},
    truncated: bool = false,
    /// Which `refresh` request produced this; stale results are dropped.
    generation: u32,

    pub fn create(gpa: Allocator, generation: u32) Allocator.Error!*ScanResult {
        const r = try gpa.create(ScanResult);
        r.* = .{ .arena = .init(gpa), .generation = generation };
        return r;
    }

    pub fn destroy(self: *ScanResult, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// Runners, merged into `command.runners` at comptime. Filled in with the
/// module proper.
pub const table = .{};
