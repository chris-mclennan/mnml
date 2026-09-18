//! Allocation tiers (D1). Every allocation in mnml-zig belongs to exactly
//! one of three tiers; the tier decides who frees it and when.
//!
//! | tier     | type                        | lifetime          | freed by                     |
//! |----------|-----------------------------|-------------------|------------------------------|
//! | gpa      | `Allocator` from `App.init` | process           | owner's `deinit`             |
//! | snapshot | `SnapshotArena`             | until next dataset| `replace` / `reset`          |
//! | frame    | `FrameArena`                | one loop iteration| `FrameArena.begin` (nobody)  |
//!
//! `page_allocator` is reserved for pty ring buffers. Nothing else may use
//! it, and no `test` block may use anything but `std.testing.allocator`.
//!
//! String ownership is spelled by the field TYPE, not by a comment:
//! `[]u8` ⇒ owned by the holder (gpa, freed in its `deinit`);
//! `[]const u8` ⇒ borrowed (literal, snapshot arena, or frame arena) and
//! never freed by the holder. Anything borrowed that must outlive the
//! iteration is `gpa.dupe`d at the boundary. See `docs/CONVENTIONS.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

/// The per-iteration arena. `begin` is called once at the top of every
/// loop iteration (dispatch → tick → render); everything allocated from
/// `allocator()` after that is gone at the next `begin`. Holding a frame
/// pointer across iterations is a use-after-free — the DebugAllocator in
/// Debug/ReleaseSafe builds will catch it.
pub const FrameArena = struct {
    arena: ArenaAllocator,

    pub fn init(gpa: Allocator) FrameArena {
        return .{ .arena = ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *FrameArena) void {
        self.arena.deinit();
    }

    /// What a reset keeps. A steady-state frame is well under this; a
    /// one-off giant frame gives its memory back instead of pinning it
    /// for the life of the process.
    pub const retain_limit = 8 << 20;

    /// Reset for a new iteration. Capacity is retained (up to
    /// `retain_limit`) so a steady-state frame allocates nothing from
    /// the backing allocator.
    pub fn begin(self: *FrameArena) void {
        _ = self.arena.reset(.{ .retain_with_limit = retain_limit });
    }

    pub fn allocator(self: *FrameArena) Allocator {
        return self.arena.allocator();
    }
};

/// One arena per replace-wholesale dataset (LSP diagnostics for a file,
/// git status, a TODO scan, an HTTP response). The owner keeps the
/// dataset's slices pointing into `allocator()`; when the replacement
/// lands it calls `reset` and re-copies. Consumers therefore only ever
/// see a complete, consistent dataset — never a half-updated one.
///
/// Workers build their result in their OWN arena (owned by the event
/// payload); the UI-thread handler adopts that arena by swapping it in.
pub const SnapshotArena = struct {
    arena: ArenaAllocator,

    pub fn init(gpa: Allocator) SnapshotArena {
        return .{ .arena = ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *SnapshotArena) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *SnapshotArena) Allocator {
        return self.arena.allocator();
    }

    /// Drop the current dataset. Every slice previously handed out from
    /// this arena is invalid after this call.
    pub fn reset(self: *SnapshotArena) void {
        _ = self.arena.reset(.retain_capacity);
    }

    /// Adopt `incoming` as the new dataset: the old arena is freed and
    /// the incoming one takes its place. `incoming` must have been built
    /// on the same gpa. After this the caller must not touch `incoming`.
    pub fn replace(self: *SnapshotArena, incoming: *SnapshotArena) void {
        self.arena.deinit();
        self.arena = incoming.arena;
        incoming.arena = ArenaAllocator.init(self.arena.child_allocator);
    }
};

/// The gpa mnml-zig runs on. Debug and ReleaseSafe get the DebugAllocator
/// so `deinit` reports leaks; ReleaseFast/ReleaseSmall get the lock-free
/// SMP allocator. Tests never use this — they use `std.testing.allocator`.
pub const Gpa = struct {
    debug: if (use_debug) std.heap.DebugAllocator(.{}) else void,

    const use_debug = switch (@import("builtin").mode) {
        .Debug, .ReleaseSafe => true,
        .ReleaseFast, .ReleaseSmall => false,
    };

    pub const init: Gpa = .{ .debug = if (use_debug) .init else {} };

    pub fn allocator(self: *Gpa) Allocator {
        return if (use_debug) self.debug.allocator() else std.heap.smp_allocator;
    }

    /// Returns `.leak` when the DebugAllocator saw leaks. Callers in
    /// `main` turn that into a non-zero exit so CI notices.
    pub fn deinit(self: *Gpa) std.heap.Check {
        return if (use_debug) self.debug.deinit() else .ok;
    }
};

test "frame arena: begin frees everything from the previous iteration" {
    var frame = FrameArena.init(std.testing.allocator);
    defer frame.deinit();
    const a = try frame.allocator().alloc(u8, 1024);
    @memset(a, 'x');
    frame.begin();
    // Not a leak: the arena owns the memory; `deinit` returns it. The
    // testing allocator would flag a leak if `begin` lost track of it.
    const b = try frame.allocator().alloc(u8, 16);
    try std.testing.expectEqual(@as(usize, 16), b.len);
}

test "frame arena: one giant frame does not pin its memory — the next begin gives back all but the retain limit" {
    var frame = FrameArena.init(std.testing.allocator);
    defer frame.deinit();
    _ = try frame.allocator().alloc(u8, 4 * FrameArena.retain_limit);
    try std.testing.expect(frame.arena.queryCapacity() >= 4 * FrameArena.retain_limit);
    frame.begin();
    try std.testing.expect(frame.arena.queryCapacity() <= FrameArena.retain_limit);
    // A small frame keeps what it had: nothing to allocate next time.
    _ = try frame.allocator().alloc(u8, 4096);
    const kept = frame.arena.queryCapacity();
    frame.begin();
    try std.testing.expectEqual(kept, frame.arena.queryCapacity());
}

test "snapshot arena: replace adopts the incoming dataset" {
    var live = SnapshotArena.init(std.testing.allocator);
    defer live.deinit();
    const old = try live.allocator().dupe(u8, "old dataset");
    try std.testing.expectEqualStrings("old dataset", old);

    var incoming = SnapshotArena.init(std.testing.allocator);
    defer incoming.deinit();
    const fresh = try incoming.allocator().dupe(u8, "fresh dataset");
    live.replace(&incoming);
    // `fresh` still points into the arena `live` now owns.
    try std.testing.expectEqualStrings("fresh dataset", fresh);
    // `incoming` is usable again (empty) — no double free at its deinit.
    _ = try incoming.allocator().alloc(u8, 4);
}
