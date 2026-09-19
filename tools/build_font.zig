//! `zig build font` — write the shipped `MnmlSymbols.ttf`.
//!
//! The face mnml's own block is drawn from, built out of the SVGs in
//! `data/glyphs/` by `src/glyph/builder.zig`. It lands at
//! `share/mnml/fonts/MnmlSymbols.ttf` under the install prefix, beside
//! the Lua script set and found the same way (`scripts/package.sh`,
//! `nfpm/mnml.yaml`, `dist/`).
//!
//!     build-font <out.ttf>
//!
//! One argument, no options: what the face carries is a property of the
//! repo, not of the invocation.

const std = @import("std");
const Io = std.Io;
const builder = @import("glyph");

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var stderr_buf: [4096]u8 = undefined;
    var stderr_file: Io.File.Writer = .initStreaming(.stderr(), init.io, &stderr_buf);
    const err = &stderr_file.interface;
    defer err.flush() catch {};
    if (args.len != 2) {
        try err.writeAll("usage: build-font <out.ttf>\n");
        return 2;
    }
    const bytes = builder.buildDefault(arena) catch |e| {
        try err.print("build-font: {s}\n", .{@errorName(e)});
        return 1;
    };
    if (std.fs.path.dirname(args[1])) |dir| Io.Dir.cwd().createDirPath(init.io, dir) catch {};
    try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = bytes });
    // Silent on success: a build step that writes to stderr makes the
    // build print `failed command:` beside a step that worked.
    return 0;
}
