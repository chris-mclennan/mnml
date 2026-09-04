//! `Map(V)` — a user-keyed config section (`.lsp.<name>`, `.keys.global.<chord>`,
//! `.snippets.<scope>.<trigger>`, …). A thin wrapper over
//! `StringArrayHashMapUnmanaged` that keeps file order, so a settings
//! screen lists entries the way the user wrote them.
//!
//! `std.zon.parse` has no map type, which is why these sections are
//! walked name-by-name by `decode.zig` instead of handed to the std
//! parser. The wrapper's `is_config_map` marker is how `Patch` and the
//! decoder recognise one at comptime.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Map(comptime V: type) type {
    return struct {
        const Self = @This();

        /// Comptime marker for `isMap`.
        pub const is_config_map = true;
        pub const Value = V;

        entries: std.StringArrayHashMapUnmanaged(V) = .empty,

        pub const empty: Self = .{};

        /// Keys and values are borrowed — the caller's arena owns them.
        pub fn put(self: *Self, gpa: Allocator, key: []const u8, value: V) Allocator.Error!void {
            try self.entries.put(gpa, key, value);
        }

        pub fn get(self: Self, key: []const u8) ?V {
            return self.entries.get(key);
        }

        pub fn getPtr(self: *Self, key: []const u8) ?*V {
            return self.entries.getPtr(key);
        }

        pub fn getOrPut(self: *Self, gpa: Allocator, key: []const u8) Allocator.Error!std.StringArrayHashMapUnmanaged(V).GetOrPutResult {
            return self.entries.getOrPut(gpa, key);
        }

        pub fn contains(self: Self, key: []const u8) bool {
            return self.entries.contains(key);
        }

        pub fn count(self: Self) usize {
            return self.entries.count();
        }

        pub fn keys(self: Self) []const []const u8 {
            return self.entries.keys();
        }

        pub fn values(self: Self) []V {
            return self.entries.values();
        }

        pub fn iterator(self: *const Self) std.StringArrayHashMapUnmanaged(V).Iterator {
            return self.entries.iterator();
        }

        pub fn clear(self: *Self) void {
            self.entries.clearRetainingCapacity();
        }

        /// Frees the table only. Keys and values belong to whoever
        /// allocated them (an arena, in every real caller).
        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.entries.deinit(gpa);
            self.* = .{};
        }
    };
}

/// `true` for any `Map(V)` instantiation.
pub fn isMap(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "is_config_map");
}

test "Map keeps insertion order and frees only its table" {
    const gpa = std.testing.allocator;
    var m: Map(u8) = .empty;
    defer m.deinit(gpa);
    try m.put(gpa, "zeta", 1);
    try m.put(gpa, "alpha", 2);
    try m.put(gpa, "zeta", 3);
    try std.testing.expectEqual(@as(usize, 2), m.count());
    try std.testing.expectEqualStrings("zeta", m.keys()[0]);
    try std.testing.expectEqual(@as(u8, 3), m.get("zeta").?);
    try std.testing.expect(isMap(Map(u8)));
    try std.testing.expect(!isMap(struct { a: u8 }));
}
