//! `<data root>/integrations/bitbucket/config.zon` — the private-source
//! install path from the Zig integrations plan: the manifest that mnml
//! reads is public (`<data root>/integrations/bitbucket.zon`, written by
//! `--install`), and everything about *your* workspace lives in a
//! separate file beside it that nothing else reads. First run writes a
//! commented scaffold and says so; no token ever goes in here (that is
//! `auth.zig`).
//!
//! A tab is `kind` / `mode` / `fallback`:
//!
//!   * `kind` is what the tab lists. `.pull_requests` today; the field
//!     exists so a pipelines or branches tab is additive.
//!   * `mode` is whose pull requests: `.repo` (one repo's list),
//!     `.mine` (PRs you opened), `.reviewing` (PRs you are a reviewer
//!     on). `.mine` and `.reviewing` resolve your `account_id` through
//!     `/2.0/user`, which needs **Account: Read** on the token.
//!   * `fallback` is what the tab shows when `mode` cannot run — the
//!     token has no Account: Read, or `/2.0/user` failed. `.none`
//!     leaves the tab empty and says why; `.repo` drops to this tab's
//!     `repo`; `.workspace` drops to every OPEN PR in `repos`.
//!
//! Bitbucket Cloud has no workspace-wide pull-request endpoint, so a
//! `.mine` / `.reviewing` / `.workspace` tab fans out one query per
//! repo in `repos`. That list is required for those modes: enumerating
//! a 100-repo workspace on every refresh is what lands an account in
//! 429s.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Kind = enum { pull_requests };

pub const Mode = enum { repo, mine, reviewing, workspace };

pub const State = enum { OPEN, MERGED, DECLINED, SUPERSEDED };

pub const Fallback = enum { none, repo, workspace };

pub const Tab = struct {
    name: []const u8,
    kind: Kind = .pull_requests,
    mode: Mode = .repo,
    fallback: Fallback = .none,
    /// The repo slug for `mode = .repo` (and for `fallback = .repo`).
    repo: []const u8 = "",
    /// Override the top-level workspace for this tab.
    workspace: []const u8 = "",
    state: State = .OPEN,
    /// Raw Bitbucket Query Language layered under the mode's own
    /// predicate — `updated_on >= 2026-01-01`.
    q: []const u8 = "",
};

/// Cross-links out of a pull request. Each section names the mnml
/// command to run when the sibling integration is installed, and the
/// URL to open in a browser when it is not.
pub const Jira = struct {
    enabled: bool = true,
    /// The command the jira integration registers. mnml runs it when
    /// `<data root>/integrations/jira.zon` exists.
    command: []const u8 = "jira.open",
    /// `https://you.atlassian.net` — the browser fallback's base.
    base_url: []const u8 = "",
    /// Only these project keys count as issue keys. Empty means any
    /// `ABC-123`-shaped token, which over-matches on a PR that quotes
    /// an error code.
    project_keys: []const []const u8 = &.{},
};

pub const Github = struct {
    enabled: bool = false,
    command: []const u8 = "github.open",
    /// `https://github.com/<owner>` — a mirror of the same source.
    base_url: []const u8 = "",
};

/// mnml itself: what the pane may do to the editor's workspace.
pub const Mnml = struct {
    /// `c` checks the PR's source branch out in the workspace. Off
    /// refuses with a reason rather than touching the working tree.
    allow_checkout: bool = true,
    /// An mnml command to run after a successful checkout — the git
    /// section's refresh, usually.
    after_checkout_command: []const u8 = "git.refresh",
};

/// The token bucket every request passes through, and how a 429 is
/// answered. Bitbucket's ceiling is per-account, so a burst from a
/// fan-out is what trips it.
pub const Rate = struct {
    /// Minimum gap between two requests.
    min_interval_ms: u32 = 200,
    /// Attempts per request, retries included.
    max_attempts: u8 = 3,
    /// Used when a 429 carries no `Retry-After`.
    default_backoff_secs: u32 = 15,
    /// A `Retry-After` longer than this is clamped, so one stubborn
    /// repo cannot park the pane.
    max_backoff_secs: u32 = 30,
};

pub const Config = struct {
    /// Your Atlassian account email — the username half of Basic auth.
    email: []const u8 = "",
    /// The default workspace slug (`bitbucket.org/<workspace>/<repo>`).
    workspace: []const u8 = "",
    /// The repos a `.mine` / `.reviewing` / `.workspace` tab queries.
    repos: []const []const u8 = &.{},
    /// Never listed, whatever a tab asks for.
    hidden_repos: []const []const u8 = &.{},
    /// 0 disables the tab's auto-refresh; `r` still works.
    refresh_interval_secs: u32 = 300,
    /// Rows per API page. Bitbucket caps this at 50.
    page_len: u32 = 50,
    /// Override the API base — the fake server, or a test double.
    /// `$BITBUCKET_BASE_URL` wins over this.
    base_url: []const u8 = "",
    rate: Rate = .{},
    tabs: []const Tab = &.{},
    jira: Jira = .{},
    github: Github = .{},
    mnml: Mnml = .{},

    /// A repo is listed unless it is hidden.
    pub fn isHidden(c: Config, slug: []const u8) bool {
        for (c.hidden_repos) |h| if (std.mem.eql(u8, h, slug)) return true;
        return false;
    }

    /// The workspace a tab queries: its own override, else the default.
    pub fn tabWorkspace(c: Config, tab: Tab) []const u8 {
        return if (tab.workspace.len > 0) tab.workspace else c.workspace;
    }
};

pub const ValidateError = error{Invalid};

/// The rule the loader and `--check` both apply. `why` gets a line the
/// pane can paint.
pub fn validate(c: Config, why: *[]const u8) ValidateError!void {
    if (std.mem.trim(u8, c.email, " ").len == 0) {
        why.* = "`email` is required — your Atlassian account email";
        return error.Invalid;
    }
    if (std.mem.trim(u8, c.workspace, " ").len == 0) {
        why.* = "`workspace` is required — the slug in bitbucket.org/<workspace>/<repo>";
        return error.Invalid;
    }
    if (c.tabs.len == 0) {
        why.* = "at least one `.tabs` entry is required";
        return error.Invalid;
    }
    if (c.page_len == 0 or c.page_len > 50) {
        why.* = "`page_len` must be 1–50 (Bitbucket's cap)";
        return error.Invalid;
    }
    for (c.tabs) |tab| {
        if (tab.name.len == 0) {
            why.* = "a tab needs a `name`";
            return error.Invalid;
        }
        if (tab.mode == .repo and tab.repo.len == 0 and tab.q.len == 0) {
            why.* = "a `mode = .repo` tab needs a `repo` (or a raw `q`)";
            return error.Invalid;
        }
        if (tab.fallback == .repo and tab.repo.len == 0) {
            why.* = "a `fallback = .repo` tab needs a `repo` to fall back to";
            return error.Invalid;
        }
        if ((tab.mode == .mine or tab.mode == .reviewing or tab.mode == .workspace or tab.fallback == .workspace) and c.repos.len == 0) {
            why.* = "`repos` is required for a mine / reviewing / workspace tab — Bitbucket has no workspace-wide PR endpoint";
            return error.Invalid;
        }
    }
}

// ─── where it lives ──────────────────────────────────────────────────────

pub const subdir = "integrations/bitbucket";
pub const file_name = "config.zon";

/// mnml's data root, the way the SDK picks it.
pub fn dataRoot(gpa: Allocator, env: *const std.process.Environ.Map) Allocator.Error!?[]u8 {
    if (nonEmpty(env.get("MNML_DATA_ROOT"))) |root| return try gpa.dupe(u8, root);
    if (nonEmpty(env.get("XDG_CONFIG_HOME"))) |xdg| return try std.fs.path.join(gpa, &.{ xdg, "mnml" });
    if (nonEmpty(env.get("HOME"))) |home| return try std.fs.path.join(gpa, &.{ home, ".config", "mnml" });
    return null;
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

pub const PathError = error{NoHome} || Allocator.Error;

/// `<data root>/integrations/bitbucket/config.zon`, owned. An explicit
/// `$MNML_BITBUCKET_CONFIG` wins — the corpus and a second workspace
/// both need one.
pub fn configPath(gpa: Allocator, env: *const std.process.Environ.Map) PathError![]u8 {
    if (nonEmpty(env.get("MNML_BITBUCKET_CONFIG"))) |p| return try gpa.dupe(u8, p);
    const root = (try dataRoot(gpa, env)) orelse return error.NoHome;
    defer gpa.free(root);
    return std.fs.path.join(gpa, &.{ root, "integrations", "bitbucket", file_name });
}

pub const LoadError = error{ NoConfig, Scaffolded, Malformed, Invalid, ReadFailed, WriteFailed } || PathError;

/// `why` outlives `load`'s arena, so the one reason that is not a string
/// literal — the path the scaffold went to — is copied here rather than
/// left pointing into memory the error path has already freed. (It did
/// point there; Debug happened to survive it and ReleaseSafe did not.)
threadlocal var why_buf: [std.fs.max_path_bytes + 64]u8 = undefined;

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    config: Config,
    /// Where it was read from, on the arena.
    path: []const u8,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Read + validate the config. A missing file is written as the
/// scaffold and reported as `error.Scaffolded` with the path in
/// `why` — first run is a setup step, not a crash.
pub fn load(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, why: *[]const u8) LoadError!Loaded {
    const p = try configPath(gpa, env);
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const owned_path = try a.dupe(u8, p);
    gpa.free(p);

    const text = Io.Dir.cwd().readFileAllocOptions(io, owned_path, a, .unlimited, .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => {
            scaffold(io, owned_path) catch {
                why.* = "could not write the config scaffold";
                return error.WriteFailed;
            };
            why.* = std.fmt.bufPrint(&why_buf, "{s}", .{owned_path}) catch "wrote the config scaffold";
            return error.Scaffolded;
        },
        else => {
            why.* = "could not read the config";
            return error.ReadFailed;
        },
    };
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(a);
    const cfg = std.zon.parse.fromSliceAlloc(Config, a, text, &diag, .{ .free_on_error = false }) catch {
        why.* = "config.zon does not parse — check the trailing commas and the field names";
        return error.Malformed;
    };
    try validate(cfg, why);
    return .{ .arena = arena, .config = cfg, .path = owned_path };
}

/// Write the commented template. Used by first run and by `--scaffold`.
pub fn scaffold(io: Io, p: []const u8) !void {
    if (std.fs.path.dirname(p)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = template });
}

pub const template =
    \\// mnml-bitbucket — your Bitbucket Cloud workspace. Edit and
    \\// re-open the pane (`bitbucket.refresh` re-reads this file).
    \\//
    \\// No token goes in here. Set BITBUCKET_API_TOKEN (read) and
    \\// BITBUCKET_ACCESS_TOKEN (write), or drop them in
    \\// <this folder>/token and <this folder>/token.write — see the
    \\// README's "Auth" section.
    \\.{
    \\    .email = "you@example.com",
    \\    .workspace = "your-workspace-slug",
    \\
    \\    // Bitbucket has no workspace-wide PR endpoint: a mine /
    \\    // reviewing / workspace tab queries each of these in turn.
    \\    // Keep it to the repos you actually watch.
    \\    .repos = .{ "api", "web" },
    \\    // .hidden_repos = .{ "archived-thing" },
    \\
    \\    .refresh_interval_secs = 300,
    \\    .page_len = 50,
    \\
    \\    // Tabs are switched with 1-9 / Tab. `kind` is what the tab
    \\    // lists, `mode` is whose PRs, `fallback` is what to show when
    \\    // the mode cannot run (no Account: Read on the token).
    \\    .tabs = .{
    \\        .{ .name = "Mine", .mode = .mine, .fallback = .workspace },
    \\        .{ .name = "Review queue", .mode = .reviewing, .fallback = .none },
    \\        .{ .name = "api", .mode = .repo, .repo = "api", .state = .OPEN },
    \\    },
    \\
    \\    // A PR's issue keys open the jira integration when it is
    \\    // installed, and this base URL in a browser when it is not.
    \\    .jira = .{ .enabled = true, .command = "jira.open", .base_url = "", .project_keys = .{} },
    \\    .github = .{ .enabled = false },
    \\    .mnml = .{ .allow_checkout = true, .after_checkout_command = "git.refresh" },
    \\}
    \\
;

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

fn parseText(arena: Allocator, text: [:0]const u8) !Config {
    return std.zon.parse.fromSliceAlloc(Config, arena, text, null, .{ .free_on_error = false });
}

test "the scaffold parses and validates once the placeholders are real" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const z = try arena.allocator().dupeZ(u8, template);
    var cfg = try parseText(arena.allocator(), z);
    var why: []const u8 = "";
    try validate(cfg, &why);
    try t.expectEqual(@as(usize, 3), cfg.tabs.len);
    try t.expectEqual(Mode.mine, cfg.tabs[0].mode);
    try t.expectEqual(Fallback.workspace, cfg.tabs[0].fallback);
    try t.expectEqual(Mode.reviewing, cfg.tabs[1].mode);
    try t.expectEqual(Mode.repo, cfg.tabs[2].mode);
    try t.expectEqual(State.OPEN, cfg.tabs[2].state);
    try t.expectEqualStrings("api", cfg.tabs[2].repo);
    try t.expectEqualStrings("jira.open", cfg.jira.command);
    try t.expect(cfg.mnml.allow_checkout);
    try t.expectEqualStrings("git.refresh", cfg.mnml.after_checkout_command);
    // The tab workspace falls through to the top-level one.
    try t.expectEqualStrings("your-workspace-slug", cfg.tabWorkspace(cfg.tabs[0]));
    cfg.tabs = &.{.{ .name = "x", .workspace = "other", .repo = "r" }};
    try t.expectEqualStrings("other", cfg.tabWorkspace(cfg.tabs[0]));
}

test "validate names what is missing rather than failing silently" {
    var why: []const u8 = "";
    const ok: Config = .{
        .email = "a@b.com",
        .workspace = "ws",
        .repos = &.{"api"},
        .tabs = &.{.{ .name = "Mine", .mode = .mine }},
    };
    try validate(ok, &why);

    var bad = ok;
    bad.email = "  ";
    try t.expectError(error.Invalid, validate(bad, &why));
    try t.expect(std.mem.indexOf(u8, why, "email") != null);

    bad = ok;
    bad.workspace = "";
    try t.expectError(error.Invalid, validate(bad, &why));
    try t.expect(std.mem.indexOf(u8, why, "workspace") != null);

    bad = ok;
    bad.tabs = &.{};
    try t.expectError(error.Invalid, validate(bad, &why));
    try t.expect(std.mem.indexOf(u8, why, "tabs") != null);

    bad = ok;
    bad.page_len = 200;
    try t.expectError(error.Invalid, validate(bad, &why));
    try t.expect(std.mem.indexOf(u8, why, "page_len") != null);

    // A repo tab with neither a repo nor a raw query has nothing to ask for.
    bad = ok;
    bad.tabs = &.{.{ .name = "Repo", .mode = .repo }};
    try t.expectError(error.Invalid, validate(bad, &why));
    try t.expect(std.mem.indexOf(u8, why, "`repo`") != null);
    bad.tabs = &.{.{ .name = "Repo", .mode = .repo, .q = "state = \"OPEN\"" }};
    try validate(bad, &why);

    // A mine tab with no `repos` has nothing to fan out over.
    bad = ok;
    bad.repos = &.{};
    try t.expectError(error.Invalid, validate(bad, &why));
    try t.expect(std.mem.indexOf(u8, why, "repos") != null);

    // `fallback = .repo` with no repo would fall back to nothing.
    bad = ok;
    bad.tabs = &.{.{ .name = "Mine", .mode = .mine, .fallback = .repo }};
    try t.expectError(error.Invalid, validate(bad, &why));
    try t.expect(std.mem.indexOf(u8, why, "fall back") != null);
}

test "hidden repos subtract from whatever a tab asks for" {
    const c: Config = .{ .hidden_repos = &.{ "old", "legacy" } };
    try t.expect(c.isHidden("old"));
    try t.expect(c.isHidden("legacy"));
    try t.expect(!c.isHidden("api"));
}

test "the config path follows MNML_BITBUCKET_CONFIG, then the data root" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try t.expectError(error.NoHome, configPath(t.allocator, &env));
    try env.put("HOME", "/h");
    const a = try configPath(t.allocator, &env);
    defer t.allocator.free(a);
    try t.expectEqualStrings("/h/.config/mnml/integrations/bitbucket/config.zon", a);
    try env.put("MNML_DATA_ROOT", "/r");
    const b = try configPath(t.allocator, &env);
    defer t.allocator.free(b);
    try t.expectEqualStrings("/r/integrations/bitbucket/config.zon", b);
    try env.put("MNML_BITBUCKET_CONFIG", "/tmp/x.zon");
    const c = try configPath(t.allocator, &env);
    defer t.allocator.free(c);
    try t.expectEqualStrings("/tmp/x.zon", c);
}

test "first load writes the scaffold and says so; the second reads it back" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("MNML_DATA_ROOT", root);

    var why: []const u8 = "";
    try t.expectError(error.Scaffolded, load(t.allocator, t.io, &env, &why));
    try t.expect(std.mem.endsWith(u8, why, "/integrations/bitbucket/config.zon"));
    // The scaffold is there but still has the placeholder workspace, so
    // the next load is a validation failure, not a parse failure.
    var why2: []const u8 = "";
    var loaded = try load(t.allocator, t.io, &env, &why2);
    defer loaded.deinit();
    try t.expectEqualStrings("you@example.com", loaded.config.email);
    try t.expectEqual(@as(usize, 2), loaded.config.repos.len);

    // Garbage is a named parse failure, never a crash.
    const p = try configPath(t.allocator, &env);
    defer t.allocator.free(p);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = p, .data = ".{ this is not zon" });
    var why3: []const u8 = "";
    try t.expectError(error.Malformed, load(t.allocator, t.io, &env, &why3));
    try t.expect(std.mem.indexOf(u8, why3, "does not parse") != null);
}
