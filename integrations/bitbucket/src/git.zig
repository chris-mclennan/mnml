//! `c` — check the focused PR's source branch out in mnml's workspace.
//!
//! The one thing this module exists to do is **refuse**. Checking a
//! branch out is the only action in the pane that touches the user's
//! working tree, and the failure a hurried version ships is checking
//! `chris/fix-login` out in whatever directory mnml happened to open —
//! a different repo, or no repo at all. So the decision is made before
//! any git command runs, in `check`, which is pure and tested:
//!
//!   * the workspace must be a git repo,
//!   * its `origin` must be the PR's repo (`<workspace>/<repo>`, in
//!     either the https or the ssh spelling),
//!   * the working tree must be clean, and
//!   * the config's `mnml.allow_checkout` must be on.
//!
//! Only then does `checkout` fetch and switch.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Refusal = enum {
    not_allowed,
    not_a_repo,
    no_origin,
    wrong_repo,
    dirty,

    pub fn message(r: Refusal) []const u8 {
        return switch (r) {
            .not_allowed => "checkout is off in config.zon (`mnml.allow_checkout`)",
            .not_a_repo => "the workspace is not a git repository",
            .no_origin => "the workspace has no `origin` remote",
            .wrong_repo => "the workspace is a clone of another repository",
            .dirty => "the working tree has uncommitted changes",
        };
    }
};

pub const Verdict = union(enum) {
    go,
    refuse: Refusal,
};

pub const Facts = struct {
    allow_checkout: bool = true,
    is_repo: bool = false,
    /// The `origin` URL as git reports it; "" when there is none.
    origin: []const u8 = "",
    clean: bool = false,
};

/// The whole decision, with no side effects — what the confirm shows
/// and what the corpus checks.
pub fn check(f: Facts, workspace: []const u8, repo: []const u8) Verdict {
    if (!f.allow_checkout) return .{ .refuse = .not_allowed };
    if (!f.is_repo) return .{ .refuse = .not_a_repo };
    if (f.origin.len == 0) return .{ .refuse = .no_origin };
    if (!originMatches(f.origin, workspace, repo)) return .{ .refuse = .wrong_repo };
    if (!f.clean) return .{ .refuse = .dirty };
    return .go;
}

/// Does this `origin` point at `<workspace>/<repo>`? Bitbucket writes
/// the same remote five ways; all of them end in the same two path
/// segments, so that is what is compared.
pub fn originMatches(origin_in: []const u8, workspace: []const u8, repo: []const u8) bool {
    var origin = std.mem.trim(u8, origin_in, " \t\r\n");
    if (std.mem.endsWith(u8, origin, "/")) origin = origin[0 .. origin.len - 1];
    if (std.mem.endsWith(u8, origin, ".git")) origin = origin[0 .. origin.len - 4];
    // `git@bitbucket.org:acme/api` — the colon is the path start.
    if (std.mem.lastIndexOfScalar(u8, origin, ':')) |colon| {
        // Not a `https://` scheme colon: a port or an scp-style host.
        const after = origin[colon + 1 ..];
        if (after.len > 0 and !std.mem.startsWith(u8, after, "//")) origin = after;
    }
    const slash = std.mem.lastIndexOfScalar(u8, origin, '/') orelse return false;
    const got_repo = origin[slash + 1 ..];
    const head = origin[0..slash];
    const slash2 = std.mem.lastIndexOfScalar(u8, head, '/');
    const got_ws = if (slash2) |i| head[i + 1 ..] else head;
    return std.ascii.eqlIgnoreCase(got_repo, repo) and std.ascii.eqlIgnoreCase(got_ws, workspace);
}

// ─── the git commands ────────────────────────────────────────────────────

pub const Outcome = struct {
    ok: bool,
    /// Owned by the arena passed in.
    message: []const u8,
};

/// Ask git what `check` needs to know. Never fails: a git that is not
/// installed reads as "not a repo".
pub fn facts(gpa: Allocator, io: Io, dir: []const u8, allow_checkout: bool) Allocator.Error!Facts {
    var out: Facts = .{ .allow_checkout = allow_checkout };
    const inside = try run(gpa, io, dir, &.{ "git", "rev-parse", "--is-inside-work-tree" });
    defer freeRun(gpa, inside);
    if (!inside.ok) return out;
    out.is_repo = std.mem.startsWith(u8, std.mem.trim(u8, inside.stdout, " \r\n"), "true");
    if (!out.is_repo) return out;
    const origin = try run(gpa, io, dir, &.{ "git", "remote", "get-url", "origin" });
    defer freeRun(gpa, origin);
    if (origin.ok) out.origin = try gpa.dupe(u8, std.mem.trim(u8, origin.stdout, " \r\n"));
    const status = try run(gpa, io, dir, &.{ "git", "status", "--porcelain" });
    defer freeRun(gpa, status);
    out.clean = status.ok and std.mem.trim(u8, status.stdout, " \r\n").len == 0;
    return out;
}

/// Fetch the branch and switch to it. The caller has already run
/// `check`; this is the part with side effects.
pub fn checkout(arena: Allocator, io: Io, dir: []const u8, branch: []const u8) Allocator.Error!Outcome {
    const fetch = try run(arena, io, dir, &.{ "git", "fetch", "origin", branch });
    if (!fetch.ok) return .{ .ok = false, .message = try std.fmt.allocPrint(arena, "git fetch origin {s}: {s}", .{ branch, firstLine(fetch.stderr) }) };
    const sw = try run(arena, io, dir, &.{ "git", "checkout", branch });
    if (!sw.ok) return .{ .ok = false, .message = try std.fmt.allocPrint(arena, "git checkout {s}: {s}", .{ branch, firstLine(sw.stderr) }) };
    return .{ .ok = true, .message = try std.fmt.allocPrint(arena, "checked out {s}", .{branch}) };
}

const Run = struct { ok: bool, stdout: []u8, stderr: []u8 };

fn run(gpa: Allocator, io: Io, dir: []const u8, argv: []const []const u8) Allocator.Error!Run {
    const res = std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = dir },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .ok = false, .stdout = try gpa.dupe(u8, ""), .stderr = try std.fmt.allocPrint(gpa, "{s}", .{@errorName(err)}) },
    };
    return .{
        .ok = switch (res.term) {
            .exited => |c| c == 0,
            else => false,
        },
        .stdout = res.stdout,
        .stderr = res.stderr,
    };
}

fn freeRun(gpa: Allocator, r: Run) void {
    gpa.free(r.stdout);
    gpa.free(r.stderr);
}

fn firstLine(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return trimmed[0..@min(end, 100)];
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "an origin matches however Bitbucket spelled the remote" {
    try t.expect(originMatches("https://bitbucket.org/acme/api.git", "acme", "api"));
    try t.expect(originMatches("https://chris@bitbucket.org/acme/api.git", "acme", "api"));
    try t.expect(originMatches("https://bitbucket.org/acme/api", "acme", "api"));
    try t.expect(originMatches("https://bitbucket.org/acme/api/", "acme", "api"));
    try t.expect(originMatches("git@bitbucket.org:acme/api.git", "acme", "api"));
    try t.expect(originMatches("ssh://git@bitbucket.org/acme/api.git", "acme", "api"));
    try t.expect(originMatches("  git@bitbucket.org:acme/api.git\n", "acme", "api"));
    try t.expect(originMatches("git@bitbucket.org:ACME/API.git", "acme", "api"));
}

test "an origin for another repository, another workspace, or nothing at all does not match" {
    try t.expect(!originMatches("https://bitbucket.org/acme/web.git", "acme", "api"));
    try t.expect(!originMatches("https://bitbucket.org/other/api.git", "acme", "api"));
    try t.expect(!originMatches("git@bitbucket.org:other/api.git", "acme", "api"));
    try t.expect(!originMatches("", "acme", "api"));
    try t.expect(!originMatches("api", "acme", "api"));
    // A near-miss that a naive "does it contain the repo name" check
    // would wave through.
    try t.expect(!originMatches("https://bitbucket.org/acme/api-legacy.git", "acme", "api"));
}

test "check refuses before it touches anything, and names which rule stopped it" {
    const clean_clone: Facts = .{ .allow_checkout = true, .is_repo = true, .origin = "git@bitbucket.org:acme/api.git", .clean = true };
    try t.expectEqual(Verdict.go, check(clean_clone, "acme", "api"));

    var f = clean_clone;
    f.allow_checkout = false;
    try t.expectEqual(Refusal.not_allowed, check(f, "acme", "api").refuse);

    f = clean_clone;
    f.is_repo = false;
    try t.expectEqual(Refusal.not_a_repo, check(f, "acme", "api").refuse);

    f = clean_clone;
    f.origin = "";
    try t.expectEqual(Refusal.no_origin, check(f, "acme", "api").refuse);

    // The one that matters: the right shape of repo, the wrong one.
    try t.expectEqual(Refusal.wrong_repo, check(clean_clone, "acme", "web").refuse);

    f = clean_clone;
    f.clean = false;
    try t.expectEqual(Refusal.dirty, check(f, "acme", "api").refuse);
    try t.expect(std.mem.indexOf(u8, Refusal.dirty.message(), "uncommitted") != null);
}

/// `git init` a fresh repo in `dir` and give it `origin`. Returns
/// false when git is not on PATH, so the test can stand down rather
/// than fail for the wrong reason.
fn initRepo(dir: []const u8, origin: []const u8) bool {
    const init_res = std.process.run(t.allocator, t.io, .{ .argv = &.{ "git", "init", "-q" }, .cwd = .{ .path = dir } }) catch return false;
    t.allocator.free(init_res.stdout);
    t.allocator.free(init_res.stderr);
    if (origin.len == 0) return true;
    const remote_res = std.process.run(t.allocator, t.io, .{ .argv = &.{ "git", "remote", "add", "origin", origin }, .cwd = .{ .path = dir } }) catch return false;
    t.allocator.free(remote_res.stdout);
    t.allocator.free(remote_res.stderr);
    return true;
}

test "facts read a real clone: the origin, and whether the tree is clean" {
    // A repo of its own inside the scratch dir, so the answer is about
    // the fixture and not about whatever checkout the tests run in.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    if (!initRepo(dir, "git@bitbucket.org:acme/api.git")) return;

    const repo = try facts(t.allocator, t.io, dir, true);
    defer t.allocator.free(repo.origin);
    try t.expect(repo.is_repo);
    try t.expectEqualStrings("git@bitbucket.org:acme/api.git", repo.origin);
    try t.expect(repo.clean);
    try t.expectEqual(Verdict.go, check(repo, "acme", "api"));
    // The same clone, asked about a different repo: refused.
    try t.expectEqual(Refusal.wrong_repo, check(repo, "acme", "web").refuse);

    // An untracked file makes the tree dirty, and the refusal follows.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "scratch.txt", .data = "x" });
    const dirty = try facts(t.allocator, t.io, dir, true);
    defer t.allocator.free(dirty.origin);
    try t.expect(!dirty.clean);
    try t.expectEqual(Refusal.dirty, check(dirty, "acme", "api").refuse);
}

test "a clone with no origin at all is refused before any command runs" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    if (!initRepo(dir, "")) return;
    const f = try facts(t.allocator, t.io, dir, true);
    defer t.allocator.free(f.origin);
    try t.expect(f.is_repo);
    try t.expectEqualStrings("", f.origin);
    try t.expectEqual(Refusal.no_origin, check(f, "acme", "api").refuse);
}

test "a checkout in a repo with no origin fails at the fetch, carrying git's own first line" {
    // No origin, so the fetch cannot reach a network and the failure is
    // immediate and local.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    if (!initRepo(dir, "")) return;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const out = try checkout(arena.allocator(), t.io, dir, "chris/nope");
    try t.expect(!out.ok);
    try t.expect(std.mem.startsWith(u8, out.message, "git fetch origin chris/nope:"));
    try t.expect(out.message.len > "git fetch origin chris/nope: ".len);
}
