//! The answers every OS spells differently, in one place: where home
//! is, where temp is, how `PATH` splits and how a bare command name
//! resolves through it, what `~` expands to, and where the path ends in
//! a `path:line:col` location when the path may begin with a drive
//! letter.
//!
//! The rules are a value (`Rules.posix`, `Rules.win`) rather than a
//! `builtin.os.tag` switch buried in each function, so the Windows
//! answers are unit-tested on every host — the cross-build only proves
//! Windows code compiles, and nothing runs it. `Rules.native` is what
//! the app passes. Only `which` touches the file system.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Map = std.process.Environ.Map;

pub const Rules = struct {
    /// Between the entries of `PATH`.
    delimiter: u8,
    /// What a join writes between two components.
    sep: u8,
    /// Windows: `\` is a separator too, a path may start with a drive
    /// (`C:`), and a bare name also resolves with each `PATHEXT` suffix.
    drives: bool,

    pub const posix: Rules = .{ .delimiter = ':', .sep = '/', .drives = false };
    pub const win: Rules = .{ .delimiter = ';', .sep = '\\', .drives = true };
    pub const native: Rules = if (builtin.os.tag == .windows) win else posix;

    pub fn isSep(r: Rules, c: u8) bool {
        return c == '/' or (r.drives and c == '\\');
    }

    /// `C:` at the front.
    pub fn hasDrive(r: Rules, p: []const u8) bool {
        return r.drives and p.len >= 2 and std.ascii.isAlphabetic(p[0]) and p[1] == ':';
    }

    /// Whether `name` names a place rather than something to look up on
    /// `PATH`: it has a separator or a drive.
    pub fn hasDirPart(r: Rules, name: []const u8) bool {
        if (r.hasDrive(name)) return true;
        for (name) |c| if (r.isSep(c)) return true;
        return false;
    }
};

fn nonEmpty(env: *const Map, key: []const u8) ?[]const u8 {
    const v = env.get(key) orelse return null;
    return if (v.len == 0) null else v;
}

/// The user's home: `$HOME`, else `%USERPROFILE%` (Windows sets no
/// `HOME`; MSYS and Git Bash set both, and `HOME` wins there). An empty
/// value counts as unset.
pub fn home(env: *const Map) ?[]const u8 {
    return nonEmpty(env, "HOME") orelse nonEmpty(env, "USERPROFILE");
}

/// The temp directory: `$TMPDIR` (POSIX), else `%TEMP%` / `%TMP%`
/// (Windows), else the platform's fixed answer.
pub fn tempDir(env: *const Map, r: Rules) []const u8 {
    return nonEmpty(env, "TMPDIR") orelse nonEmpty(env, "TEMP") orelse nonEmpty(env, "TMP") orelse
        if (r.drives) "C:\\Windows\\Temp" else "/tmp";
}

/// `~` → `home`; `~/rest` (and `~\rest` under Windows rules) →
/// `home` joined with `rest`. Anything else — `~user`, no home — comes
/// back unchanged. The result is `path`, `home`, or allocated in `arena`.
pub fn expandTilde(arena: Allocator, path: []const u8, home_dir: ?[]const u8, r: Rules) Allocator.Error![]const u8 {
    const h = home_dir orelse return path;
    if (path.len == 0 or path[0] != '~') return path;
    if (path.len == 1) return h;
    if (!r.isSep(path[1])) return path;
    const rest = path[2..];
    if (rest.len == 0) return h;
    const trimmed = std.mem.trimEnd(u8, h, if (r.drives) "/\\" else "/");
    return std.fmt.allocPrint(arena, "{s}{c}{s}", .{ trimmed, r.sep, rest });
}

/// A `path:line:col:text` location (a compiler's, grep's, `:cexpr`'s)
/// split at the colon that ends the path. Under Windows rules a leading
/// drive — `C:\src\a.zig:12:3: msg` — is part of the path, not a field.
pub const Location = struct {
    path: []const u8,
    /// Everything after the path's colon (`12:3: msg`); empty when the
    /// line had none.
    rest: []const u8,
};

pub fn splitLocation(line: []const u8, r: Rules) Location {
    const from: usize = if (r.hasDrive(line) and line.len > 2 and r.isSep(line[2])) 2 else 0;
    const colon = std.mem.indexOfScalarPos(u8, line, from, ':') orelse return .{ .path = line, .rest = "" };
    return .{ .path = line[0..colon], .rest = line[colon + 1 ..] };
}

/// The paths a bare `name` may resolve to, in the order the OS tries
/// them: each non-empty `PATH` entry with `name` itself, then (Windows
/// rules) `name` with each `PATHEXT` suffix — how `CreateProcessW` and
/// `cmd.exe` find `git.exe` for `git` and `npm.cmd` for `npm`.
pub const Candidates = struct {
    dirs: std.mem.SplitIterator(u8, .scalar),
    pathext: []const u8,
    name: []const u8,
    r: Rules,
    dir: ?[]const u8 = null,
    exts: ?std.mem.SplitIterator(u8, .scalar) = null,

    pub fn init(path_var: []const u8, pathext: []const u8, name: []const u8, r: Rules) Candidates {
        return .{ .dirs = std.mem.splitScalar(u8, path_var, r.delimiter), .pathext = if (r.drives) pathext else "", .name = name, .r = r };
    }

    /// The next candidate, written into `buf`; null when there is none
    /// left. One too long for `buf` is skipped.
    pub fn next(self: *Candidates, buf: []u8) ?[]const u8 {
        while (true) {
            if (self.exts) |*it| {
                while (it.next()) |ext| {
                    if (ext.len == 0) continue;
                    return self.join(buf, ext) orelse continue;
                }
                self.exts = null;
            }
            const d = self.dirs.next() orelse return null;
            if (d.len == 0) continue;
            self.dir = d;
            self.exts = std.mem.splitScalar(u8, self.pathext, ';');
            return self.join(buf, "") orelse continue;
        }
    }

    fn join(self: *const Candidates, buf: []u8, ext: []const u8) ?[]const u8 {
        const d = self.dir.?;
        const sep = [1]u8{self.r.sep};
        const glue: []const u8 = if (self.r.isSep(d[d.len - 1])) "" else &sep;
        return std.fmt.bufPrint(buf, "{s}{s}{s}{s}", .{ d, glue, self.name, ext }) catch null;
    }
};

/// Where `name` runs from: itself when it names a place and is a file,
/// else the first `Candidates` entry that is a file (a directory of the
/// same name does not count). The answer is `name` or lives in `buf`.
/// The map is the App's own environment — a spawn resolves a bare
/// argv[0] against the PROCESS's `PATH`, which may differ, so a caller
/// about to spawn should spawn the path this returns.
/// Whether `a` and `b` name one path as the platform reads it: on
/// Windows `/` and `\` are one separator, so `D:\ws\a` and
/// `D:\ws/a` are the same file; elsewhere the bytes must match.
pub fn samePath(a: []const u8, b: []const u8) bool {
    return samePathWith(a, b, Rules.native);
}

pub fn samePathWith(a: []const u8, b: []const u8, r: Rules) bool {
    if (!r.drives) return std.mem.eql(u8, a, b);
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y and !(r.isSep(x) and r.isSep(y))) return false;
    return true;
}

pub fn which(io: Io, env: *const Map, buf: []u8, name: []const u8) ?[]const u8 {
    return whichWith(io, env, buf, name, Rules.native);
}

pub fn whichWith(io: Io, env: *const Map, buf: []u8, name: []const u8, r: Rules) ?[]const u8 {
    if (name.len == 0) return null;
    if (r.hasDirPart(name)) return if (isFile(io, name)) name else null;
    var it = Candidates.init(env.get("PATH") orelse return null, env.get("PATHEXT") orelse "", name, r);
    while (it.next(buf)) |p| if (isFile(io, p)) return p;
    return null;
}

fn isFile(io: Io, p: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind != .directory;
}

// ─── tests: every rule set on every host ─────────────────────────────────

const testing = std.testing;

/// `expectEqualStrings` for an optional: a null is a failed test, not a
/// panic that takes the rest of the binary's tests with it.
fn expectSome(want: []const u8, got: ?[]const u8) !void {
    try testing.expectEqualStrings(want, got orelse return error.TestExpectedSome);
}

test "home: HOME, then USERPROFILE; empty is unset" {
    var env = Map.init(testing.allocator);
    defer env.deinit();
    try testing.expect(home(&env) == null);
    try env.put("USERPROFILE", "C:\\Users\\ada");
    try expectSome("C:\\Users\\ada", home(&env));
    try env.put("HOME", "");
    try expectSome("C:\\Users\\ada", home(&env));
    try env.put("HOME", "/home/ada");
    try expectSome("/home/ada", home(&env));
}

test "tempDir: TMPDIR, TEMP, TMP, then the platform's fixed answer" {
    var env = Map.init(testing.allocator);
    defer env.deinit();
    try testing.expectEqualStrings("/tmp", tempDir(&env, Rules.posix));
    try testing.expectEqualStrings("C:\\Windows\\Temp", tempDir(&env, Rules.win));
    try env.put("TMP", "C:\\t2");
    try testing.expectEqualStrings("C:\\t2", tempDir(&env, Rules.win));
    try env.put("TEMP", "C:\\t1");
    try testing.expectEqualStrings("C:\\t1", tempDir(&env, Rules.win));
    try env.put("TMPDIR", "");
    try testing.expectEqualStrings("C:\\t1", tempDir(&env, Rules.posix));
    try env.put("TMPDIR", "/var/tmp");
    try testing.expectEqualStrings("/var/tmp", tempDir(&env, Rules.posix));
}

test "hasDirPart: separators under both rules, drives only under Windows" {
    try testing.expect(!Rules.posix.hasDirPart("rg"));
    try testing.expect(Rules.posix.hasDirPart("./rg"));
    try testing.expect(!Rules.posix.hasDirPart("bin\\rg"));
    try testing.expect(Rules.win.hasDirPart("bin\\rg"));
    try testing.expect(Rules.win.hasDirPart("bin/rg"));
    try testing.expect(Rules.win.hasDirPart("C:rg.exe"));
    try testing.expect(!Rules.posix.hasDirPart("C:rg"));
    try testing.expect(!Rules.win.hasDirPart("rg.exe"));
}

test "expandTilde: ~, ~/x, ~\\x under Windows rules; ~user and no home unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("/home/ada", try expandTilde(a, "~", "/home/ada", Rules.posix));
    try testing.expectEqualStrings("/home/ada/src", try expandTilde(a, "~/src", "/home/ada/", Rules.posix));
    try testing.expectEqualStrings("/home/ada", try expandTilde(a, "~/", "/home/ada", Rules.posix));
    try testing.expectEqualStrings("~\\src", try expandTilde(a, "~\\src", "/home/ada", Rules.posix));
    try testing.expectEqualStrings("C:\\Users\\ada\\src", try expandTilde(a, "~\\src", "C:\\Users\\ada", Rules.win));
    try testing.expectEqualStrings("C:\\Users\\ada\\src/x", try expandTilde(a, "~/src/x", "C:\\Users\\ada\\", Rules.win));
    try testing.expectEqualStrings("~bob/src", try expandTilde(a, "~bob/src", "/home/ada", Rules.posix));
    try testing.expectEqualStrings("~/src", try expandTilde(a, "~/src", null, Rules.posix));
    try testing.expectEqualStrings("src/~", try expandTilde(a, "src/~", "/home/ada", Rules.posix));
}

test "splitLocation: a drive is part of the path under Windows rules only" {
    const w = splitLocation("C:\\src\\a.zig:12:3: error: x", Rules.win);
    try testing.expectEqualStrings("C:\\src\\a.zig", w.path);
    try testing.expectEqualStrings("12:3: error: x", w.rest);
    const fwd = splitLocation("d:/src/a.zig:4", Rules.win);
    try testing.expectEqualStrings("d:/src/a.zig", fwd.path);
    try testing.expectEqualStrings("4", fwd.rest);
    const p = splitLocation("src/a.zig:12:3: error: x", Rules.posix);
    try testing.expectEqualStrings("src/a.zig", p.path);
    try testing.expectEqualStrings("12:3: error: x", p.rest);
    // Relative under Windows rules, and a POSIX line that happens to
    // start `X:` — both split at the first colon.
    try testing.expectEqualStrings("a.zig", splitLocation("a.zig:1:1: m", Rules.win).path);
    try testing.expectEqualStrings("C", splitLocation("C:\\src\\a.zig:1", Rules.posix).path);
    const none = splitLocation("no colons here", Rules.win);
    try testing.expectEqualStrings("no colons here", none.path);
    try testing.expectEqualStrings("", none.rest);
}

fn expectCandidates(want: []const []const u8, path_var: []const u8, pathext: []const u8, name: []const u8, r: Rules) !void {
    var it = Candidates.init(path_var, pathext, name, r);
    var buf: [256]u8 = undefined;
    for (want) |w| {
        const got = it.next(&buf) orelse return error.TooFewCandidates;
        try testing.expectEqualStrings(w, got);
    }
    try testing.expect(it.next(&buf) == null);
}

test "Candidates: Windows splits on ';' and tries each PATHEXT suffix after the bare name" {
    try expectCandidates(&.{
        "C:\\bin\\npm",   "C:\\bin\\npm.EXE",   "C:\\bin\\npm.CMD",
        "D:\\tools\\npm", "D:\\tools\\npm.EXE", "D:\\tools\\npm.CMD",
    }, "C:\\bin;;D:\\tools\\", ".EXE;;.CMD", "npm", Rules.win);
}

test "Candidates: POSIX splits on ':' and ignores PATHEXT" {
    try expectCandidates(&.{ "/usr/bin/rg", "/bin/rg" }, "/usr/bin::/bin/", ".EXE", "rg", Rules.posix);
    try expectCandidates(&.{}, "", "", "rg", Rules.posix);
}

test "which: finds a file on the map's PATH, skips a directory of the same name, honours a path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "a/tool");
    try tmp.dir.createDirPath(testing.io, "b");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/tool", .data = "" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buf);
    const root = root_buf[0..root_len];

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir_a = try std.fs.path.join(a, &.{ root, "a" });
    const dir_b = try std.fs.path.join(a, &.{ root, "b" });
    const want = try std.fs.path.join(a, &.{ dir_b, "tool" });

    var env = Map.init(testing.allocator);
    defer env.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(which(testing.io, &env, &buf, "tool") == null);
    try env.put("PATH", try std.fmt.allocPrint(a, "{s}{c}{s}", .{ dir_a, Rules.native.delimiter, dir_b }));
    try expectSome(want, which(testing.io, &env, &buf, "tool"));
    try testing.expect(which(testing.io, &env, &buf, "absent") == null);
    try expectSome(want, which(testing.io, &env, &buf, want));
    try testing.expect(which(testing.io, &env, &buf, try std.fs.path.join(a, &.{ dir_a, "tool" })) == null);
}

test "samePath: one separator under Windows rules, bytes elsewhere" {
    try testing.expect(samePathWith("D:\\ws\\a", "D:\\ws/a", Rules.win));
    try testing.expect(!samePathWith("D:\\ws\\a", "D:\\ws\\b", Rules.win));
    try testing.expect(!samePathWith("/ws/a", "/ws\\a", Rules.posix));
    try testing.expect(samePathWith("/ws/a", "/ws/a", Rules.posix));
}
