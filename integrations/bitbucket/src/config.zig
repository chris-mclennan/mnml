//! `<data root>/integrations/bitbucket/config.zon` — the private half
//! of the install. The manifests mnml reads (`bitbucket_prs.zon`,
//! `bitbucket_pipelines.zon`, written by `--install`) are public; this
//! file is *your* workspace and nothing else reads it. Its keys are the
//! reference's TOML keys by name — `email`, `workspace`, `repos`,
//! `scope`, `recent_window_days`, `hidden_repos`, `repo_order`,
//! `chip_stale_after_days`, `chip_excluded_branch_patterns`, the
//! `tabs` with their `kind` / `repo` / `state` / `mode` / `q` — so a
//! `mnml-forge-bitbucket.toml` converts line for line.
//!
//! Tabs come in six kinds. Three see the whole workspace and take
//! their repos from the top-level scope: `workspace_open_prs`,
//! `workspace_merged_prs`, `workspace_pipelines`. Three are the older
//! per-repo shapes: `pull_requests` (one repo's list, or `mode = .mine`
//! / `.reviewing` across the workspace), `pipelines`, `branches`.
//!
//! The runtime keys that change this file — `x` hides a repo, `H`
//! un-hides them all, `s` cycles the scope, `alt+↑` / `alt+↓` reorder
//! — rewrite it whole through `save`; hand-written comments do not
//! survive that, as they do not in the reference.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sdk = @import("mnml_sdk");

pub const Kind = enum {
    workspace_open_prs,
    workspace_merged_prs,
    workspace_pipelines,
    pull_requests,
    pipelines,
    branches,

    /// The workspace-wide kinds take their repos from `scope`.
    pub fn isWorkspaceWide(k: Kind) bool {
        return k == .workspace_open_prs or k == .workspace_merged_prs or k == .workspace_pipelines;
    }

    /// The `--only` family a kind belongs to.
    pub fn family(k: Kind) Family {
        return switch (k) {
            .workspace_open_prs, .workspace_merged_prs, .pull_requests => .prs,
            .workspace_pipelines, .pipelines => .pipelines,
            .branches => .branches,
        };
    }

    pub fn isPrs(k: Kind) bool {
        return k.family() == .prs;
    }
};

/// What `--only` narrows to.
pub const Family = enum { prs, pipelines, branches };

pub const State = enum { OPEN, MERGED, DECLINED, SUPERSEDED };

/// `mode` on a `pull_requests` tab: `.none` is a per-repo list.
pub const Mode = enum { none, mine, reviewing };

pub const Scope = enum {
    all,
    recent,
    explicit,

    /// `s` cycles all → recent → explicit → all.
    pub fn next(s: Scope) Scope {
        return switch (s) {
            .all => .recent,
            .recent => .explicit,
            .explicit => .all,
        };
    }
};

pub const Tab = struct {
    name: []const u8,
    kind: Kind = .pull_requests,
    /// Overrides the top-level workspace for this tab.
    workspace: []const u8 = "",
    /// The repo slug a per-repo kind reads.
    repo: []const u8 = "",
    /// The PR state a `pull_requests` tab lists.
    state: State = .OPEN,
    mode: Mode = .none,
    /// Raw Bitbucket Query Language layered under the mode's own.
    q: []const u8 = "",
    /// A workspace PR tab that keeps only the account's own pull
    /// requests — what `--only prs-mine` synthesises.
    mine_only: bool = false,
};

/// The token's bucket: its knobs and where it lives (`ratelimit.zig`).
/// The defaults are the measured preset (`ratelimit.config`); a value
/// set here wins over it.
pub const Rate = struct {
    rate_per_sec: f64 = 1.2,
    capacity: f64 = 40.0,
    /// Attempts per request on a 429, retries included.
    max_attempts: u8 = 3,
    /// The first pause when a 429 carries no `Retry-After`; it doubles
    /// per attempt, jittered (`sdk.budget.Backoff`).
    default_backoff_secs: u32 = 15,
    /// The ceiling on that doubling. A `Retry-After` is honoured as the
    /// server sent it.
    max_backoff_secs: u32 = 30,
    /// The state file; empty means the token's own beside the shared
    /// one (see `ratelimit.zig`). Set, it names the file outright.
    state_path: []const u8 = "",
};

/// Spelled as Bitbucket spells `merge_strategy`, so a config reads
/// like the API it ends up in.
pub const MergeStrategy = enum { merge_commit, squash, fast_forward };

pub const Config = struct {
    /// Your Atlassian account email — the username half of Basic auth.
    email: []const u8 = "",
    /// The default workspace slug (`bitbucket.org/<workspace>/<repo>`).
    workspace: []const u8 = "",
    /// A scoped access token cannot read `/2.0/user`; naming the
    /// account here skips that call.
    account_id: []const u8 = "",
    /// 0 disables the auto-refresh; `r` still works. The poller's base:
    /// it doubles while polls come back unchanged, up to `poll_max_secs`,
    /// and snaps back here on a change, a key, a click or a focus.
    refresh_interval_secs: u32 = 60,
    /// The ceiling on that doubling. At or below the base the interval
    /// stays fixed.
    poll_max_secs: u32 = 120,
    /// An event file anything can append "this pull request changed" to
    /// (`sdk.feed`, the JSONL contract in `docs/SDK.md`). Empty is off.
    feed: sdk.feed.Config = .{},
    /// `shared_bucket`: a machine-wide token bucket file every caller on
    /// the machine draws from (`sdk.budget.Bucket`). Empty is none.
    budget: sdk.budget.Settings = .{},
    /// Which repos the workspace-wide tabs see.
    scope: Scope = .recent,
    /// A repo with activity in the last this-many days is "recent".
    recent_window_days: u32 = 14,
    /// The allow-list `scope = .explicit` uses.
    explicit_repos: []const []const u8 = &.{},
    /// Never listed, whatever the scope says.
    hidden_repos: []const []const u8 = &.{},
    /// Repos listed here render first, in this order.
    repo_order: []const []const u8 = &.{},
    /// The statusline chip counts only PRs updated this recently
    /// (0: all of them) …
    chip_stale_after_days: u32 = 90,
    /// Approvals a pull request needs before `[ Merge ]` stops being
    /// dim. Bitbucket keeps this per repository and the API does not
    /// offer it, so it is stated here rather than guessed at.
    required_approvals: usize = 1,
    /// The merge strategies this workspace allows, in the order the
    /// confirm offers them. Every repo allows a merge commit.
    merge_strategies: []const MergeStrategy = &.{ .merge_commit, .squash, .fast_forward },
    /// … and not those whose source branch matches one of these —
    /// `^prefix` anchors at the start, anything else is a substring.
    chip_excluded_branch_patterns: []const []const u8 = &.{ "^release/", "^hotfix/" },
    /// When set, both the chip and the workspace tabs read only these
    /// repos and never enumerate the workspace.
    repos: []const []const u8 = &.{},
    tabs: []const Tab = &.{},
    /// Override the API base — the fake server, or a test double.
    /// `$BITBUCKET_BASE_URL` wins over this.
    base_url: []const u8 = "",
    rate: Rate = .{},
    /// Dry run: log what WOULD be requested and answer from what is
    /// already held, sending nothing — for a morning near the limit.
    /// `Shift+N` (or `integrations.toggle_dry_run`) flips it for the
    /// session; the header's budget chip says `DRY` while it is on.
    dry_run: bool = false,
    /// How often each kind of thing is kept fresh. A listing drifts,
    /// a pipeline mid-run does not wait, and whether a pull request
    /// may merge is only ever asked about the row under the cursor —
    /// so they move at three speeds rather than one.
    /// `readiness_secs = 0` means what it says: on demand only.
    intervals: sdk.warm.Intervals = .{},

    pub fn isHidden(c: Config, slug: []const u8) bool {
        return contains(c.hidden_repos, slug);
    }

    /// The workspace a tab queries: its own override, else the default.
    pub fn tabWorkspace(c: Config, tab: Tab) []const u8 {
        return if (tab.workspace.len > 0) tab.workspace else c.workspace;
    }
};

pub fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// The reference's default three tabs, for a scaffold and for a
/// `--only` launch that finds a family missing.
pub const default_tabs = [_]Tab{
    .{ .name = "Open + Draft", .kind = .workspace_open_prs },
    .{ .name = "Merged", .kind = .workspace_merged_prs },
    .{ .name = "Pipelines", .kind = .workspace_pipelines },
};

pub const ValidateError = error{Invalid};

/// The rule the loader and `--check` both apply. `why` gets a line
/// the pane can paint.
pub fn validate(c: Config, why: *[]const u8) ValidateError!void {
    if (std.mem.trim(u8, c.email, " ").len == 0) {
        why.* = "`email` is required — your Atlassian account email";
        return error.Invalid;
    }
    if (std.mem.trim(u8, c.workspace, " ").len == 0) {
        why.* = "`workspace` is required — the slug in bitbucket.org/<workspace>/<repo>";
        return error.Invalid;
    }
    if (c.scope == .explicit and c.explicit_repos.len == 0) {
        why.* = "`scope = .explicit` needs a non-empty `explicit_repos`";
        return error.Invalid;
    }
    if (c.tabs.len == 0) {
        why.* = "at least one `.tabs` entry is required";
        return error.Invalid;
    }
    for (c.tabs) |tab| {
        if (tab.name.len == 0) {
            why.* = "a tab needs a `name`";
            return error.Invalid;
        }
        switch (tab.kind) {
            .workspace_open_prs, .workspace_merged_prs, .workspace_pipelines => {},
            .pull_requests => if (tab.mode == .none and tab.repo.len == 0 and tab.q.len == 0) {
                why.* = "a `pull_requests` tab needs a `repo`, a `mode` or a `q`";
                return error.Invalid;
            },
            .pipelines, .branches => if (tab.repo.len == 0) {
                why.* = "a `pipelines` / `branches` tab needs a `repo`";
                return error.Invalid;
            },
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
    // `HOME`, else `USERPROFILE` — the SDK's ladder (`manifest.dataRoot`);
    // Windows sets no `HOME`.
    if (nonEmpty(env.get("HOME")) orelse nonEmpty(env.get("USERPROFILE"))) |home| return try std.fs.path.join(gpa, &.{ home, ".config", "mnml" });
    return null;
}

pub fn nonEmpty(v: ?[]const u8) ?[]const u8 {
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

/// `why` outlives `load`'s arena, so the one reason that is not a
/// string literal — the path the scaffold went to — is copied here.
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
    const cfg = parseText(a, text) catch {
        why.* = "config.zon does not parse — check the trailing commas and the field names";
        return error.Malformed;
    };
    try validate(cfg, why);
    return .{ .arena = arena, .config = cfg, .path = owned_path };
}

pub fn parseText(arena: Allocator, text: [:0]const u8) !Config {
    // The parser unrolls a branch per field at compile time; a config
    // this wide passes the default quota.
    @setEvalBranchQuota(4000);
    return sdk.zig_compat.zonParse(Config, arena, text, null, .{});
}

/// The config as ZON, owned — what `save` writes.
pub fn render(gpa: Allocator, c: Config) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    out.writer.writeAll("// mnml-bitbucket — rewritten by the pane (x / H / s / alt+↑↓); see the README.\n") catch return error.OutOfMemory;
    std.zon.stringify.serialize(c, .{ .emit_default_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

/// Rewrite the file from `c` (a runtime change persisting).
pub fn save(gpa: Allocator, io: Io, path: []const u8, c: Config) !void {
    const text = try render(gpa, c);
    defer gpa.free(text);
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

/// Write the commented template. Used by first run and by `--scaffold`.
pub fn scaffold(io: Io, p: []const u8) !void {
    if (std.fs.path.dirname(p)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = template });
}

pub const template =
    \\// mnml-bitbucket — your Bitbucket Cloud workspace. The keys are the
    \\// reference's `mnml-forge-bitbucket.toml` keys by name.
    \\//
    \\// No token goes in here: put mnml's own token in <this folder>/token
    \\// (one line, chmod 600). When that file is there it is the token,
    \\// for reads and approvals, whatever your shell exports; without it
    \\// BITBUCKET_ACCESS_TOKEN, BITBUCKET_API_TOKEN, an app password or
    \\// BITBUCKET_PERSONAL_TOKEN answer — see the README's "Auth" section.
    \\.{
    \\    .email = "you@example.com",
    \\    .workspace = "your-workspace-slug",
    \\    // An access token (ATCTT…) has no account, so it cannot read
    \\    // /2.0/user: with one in the token file, name your account here
    \\    // or the `mine` / `reviewing` tabs have nothing to filter by.
    \\    // .account_id = "",
    \\
    \\    // Auto-refresh in seconds; 0 disables (`r` still works). It
    \\    // doubles while nothing changes, up to `poll_max_secs`, and
    \\    // snaps back on a change or a key.
    \\    .refresh_interval_secs = 60,
    \\    .poll_max_secs = 120,
    \\
    \\    // An event file that says which pull requests changed (one JSON
    \\    // line each: {"kind":"pr","key":"api#12","at":…,"source":…}).
    \\    // While it is live the listing is only swept every `sweep_secs`.
    \\    // .feed = .{ .file = "~/feeds/bitbucket.jsonl", .stale_secs = 300, .sweep_secs = 600 },
    \\
    \\    // A machine-wide token bucket file shared with other tools.
    \\    // .budget = .{ .shared_bucket = "~/buckets/bitbucket.json" },
    \\
    \\    // How often each kind of thing is kept fresh. A listing
    \\    // drifts; a pipeline mid-run does not wait; whether a pull
    \\    // request may merge is only asked about the row under the
    \\    // cursor, so `readiness_secs = 0` means on demand only.
    \\    .intervals = .{ .listing_secs = 300, .builds_secs = 90, .readiness_secs = 0 },
    \\
    \\    // Which repos the workspace-wide tabs see: .all, .recent (touched
    \\    // in the last `recent_window_days`), or .explicit (only
    \\    // `explicit_repos`). `s` in the pane cycles this.
    \\    .scope = .recent,
    \\    .recent_window_days = 14,
    \\    // .explicit_repos = .{ "frontend", "backend" },
    \\
    \\    // When set, the tabs and the statusline chip read only these
    \\    // repos and never enumerate the workspace — the cheap path.
    \\    .repos = .{},
    \\    // Never listed; `x` on a repo row adds to this, `H` clears it.
    \\    .hidden_repos = .{},
    \\    // Listed first, in this order; alt+↑ / alt+↓ rewrite it.
    \\    .repo_order = .{},
    \\
    \\    // The statusline chip: PRs you authored, updated in the last
    \\    // 90 days, not on a release/hotfix branch.
    \\    .chip_stale_after_days = 90,
    \\    .chip_excluded_branch_patterns = .{ "^release/", "^hotfix/" },
    \\
    \\    // 1-9 / tab switch tabs. The three workspace-wide kinds are the
    \\    // recommended set; per-repo kinds (.pull_requests / .pipelines /
    \\    // .branches) take a `.repo`.
    \\    .tabs = .{
    \\        .{ .name = "Open + Draft", .kind = .workspace_open_prs },
    \\        .{ .name = "Merged", .kind = .workspace_merged_prs },
    \\        .{ .name = "Pipelines", .kind = .workspace_pipelines },
    \\        // .{ .name = "api PRs", .kind = .pull_requests, .repo = "api", .state = .OPEN },
    \\        // .{ .name = "Mine", .kind = .pull_requests, .mode = .mine },
    \\    },
    \\}
    \\
;

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "dataRoot: MNML_DATA_ROOT, XDG_CONFIG_HOME, HOME, then USERPROFILE (Windows)" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try std.testing.expect((try dataRoot(gpa, &env)) == null);
    try env.put("USERPROFILE", "/profile");
    const want = try std.fs.path.join(gpa, &.{ "/profile", ".config", "mnml" });
    defer gpa.free(want);
    const got = (try dataRoot(gpa, &env)) orelse return error.TestExpectedDataRoot;
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got);
    try env.put("HOME", "/home/u");
    const want_home = try std.fs.path.join(gpa, &.{ "/home/u", ".config", "mnml" });
    defer gpa.free(want_home);
    const got_home = (try dataRoot(gpa, &env)) orelse return error.TestExpectedDataRoot;
    defer gpa.free(got_home);
    try std.testing.expectEqualStrings(want_home, got_home);
}

test "the scaffold parses and validates once the placeholders are real" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const z = try arena.allocator().dupeSentinel(u8, template, 0);
    const cfg = try parseText(arena.allocator(), z);
    var why: []const u8 = "";
    try validate(cfg, &why);
    try t.expectEqual(@as(usize, 3), cfg.tabs.len);
    try t.expectEqual(Kind.workspace_open_prs, cfg.tabs[0].kind);
    try t.expectEqual(Kind.workspace_pipelines, cfg.tabs[2].kind);
    try t.expectEqual(Scope.recent, cfg.scope);
    try t.expectEqual(@as(u32, 14), cfg.recent_window_days);
    try t.expectEqual(@as(u32, 90), cfg.chip_stale_after_days);
    try t.expectEqualStrings("^release/", cfg.chip_excluded_branch_patterns[0]);
}

test "the reference's TOML converts key for key" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try parseText(arena.allocator(),
        \\.{ .email = "me@x.com", .workspace = "acme", .account_id = "acct-1", .refresh_interval_secs = 60,
        \\   .scope = .recent, .recent_window_days = 14, .repos = .{ "api", "web" },
        \\   .tabs = .{ .{ .name = "Open + Draft", .kind = .workspace_open_prs }, .{ .name = "api", .kind = .pull_requests, .repo = "api", .state = .OPEN },
        \\              .{ .name = "Mine", .kind = .pull_requests, .mode = .mine }, .{ .name = "builds", .kind = .pipelines, .repo = "api" } } }
    );
    var why: []const u8 = "";
    try validate(cfg, &why);
    try t.expectEqualStrings("acct-1", cfg.account_id);
    try t.expectEqual(Mode.mine, cfg.tabs[2].mode);
    try t.expectEqual(Kind.pipelines, cfg.tabs[3].kind);
    try t.expect(cfg.tabs[0].kind.isWorkspaceWide());
    try t.expectEqual(Family.pipelines, cfg.tabs[3].kind.family());
}

test "validate names the missing key" {
    var why: []const u8 = "";
    try t.expectError(error.Invalid, validate(.{ .workspace = "w", .tabs = &default_tabs }, &why));
    try t.expect(std.mem.indexOf(u8, why, "email") != null);
    try t.expectError(error.Invalid, validate(.{ .email = "e", .workspace = "w" }, &why));
    try t.expect(std.mem.indexOf(u8, why, "tabs") != null);
    try t.expectError(error.Invalid, validate(.{ .email = "e", .workspace = "w", .tabs = &.{.{ .name = "x", .kind = .pipelines }} }, &why));
    try t.expect(std.mem.indexOf(u8, why, "repo") != null);
    try t.expectError(error.Invalid, validate(.{ .email = "e", .workspace = "w", .scope = .explicit, .tabs = &default_tabs }, &why));
    try t.expect(std.mem.indexOf(u8, why, "explicit_repos") != null);
    try validate(.{ .email = "e", .workspace = "w", .tabs = &.{.{ .name = "x", .kind = .pull_requests, .mode = .reviewing }} }, &why);
}

test "save rewrites the file and load reads the same config back" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const path = try std.fs.path.join(t.allocator, &.{ dir, "cfg", "config.zon" });
    defer t.allocator.free(path);
    try save(t.allocator, t.io, path, .{
        .email = "me@x.com",
        .workspace = "acme",
        .hidden_repos = &.{"old"},
        .repo_order = &.{ "web", "api" },
        .scope = .all,
        .tabs = &default_tabs,
    });
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("MNML_BITBUCKET_CONFIG", path);
    var why: []const u8 = "";
    var loaded = try load(t.allocator, t.io, &env, &why);
    defer loaded.deinit();
    try t.expectEqualStrings("old", loaded.config.hidden_repos[0]);
    try t.expectEqualStrings("web", loaded.config.repo_order[0]);
    try t.expectEqual(Scope.all, loaded.config.scope);
    try t.expectEqual(@as(usize, 3), loaded.config.tabs.len);
    try t.expectEqualStrings("Merged", loaded.config.tabs[1].name);
}

test "a missing config is scaffolded and reported with its path" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const path = try std.fs.path.join(t.allocator, &.{ dir, "never", "config.zon" });
    defer t.allocator.free(path);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("MNML_BITBUCKET_CONFIG", path);
    var why: []const u8 = "";
    try t.expectError(error.Scaffolded, load(t.allocator, t.io, &env, &why));
    try t.expectEqualStrings(path, why);
    // The scaffold's placeholders are non-empty, so a second load parses it.
    var loaded = try load(t.allocator, t.io, &env, &why);
    defer loaded.deinit();
    try t.expectEqualStrings("you@example.com", loaded.config.email);
}
