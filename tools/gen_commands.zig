//! `zig build docs` — `docs/commands.md` from the comptime spec table.
//!
//! The page itself is `src/commands/reference.zig` (`render`), which
//! `view.commands_reference` opens in the editor too; this is the thin
//! `main` that writes it to a file. Runs as `gen-commands <out path>`;
//! the build passes `docs/commands.md`.

const std = @import("std");
const reference = @import("reference");

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: gen-commands <out.md>\n", .{});
        return error.Usage;
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    try reference.render(arena, &out.writer);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = out.written() });
    std.debug.print("{d} commands in {d} groups → {s}\n", .{ reference.specs.len, reference.groups.len, args[1] });
}

test {
    // The page's own test runs with the tool's (`zig build test`).
    _ = reference;
}
