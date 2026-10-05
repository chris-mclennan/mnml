//! Writing a saved file without ever leaving it torn.
//!
//! A save goes to a sibling temp file in the target's own directory,
//! is synced, then renamed over the target: until the rename the old
//! bytes are on disk untouched, so a full disk, a quota, a dropped
//! share or a crash mid-write costs the new text, never the file.
//!
//! The rename is skipped — the file is rewritten in place, as before —
//! where replacing the directory entry would change what the user has:
//! - a file with more than one hard link (a rename would detach this
//!   path from the others, which would stop seeing the edit);
//! - anything that is not a regular file (a fifo, a device);
//! - a dangling symlink (the write creates the link's target);
//! - a directory the user cannot create files in (the file itself may
//!   still be writable).
//! A symlink is followed: the temp file lands beside the TARGET and
//! replaces it, so the link keeps pointing where it did. The mode is
//! copied onto the temp file before the rename. Ownership, extended
//! attributes and ACLs are not carried over (a rename cannot keep them;
//! a file shared across users is usually hard-linked or group-owned by
//! its directory, and the in-place path covers the former).

const std = @import("std");
const repeat = @import("mnml_sdk").zig_compat.repeat;
const Io = std.Io;
const Dir = Io.Dir;

pub const Outcome = enum {
    /// Written to a temp file and renamed over the target.
    replaced,
    /// Rewritten in place (see the module doc for when).
    in_place,
};

pub const Error = Dir.WriteFileError || Io.File.SyncError || Dir.RenameError || Io.File.SetPermissionsError;

/// Where `write` would go and how, decided before a byte is written —
/// the caller's failure message depends on it ("untouched" is only
/// true of `.replaced`).
pub const Plan = struct {
    outcome: Outcome,
    /// The file to write: the symlink's target when `path` is a link.
    target_buf: [std.fs.max_path_bytes]u8 = undefined,
    target_len: usize = 0,
    permissions: Io.File.Permissions = .default_file,

    pub fn target(p: *const Plan) []const u8 {
        return p.target_buf[0..p.target_len];
    }
};

pub fn plan(io: Io, path: []const u8) Plan {
    var p: Plan = .{ .outcome = .in_place };
    const real_n = Dir.cwd().realPathFile(io, path, &p.target_buf) catch {
        // No file yet (or a dangling link): nothing on disk to protect
        // unless it is the link, which only an in-place write keeps.
        const link = if (Dir.cwd().statFile(io, path, .{ .follow_symlinks = false })) |st| st.kind == .sym_link else |_| false;
        @memcpy(p.target_buf[0..path.len], path);
        p.target_len = path.len;
        p.outcome = if (link) .in_place else .replaced;
        return p;
    };
    p.target_len = real_n;
    const st = Dir.cwd().statFile(io, p.target(), .{}) catch return p;
    if (st.kind != .file or st.nlink > 1) return p;
    p.permissions = st.permissions;
    p.outcome = .replaced;
    return p;
}

/// Write `data` to `path` (see the module doc); returns what it did.
pub fn write(io: Io, path: []const u8, data: []const u8) Error!Outcome {
    var p = plan(io, path);
    return writePlanned(io, &p, data, null);
}

/// A failure injected after `after_bytes` of the temp file are written —
/// the tests' stand-in for a full disk.
pub const Fault = struct { after_bytes: usize, err: Error };

pub fn writePlanned(io: Io, p: *Plan, data: []const u8, fault: ?Fault) Error!Outcome {
    const target = p.target();
    if (p.outcome == .in_place) {
        try writeInPlace(io, target, data, fault);
        return .in_place;
    }
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = std.fs.path.dirname(target) orelse ".";
    const base = std.fs.path.basename(target);
    const seed: u64 = @truncate(@as(u96, @bitCast(Io.Timestamp.now(io, .real).nanoseconds)));
    var attempt: u64 = 0;
    const tmp, const file = while (true) : (attempt += 1) {
        const tmp = std.fmt.bufPrint(&name_buf, "{s}/.{s}.mnml-save-{x}", .{ dir_path, base, seed +% attempt }) catch {
            // The temp name does not fit — the in-place write still does.
            p.outcome = .in_place;
            try writeInPlace(io, target, data, fault);
            return .in_place;
        };
        const f = Dir.cwd().createFile(io, tmp, .{ .exclusive = true, .permissions = p.permissions }) catch |err| switch (err) {
            error.PathAlreadyExists => if (attempt < 16) continue else return err,
            // A directory that refuses new files; the file may not.
            error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem, error.NameTooLong => {
                p.outcome = .in_place;
                try writeInPlace(io, target, data, fault);
                return .in_place;
            },
            else => return err,
        };
        break .{ tmp, f };
    };
    errdefer Dir.cwd().deleteFile(io, tmp) catch {};
    {
        defer file.close(io);
        try writeAll(io, file, data, fault);
        // The umask narrowed the create; the target's mode is the answer.
        file.setPermissions(io, p.permissions) catch {};
        try file.sync(io);
    }
    try Dir.rename(Dir.cwd(), tmp, Dir.cwd(), target, io);
    return .replaced;
}

fn writeInPlace(io: Io, target: []const u8, data: []const u8, fault: ?Fault) Error!void {
    const file = try Dir.cwd().createFile(io, target, .{});
    defer file.close(io);
    try writeAll(io, file, data, fault);
}

fn writeAll(io: Io, file: Io.File, data: []const u8, fault: ?Fault) Error!void {
    if (fault) |f| if (f.after_bytes < data.len) {
        try file.writeStreamingAll(io, data[0..f.after_bytes]);
        return f.err;
    };
    try file.writeStreamingAll(io, data);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn tmpPath(tmp: *testing.TmpDir, buf: []u8, name: []const u8) ![]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &root);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ root[0..n], name });
}

fn countEntries(tmp: *testing.TmpDir) !usize {
    var it = tmp.dir.iterate();
    var n: usize = 0;
    while (try it.next(testing.io)) |_| n += 1;
    return n;
}

test "a save that fails part-way leaves the old file whole, and no temp file behind" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const old = repeat("x", 4096);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.txt", .data = old });
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &pb, "big.txt");
    var p = plan(testing.io, path);
    try testing.expectEqual(Outcome.replaced, p.outcome);
    const new = repeat("y", 8192);
    try testing.expectError(error.NoSpaceLeft, writePlanned(testing.io, &p, new, .{ .after_bytes = 100, .err = error.NoSpaceLeft }));
    const back = try tmp.dir.readFileAlloc(testing.io, "big.txt", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(old, back);
    try testing.expectEqual(@as(usize, 1), try countEntries(&tmp));
    // Without a fault the new bytes land, the mode survives. Windows
    // has no mode bits (`Permissions` is attributes there), so the
    // mode half is POSIX's; the bytes half runs everywhere.
    const posix_modes = @import("builtin").os.tag != .windows;
    if (posix_modes) try tmp.dir.setFilePermissions(testing.io, "big.txt", Io.File.Permissions.fromMode(0o640), .{});
    try testing.expectEqual(Outcome.replaced, try write(testing.io, path, new));
    const st = try tmp.dir.statFile(testing.io, "big.txt", .{});
    try testing.expectEqual(@as(usize, new.len), st.size);
    if (posix_modes) try testing.expectEqual(@as(u32, 0o640), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    try testing.expectEqual(@as(usize, 1), try countEntries(&tmp));
}

test "a symlink keeps pointing at its target, which takes the new bytes; a hard-linked file is written in place" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "real.txt", .data = "old" });
    try tmp.dir.symLink(testing.io, "real.txt", "link.txt", .{});
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const link = try tmpPath(&tmp, &pb, "link.txt");
    try testing.expectEqual(Outcome.replaced, try write(testing.io, link, "new"));
    var lb: [64]u8 = undefined;
    const n = try tmp.dir.readLink(testing.io, "link.txt", &lb);
    try testing.expectEqualStrings("real.txt", lb[0..n]);
    var rb: [16]u8 = undefined;
    try testing.expectEqualStrings("new", try tmp.dir.readFile(testing.io, "real.txt", &rb));
    // Two names, one file: both see the save.
    try tmp.dir.hardLink("real.txt", tmp.dir, "twin.txt", testing.io, .{});
    var pb2: [std.fs.max_path_bytes]u8 = undefined;
    const real = try tmpPath(&tmp, &pb2, "real.txt");
    try testing.expectEqual(Outcome.in_place, try write(testing.io, real, "both"));
    try testing.expectEqualStrings("both", try tmp.dir.readFile(testing.io, "twin.txt", &rb));
    try testing.expectEqual(@as(u64, 2), (try tmp.dir.statFile(testing.io, "real.txt", .{})).nlink);
    // A new file is created whole.
    var pb3: [std.fs.max_path_bytes]u8 = undefined;
    const fresh = try tmpPath(&tmp, &pb3, "fresh.txt");
    try testing.expectEqual(Outcome.replaced, try write(testing.io, fresh, "hi"));
    try testing.expectEqualStrings("hi", try tmp.dir.readFile(testing.io, "fresh.txt", &rb));
}
