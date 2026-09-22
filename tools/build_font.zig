//! `zig build font` — write the shipped `MnmlSymbols.ttf`.
//!
//! The face mnml's own block is drawn from, built out of the SVGs in
//! `data/glyphs/` by `src/glyph/builder.zig`. It lands at
//! `share/mnml/fonts/MnmlSymbols.ttf` under the install prefix, beside
//! the Lua script set and found the same way (`scripts/package.sh`,
//! `nfpm/mnml.yaml`, `dist/`).
//!
//!     build-font <out.ttf>
//!     build-font merge <installed.ttf> <out.ttf>
//!
//! The first form writes what the repo bakes; what that face carries is
//! a property of the repo, not of the invocation.
//!
//! The second is what `run.sh install-font` runs when a MnmlSymbols is
//! already installed. An installed face may carry codepoints this repo
//! has no source for (the Rust-era integration chips), so it is read
//! back and merged rather than overwritten — see `builder.merge`. It
//! prints one line saying what it kept, replaced, added and dropped,
//! because an installer that says nothing about a merge is one nobody
//! can check.

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
    const merging = args.len == 4 and std.mem.eql(u8, args[1], "merge");
    if (args.len != 2 and !merging) {
        try err.writeAll("usage: build-font <out.ttf> | build-font merge <installed.ttf> <out.ttf>\n");
        return 2;
    }
    const out_path = if (merging) args[3] else args[1];
    var report: builder.MergeReport = .{};
    const bytes = blk: {
        if (!merging) break :blk builder.buildDefault(arena) catch |e| {
            try err.print("build-font: {s}\n", .{@errorName(e)});
            return 1;
        };
        const installed = Io.Dir.cwd().readFileAlloc(init.io, args[2], arena, .unlimited) catch |e| {
            try err.print("build-font: cannot read {s}: {s}\n", .{ args[2], @errorName(e) });
            return 1;
        };
        break :blk builder.merge(arena, installed, .{}, &report) catch |e| {
            try err.print("build-font: cannot merge {s}: {s}\n", .{ args[2], @errorName(e) });
            return 1;
        };
    };
    if (std.fs.path.dirname(out_path)) |dir| Io.Dir.cwd().createDirPath(init.io, dir) catch {};
    try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = bytes });
    if (merging) try err.print(
        "merged {s}: {d} codepoints ({d} kept, {d} replaced, {d} added, {d} unmapped outline{s} dropped)\n",
        .{ out_path, report.total, report.kept, report.replaced, report.added, report.stripped, if (report.stripped == 1) "" else "s" },
    );
    // Silent on a plain build: a build step that writes to stderr makes
    // the build print `failed command:` beside a step that worked.
    return 0;
}
