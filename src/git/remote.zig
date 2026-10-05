//! Remote URLs: which forge `remote.origin.url` names, and the web
//! address of a file, a line or a commit on it. Pure text — no git, no
//! `App`; the worker resolves the remote and calls in here.
//!
//! Both remote shapes resolve — `git@host:owner/repo.git` and
//! `[scheme]://[user@]host/owner/repo[.git]` — and the forge is read
//! off the host: GitHub (and an enterprise host that says so), GitLab
//! (`gitlab` anywhere in the host), Bitbucket Cloud and a Bitbucket
//! Server (`/scm/PROJ/repo` paths), Azure DevOps (`dev.azure.com`,
//! `*.visualstudio.com`, and the `ssh.dev.azure.com:v3/org/proj/repo`
//! SSH form). An unknown host gets GitHub's shape, which most forges
//! mirror.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Provider = enum {
    github,
    gitlab,
    bitbucket,
    azure,
    other,
    none,

    /// The badge text.
    pub fn label(p: Provider) []const u8 {
        return switch (p) {
            .github => "GitHub",
            .gitlab => "GitLab",
            .bitbucket => "Bitbucket",
            .azure => "Azure",
            .other => "remote",
            .none => "",
        };
    }
};

/// The host and the owner/repo path of a remote, with `.git` and any
/// trailing `/` stripped. Null for a path that is not a URL (a local
/// remote).
pub const Remote = struct {
    host: []const u8,
    path: []const u8,
};

pub fn parseRemote(remote: []const u8) ?Remote {
    const r = std.mem.trim(u8, remote, " \t\r\n");
    var host: []const u8 = "";
    var path: []const u8 = "";
    if (std.mem.indexOf(u8, r, "://")) |i| {
        var rest = r[i + 3 ..];
        if (std.mem.indexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        host = rest[0..slash];
        path = if (slash < rest.len) rest[slash + 1 ..] else "";
        // `ssh://host:22/…` carries a port; the web host has none.
        if (std.mem.indexOfScalar(u8, host, ':')) |c| host = host[0..c];
    } else if (std.mem.indexOfScalar(u8, r, ':')) |colon| {
        // scp-like: `[user@]host:path`
        var h = r[0..colon];
        if (std.mem.indexOfScalar(u8, h, '@')) |at| h = h[at + 1 ..];
        if (h.len == 0 or std.mem.indexOfScalar(u8, h, '/') != null) return null;
        host = h;
        path = r[colon + 1 ..];
    } else return null;
    if (host.len == 0) return null;
    path = std.mem.trim(u8, path, "/");
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - 4];
    path = std.mem.trimEnd(u8, path, "/");
    return .{ .host = host, .path = path };
}

pub fn providerOf(remote: []const u8) Provider {
    const r = parseRemote(remote) orelse return if (std.mem.trim(u8, remote, " \t\r\n").len == 0) .none else .other;
    return providerOfHost(r.host);
}

fn providerOfHost(host: []const u8) Provider {
    if (std.ascii.findIgnoreCase(host, "github") != null) return .github;
    if (std.ascii.findIgnoreCase(host, "gitlab") != null) return .gitlab;
    if (std.ascii.findIgnoreCase(host, "bitbucket") != null) return .bitbucket;
    if (std.ascii.findIgnoreCase(host, "dev.azure.com") != null or std.ascii.findIgnoreCase(host, "visualstudio.com") != null) return .azure;
    return .other;
}

/// The Azure SSH form names the repo as `v3/org/proj/repo`; the web
/// address is `dev.azure.com/org/proj/_git/repo`. Everything else keeps
/// its host and path.
fn webBase(arena: Allocator, r: Remote) Allocator.Error!struct { host: []const u8, path: []const u8 } {
    if (std.mem.startsWith(u8, r.path, "v3/") and std.ascii.findIgnoreCase(r.host, "dev.azure.com") != null) {
        var it = std.mem.splitScalar(u8, r.path[3..], '/');
        const org = it.next() orelse "";
        const proj = it.next() orelse "";
        const repo = it.next() orelse "";
        return .{ .host = "dev.azure.com", .path = try std.fmt.allocPrint(arena, "{s}/{s}/_git/{s}", .{ org, proj, repo }) };
    }
    return .{ .host = r.host, .path = r.path };
}

/// A Bitbucket Server clone path is `scm/PROJ/repo`; the web path is
/// `projects/PROJ/repos/repo`.
fn bitbucketServer(arena: Allocator, path: []const u8) Allocator.Error!?[]const u8 {
    if (!std.mem.startsWith(u8, path, "scm/")) return null;
    var it = std.mem.splitScalar(u8, path[4..], '/');
    const proj = it.next() orelse return null;
    const repo = it.next() orelse return null;
    return try std.fmt.allocPrint(arena, "projects/{s}/repos/{s}", .{ proj, repo });
}

/// The web page of `path` at `ref`, at `line` when given. A remote
/// that is not a URL is returned as it is.
pub fn fileUrl(arena: Allocator, remote: []const u8, ref: []const u8, path: []const u8, line: ?u32) Allocator.Error![]const u8 {
    const r = parseRemote(remote) orelse return arena.dupe(u8, std.mem.trim(u8, remote, " \t\r\n"));
    const w = try webBase(arena, r);
    switch (providerOfHost(r.host)) {
        .bitbucket => {
            if (try bitbucketServer(arena, w.path)) |web| {
                if (line) |l| return std.fmt.allocPrint(arena, "https://{s}/{s}/browse/{s}?at={s}#{d}", .{ w.host, web, path, ref, l });
                return std.fmt.allocPrint(arena, "https://{s}/{s}/browse/{s}?at={s}", .{ w.host, web, path, ref });
            }
            if (line) |l| return std.fmt.allocPrint(arena, "https://{s}/{s}/src/{s}/{s}#lines-{d}", .{ w.host, w.path, ref, path, l });
            return std.fmt.allocPrint(arena, "https://{s}/{s}/src/{s}/{s}", .{ w.host, w.path, ref, path });
        },
        .gitlab => {
            if (line) |l| return std.fmt.allocPrint(arena, "https://{s}/{s}/-/blob/{s}/{s}#L{d}", .{ w.host, w.path, ref, path, l });
            return std.fmt.allocPrint(arena, "https://{s}/{s}/-/blob/{s}/{s}", .{ w.host, w.path, ref, path });
        },
        .azure => {
            if (line) |l| return std.fmt.allocPrint(arena, "https://{s}/{s}?path=/{s}&version=GB{s}&line={d}", .{ w.host, w.path, path, ref, l });
            return std.fmt.allocPrint(arena, "https://{s}/{s}?path=/{s}&version=GB{s}", .{ w.host, w.path, path, ref });
        },
        .github, .other, .none => {
            if (line) |l| return std.fmt.allocPrint(arena, "https://{s}/{s}/blob/{s}/{s}#L{d}", .{ w.host, w.path, ref, path, l });
            return std.fmt.allocPrint(arena, "https://{s}/{s}/blob/{s}/{s}", .{ w.host, w.path, ref, path });
        },
    }
}

/// The web page of commit `sha`.
pub fn commitUrl(arena: Allocator, remote: []const u8, sha: []const u8) Allocator.Error![]const u8 {
    const r = parseRemote(remote) orelse return arena.dupe(u8, std.mem.trim(u8, remote, " \t\r\n"));
    const w = try webBase(arena, r);
    return switch (providerOfHost(r.host)) {
        .bitbucket => if (try bitbucketServer(arena, w.path)) |web|
            std.fmt.allocPrint(arena, "https://{s}/{s}/commits/{s}", .{ w.host, web, sha })
        else
            std.fmt.allocPrint(arena, "https://{s}/{s}/commits/{s}", .{ w.host, w.path, sha }),
        .gitlab => std.fmt.allocPrint(arena, "https://{s}/{s}/-/commit/{s}", .{ w.host, w.path, sha }),
        .azure => std.fmt.allocPrint(arena, "https://{s}/{s}/commit/{s}", .{ w.host, w.path, sha }),
        .github, .other, .none => std.fmt.allocPrint(arena, "https://{s}/{s}/commit/{s}", .{ w.host, w.path, sha }),
    };
}

/// The web page of branch `branch` (git-panel: the branches panel's
/// "Copy link to branch").
pub fn branchUrl(arena: Allocator, remote: []const u8, branch: []const u8) Allocator.Error![]const u8 {
    const r = parseRemote(remote) orelse return arena.dupe(u8, std.mem.trim(u8, remote, " \t\r\n"));
    const w = try webBase(arena, r);
    return switch (providerOfHost(r.host)) {
        .bitbucket => if (try bitbucketServer(arena, w.path)) |web|
            std.fmt.allocPrint(arena, "https://{s}/{s}/browse?at=refs/heads/{s}", .{ w.host, web, branch })
        else
            std.fmt.allocPrint(arena, "https://{s}/{s}/branch/{s}", .{ w.host, w.path, branch }),
        .gitlab => std.fmt.allocPrint(arena, "https://{s}/{s}/-/tree/{s}", .{ w.host, w.path, branch }),
        .azure => std.fmt.allocPrint(arena, "https://{s}/{s}?version=GB{s}", .{ w.host, w.path, branch }),
        .github, .other, .none => std.fmt.allocPrint(arena, "https://{s}/{s}/tree/{s}", .{ w.host, w.path, branch }),
    };
}

/// The forge's *new pull request* page for `branch`, or null when the
/// host is not one this knows the shape of (git-menus: *Push and start
/// PR* then pushes and says so rather than guessing a URL — an
/// unrecognised host is the one case where GitHub's shape is likelier
/// to 404 than to work).
pub fn newPrUrl(arena: Allocator, remote: []const u8, branch: []const u8) Allocator.Error!?[]const u8 {
    const r = parseRemote(remote) orelse return null;
    const w = try webBase(arena, r);
    const q = try percentEncode(arena, branch);
    return switch (providerOfHost(r.host)) {
        .github => try std.fmt.allocPrint(arena, "https://{s}/{s}/compare/{s}?expand=1", .{ w.host, w.path, branch }),
        .gitlab => try std.fmt.allocPrint(arena, "https://{s}/{s}/-/merge_requests/new?merge_request%5Bsource_branch%5D={s}", .{ w.host, w.path, q }),
        .bitbucket => if (try bitbucketServer(arena, w.path)) |web|
            try std.fmt.allocPrint(arena, "https://{s}/{s}/pull-requests?create&sourceBranch=refs%2Fheads%2F{s}", .{ w.host, web, q })
        else
            try std.fmt.allocPrint(arena, "https://{s}/{s}/pull-requests/new?source={s}", .{ w.host, w.path, q }),
        .azure => try std.fmt.allocPrint(arena, "https://{s}/{s}/pullrequestcreate?sourceRef={s}", .{ w.host, w.path, q }),
        .other, .none => null,
    };
}

/// A branch name in a query value: everything but the unreserved set
/// goes as `%XX`, so `feat/a b` reaches the forge whole.
fn percentEncode(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.append(arena, c);
        } else {
            try out.print(arena, "%{X:0>2}", .{c});
        }
    }
    return out.items;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseRemote: ssh, scp-like, https with a user, a port, no .git; a local path is not a remote" {
    const a = parseRemote("git@github.com:o/r.git").?;
    try testing.expectEqualStrings("github.com", a.host);
    try testing.expectEqualStrings("o/r", a.path);
    const b = parseRemote("ssh://git@gitlab.com:2222/g/sub/p.git/").?;
    try testing.expectEqualStrings("gitlab.com", b.host);
    try testing.expectEqualStrings("g/sub/p", b.path);
    const c = parseRemote("https://alice@bitbucket.org/w/r").?;
    try testing.expectEqualStrings("bitbucket.org", c.host);
    try testing.expectEqualStrings("w/r", c.path);
    try testing.expect(parseRemote("/srv/git/repo.git") == null);
    try testing.expect(parseRemote("../other") == null);
    try testing.expectEqual(Provider.none, providerOf(""));
    try testing.expectEqual(Provider.other, providerOf("/srv/git/repo.git"));
}

const Case = struct { remote: []const u8, provider: Provider, file: []const u8, line: []const u8, commit: []const u8 };

const table = [_]Case{
    .{ .remote = "git@github.com:o/r.git", .provider = .github, .file = "https://github.com/o/r/blob/main/src/a.zig", .line = "https://github.com/o/r/blob/main/src/a.zig#L7", .commit = "https://github.com/o/r/commit/abc123" },
    .{ .remote = "https://github.com/o/r", .provider = .github, .file = "https://github.com/o/r/blob/main/src/a.zig", .line = "https://github.com/o/r/blob/main/src/a.zig#L7", .commit = "https://github.com/o/r/commit/abc123" },
    .{ .remote = "ssh://git@github.com/o/r.git", .provider = .github, .file = "https://github.com/o/r/blob/main/src/a.zig", .line = "https://github.com/o/r/blob/main/src/a.zig#L7", .commit = "https://github.com/o/r/commit/abc123" },
    .{ .remote = "git@github.mycorp.com:team/svc.git", .provider = .github, .file = "https://github.mycorp.com/team/svc/blob/main/src/a.zig", .line = "https://github.mycorp.com/team/svc/blob/main/src/a.zig#L7", .commit = "https://github.mycorp.com/team/svc/commit/abc123" },
    .{ .remote = "https://user@gitlab.com/g/p.git", .provider = .gitlab, .file = "https://gitlab.com/g/p/-/blob/main/src/a.zig", .line = "https://gitlab.com/g/p/-/blob/main/src/a.zig#L7", .commit = "https://gitlab.com/g/p/-/commit/abc123" },
    .{ .remote = "git@gitlab.com:group/sub/proj.git", .provider = .gitlab, .file = "https://gitlab.com/group/sub/proj/-/blob/main/src/a.zig", .line = "https://gitlab.com/group/sub/proj/-/blob/main/src/a.zig#L7", .commit = "https://gitlab.com/group/sub/proj/-/commit/abc123" },
    .{ .remote = "ssh://git@gitlab.example.com:2222/g/p.git", .provider = .gitlab, .file = "https://gitlab.example.com/g/p/-/blob/main/src/a.zig", .line = "https://gitlab.example.com/g/p/-/blob/main/src/a.zig#L7", .commit = "https://gitlab.example.com/g/p/-/commit/abc123" },
    .{ .remote = "git@bitbucket.org:w/r.git", .provider = .bitbucket, .file = "https://bitbucket.org/w/r/src/main/src/a.zig", .line = "https://bitbucket.org/w/r/src/main/src/a.zig#lines-7", .commit = "https://bitbucket.org/w/r/commits/abc123" },
    .{ .remote = "https://alice@bitbucket.org/w/r.git", .provider = .bitbucket, .file = "https://bitbucket.org/w/r/src/main/src/a.zig", .line = "https://bitbucket.org/w/r/src/main/src/a.zig#lines-7", .commit = "https://bitbucket.org/w/r/commits/abc123" },
    .{ .remote = "https://bitbucket.mycorp.com/scm/proj/repo.git", .provider = .bitbucket, .file = "https://bitbucket.mycorp.com/projects/proj/repos/repo/browse/src/a.zig?at=main", .line = "https://bitbucket.mycorp.com/projects/proj/repos/repo/browse/src/a.zig?at=main#7", .commit = "https://bitbucket.mycorp.com/projects/proj/repos/repo/commits/abc123" },
    .{ .remote = "https://dev.azure.com/org/proj/_git/repo", .provider = .azure, .file = "https://dev.azure.com/org/proj/_git/repo?path=/src/a.zig&version=GBmain", .line = "https://dev.azure.com/org/proj/_git/repo?path=/src/a.zig&version=GBmain&line=7", .commit = "https://dev.azure.com/org/proj/_git/repo/commit/abc123" },
    .{ .remote = "https://org@dev.azure.com/org/proj/_git/repo", .provider = .azure, .file = "https://dev.azure.com/org/proj/_git/repo?path=/src/a.zig&version=GBmain", .line = "https://dev.azure.com/org/proj/_git/repo?path=/src/a.zig&version=GBmain&line=7", .commit = "https://dev.azure.com/org/proj/_git/repo/commit/abc123" },
    .{ .remote = "git@ssh.dev.azure.com:v3/org/proj/repo", .provider = .azure, .file = "https://dev.azure.com/org/proj/_git/repo?path=/src/a.zig&version=GBmain", .line = "https://dev.azure.com/org/proj/_git/repo?path=/src/a.zig&version=GBmain&line=7", .commit = "https://dev.azure.com/org/proj/_git/repo/commit/abc123" },
    .{ .remote = "https://org.visualstudio.com/proj/_git/repo", .provider = .azure, .file = "https://org.visualstudio.com/proj/_git/repo?path=/src/a.zig&version=GBmain", .line = "https://org.visualstudio.com/proj/_git/repo?path=/src/a.zig&version=GBmain&line=7", .commit = "https://org.visualstudio.com/proj/_git/repo/commit/abc123" },
    .{ .remote = "https://git.sr.ht/~me/r", .provider = .other, .file = "https://git.sr.ht/~me/r/blob/main/src/a.zig", .line = "https://git.sr.ht/~me/r/blob/main/src/a.zig#L7", .commit = "https://git.sr.ht/~me/r/commit/abc123" },
};

test "remote → browse URL table: file, line and commit on every forge shape" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expect(table.len >= 12);
    for (table) |c| {
        try testing.expectEqual(c.provider, providerOf(c.remote));
        try testing.expectEqualStrings(c.file, try fileUrl(arena, c.remote, "main", "src/a.zig", null));
        try testing.expectEqualStrings(c.line, try fileUrl(arena, c.remote, "main", "src/a.zig", 7));
        try testing.expectEqualStrings(c.commit, try commitUrl(arena, c.remote, "abc123"));
    }
    // A local remote comes back as itself.
    try testing.expectEqualStrings("/srv/git/repo.git", try fileUrl(arena, "/srv/git/repo.git", "main", "f", 1));
}

test "newPrUrl: the new-pull-request page per forge, the branch percent-encoded in a query; an unknown host has none" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expectEqualStrings(
        "https://github.com/acme/widget/compare/feat/eng-12?expand=1",
        (try newPrUrl(arena, "git@github.com:acme/widget.git", "feat/eng-12")).?,
    );
    try testing.expectEqualStrings(
        "https://github.acme-corp.example/platform/gateway/compare/main?expand=1",
        (try newPrUrl(arena, "https://github.acme-corp.example/platform/gateway", "main")).?,
    );
    try testing.expectEqualStrings(
        "https://gitlab.com/acme/sub/widget/-/merge_requests/new?merge_request%5Bsource_branch%5D=feat%2Feng-12",
        (try newPrUrl(arena, "git@gitlab.com:acme/sub/widget.git", "feat/eng-12")).?,
    );
    try testing.expectEqualStrings(
        "https://bitbucket.org/acme/widget/pull-requests/new?source=feat%2Feng-12",
        (try newPrUrl(arena, "git@bitbucket.org:acme/widget.git", "feat/eng-12")).?,
    );
    // A Bitbucket Server clone path is `scm/PROJ/repo`.
    try testing.expectEqualStrings(
        "https://bitbucket.acme-corp.example/projects/PLAT/repos/widget/pull-requests?create&sourceBranch=refs%2Fheads%2Ffeat%2Feng-12",
        (try newPrUrl(arena, "https://bitbucket.acme-corp.example/scm/PLAT/widget.git", "feat/eng-12")).?,
    );
    try testing.expectEqualStrings(
        "https://dev.azure.com/acme/platform/_git/widget/pullrequestcreate?sourceRef=feat%2Feng-12",
        (try newPrUrl(arena, "git@ssh.dev.azure.com:v3/acme/platform/widget", "feat/eng-12")).?,
    );
    // A host with no shape on file, and a local remote: no URL at all.
    try testing.expect((try newPrUrl(arena, "https://git.acme-corp.example/~me/widget", "main")) == null);
    try testing.expect((try newPrUrl(arena, "/srv/git/widget.git", "main")) == null);
    // A branch name needing no escape comes through as it is.
    try testing.expectEqualStrings(
        "https://bitbucket.org/acme/widget/pull-requests/new?source=main",
        (try newPrUrl(arena, "https://acme@bitbucket.org/acme/widget.git", "main")).?,
    );
}

test "branchUrl: the branch page on every forge shape" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expectEqualStrings("https://github.com/o/r/tree/feat/x", try branchUrl(arena, "git@github.com:o/r.git", "feat/x"));
    try testing.expectEqualStrings("https://gitlab.com/g/p/-/tree/main", try branchUrl(arena, "https://user@gitlab.com/g/p.git", "main"));
    try testing.expectEqualStrings("https://bitbucket.org/w/r/branch/main", try branchUrl(arena, "git@bitbucket.org:w/r.git", "main"));
    try testing.expectEqualStrings("https://bitbucket.mycorp.com/projects/proj/repos/repo/browse?at=refs/heads/main", try branchUrl(arena, "https://bitbucket.mycorp.com/scm/proj/repo.git", "main"));
    try testing.expectEqualStrings("https://dev.azure.com/org/proj/_git/repo?version=GBmain", try branchUrl(arena, "https://dev.azure.com/org/proj/_git/repo", "main"));
    try testing.expectEqualStrings("/srv/git/repo.git", try branchUrl(arena, "/srv/git/repo.git", "main"));
}
