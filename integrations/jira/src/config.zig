//! `config.zon` — the integration's own file, in ZON because this repo
//! never reads TOML.
//!
//! Three sections, which are the Rust tracker's three TOML sections by
//! another spelling: `.jira` is the site and how to reach it (its
//! top-level `jira_url` / `email` / `team_field_*` / `projects`),
//! `.mnml` is how the pane behaves (its `refresh_interval_secs`,
//! `release_cut` and `[detail_modal]`), and `.tabs` is `[[tabs]]`
//! unchanged. `README.md` documents every key with an example.
//!
//! Where the file lives, first hit wins:
//!
//!   1. `--config PATH`
//!   2. `$MNML_JIRA_CONFIG`
//!   3. `<workspace>/.mnml/integrations/jira/config.zon`   (per project)
//!   4. `<data root>/integrations/jira/config.zon`         (the private-
//!      source install path — `~/.config/mnml/integrations/jira/`)
//!
//! A missing file is not an error: `Loaded.missing` carries the path the
//! pane should tell the user to write, and `example` is what to write.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const file_name = "config.zon";
pub const dir_name = "jira";
pub const env_path = "MNML_JIRA_CONFIG";
pub const max_file_bytes = 1 << 20;

/// Which REST version to speak. v3 takes and returns ADF for bodies; v2
/// takes wiki markup as a plain string. A Server / Data Center site only
/// has v2.
pub const ApiVersion = enum { v3, v2 };

/// How a `fix_version` tab picks its version out of the project's
/// unreleased ones.
pub const ResolveMode = enum { current_release, next_release };

/// The families a tab can be. `jql` on the tab overrides whatever the
/// kind would have built.
pub const TabKind = enum {
    /// Everything assigned to me and unresolved.
    work_assigned,
    /// What I closed in the last 30 days.
    work_recently_done,
    /// Anything I touched in the last 30 days.
    work_recent,
    /// Assigned to me, open or closed recently — one list.
    work_unified,
    /// A saved Jira filter (`filter_id`).
    filter,
    /// A release: `project` + the auto-resolved `fixVersion`.
    fix_version,
    /// A raw JQL the tab carries itself.
    custom,

    pub fn defaultJql(k: TabKind) ?[]const u8 {
        return switch (k) {
            .work_assigned =>
            \\assignee = currentUser() AND resolution = Unresolved AND status not in ("Done", "Closed", "Resolved") ORDER BY updated DESC
            ,
            .work_recently_done =>
            \\assignee = currentUser() AND status in (Done, Closed, Resolved) AND resolved >= -30d ORDER BY resolved DESC
            ,
            .work_recent =>
            \\(assignee was currentUser() OR reporter = currentUser() OR worklogAuthor = currentUser() OR commentedBy = currentUser()) AND updated >= -30d ORDER BY updated DESC
            ,
            .work_unified =>
            \\assignee = currentUser() AND (resolution is EMPTY OR resolved >= -30d) ORDER BY resolved DESC, updated DESC
            ,
            .filter, .fix_version, .custom => null,
        };
    }
};

/// A column of the ticket table. `summary` takes what is left.
pub const Column = enum {
    key,
    status,
    assignee,
    reporter,
    priority,
    type,
    updated,
    fix_version,
    summary,
    actions,

    /// Cells, the Rust tracker's numbers. `summary` is the flexible one.
    pub fn width(c: Column) ?u16 {
        return switch (c) {
            .key => 14,
            .status => 14,
            .assignee => 20,
            .reporter => 20,
            .priority => 10,
            .type => 10,
            .updated => 10,
            .fix_version => 14,
            .actions => 11,
            .summary => null,
        };
    }

    pub fn header(c: Column) []const u8 {
        return switch (c) {
            .key => "KEY",
            .status => "STATUS",
            .assignee => "ASSIGNEE",
            .reporter => "REPORTER",
            .priority => "PRIORITY",
            .type => "TYPE",
            .updated => "UPDATED",
            .fix_version => "FIXVERSION",
            .summary => "SUMMARY",
            .actions => "ACTIONS",
        };
    }
};

pub const default_columns = [_]Column{ .key, .status, .assignee, .updated, .summary, .actions };

/// How the tree buckets its top level.
pub const GroupBy = enum {
    /// Epic → story → sub-task, the issue hierarchy.
    hierarchy,
    /// A bucket per workflow status, in `status_order` then alphabetical
    /// — what the Rust tracker's tree does.
    status,
};

pub const Tab = struct {
    name: []const u8,
    kind: TabKind = .custom,
    /// Wins over whatever `kind` would build.
    jql: []const u8 = "",
    /// `fix_version` needs it; the team clause and the assignee picker
    /// use it when it is there.
    project: []const u8 = "",
    component: []const u8 = "",
    mode: ResolveMode = .current_release,
    /// Only consider versions whose name contains this (case-insensitive)
    /// — for a project with parallel release tracks.
    version_name_contains: []const u8 = "",
    filter_id: u64 = 0,
    /// A team value matched against the team field, the component and
    /// the labels. Empty means no team clause.
    team: []const u8 = "",
    columns: []const Column = &default_columns,
    group_by: GroupBy = .hierarchy,
    /// The status buckets, in order, when `group_by = .status`.
    status_order: []const []const u8 = &.{ "In Progress", "In Review", "Testing", "To Do", "Open", "Done" },

    /// The JQL this tab runs before the fixVersion resolve: the explicit
    /// one, else the filter form, else the kind's default. Null means it
    /// has to ask the server (a `fix_version` tab).
    pub fn staticJql(t: Tab, gpa: Allocator) Allocator.Error!?[]u8 {
        if (t.jql.len > 0) return try gpa.dupe(u8, t.jql);
        if (t.kind == .filter) {
            if (t.filter_id == 0) return null;
            return try std.fmt.allocPrint(gpa, "filter = {d} ORDER BY updated DESC", .{t.filter_id});
        }
        const d = t.kind.defaultJql() orelse return null;
        return try gpa.dupe(u8, d);
    }
};

/// The token bucket's parameters — `crates/mnml-ratelimit`'s Jira row.
pub const Rate = struct {
    per_sec: f64 = 0.33,
    burst: u32 = 60,
    /// The pause a 429 with no `Retry-After` takes, seconds.
    cooldown_secs: u32 = 45,
    /// The ceiling on one wait, seconds.
    max_block_secs: u32 = 120,
};

pub const Jira = struct {
    /// `https://acme.atlassian.net`; a trailing `/` is stripped on load.
    url: []const u8 = "",
    /// The Atlassian account email — the HTTP Basic user name.
    email: []const u8 = "",
    api: ApiVersion = .v3,
    /// The environment variable holding the API token.
    token_env: []const u8 = "JIRA_API_TOKEN",
    /// A file holding the API token. `~` is expanded. Empty means the
    /// default path (`auth.defaultTokenPath`).
    token_file: []const u8 = "",
    /// A Jira select custom field holding the team (`customfield_10056`).
    team_field_id: []const u8 = "",
    /// Its display name, which reads better in the JQL it goes into.
    team_field_name: []const u8 = "",
    /// Project keys the statusline count is scoped to. Sanitised to
    /// `[A-Z0-9]{1,10}` on load; anything else is dropped.
    projects: []const []const u8 = &.{},
    rate: Rate = .{},
};

pub const Mnml = struct {
    /// Auto-refresh the active tab after this many idle seconds. 0 off.
    refresh_interval_secs: u32 = 60,
    /// The detail pane's share of the width, per cent.
    detail_width_pct: u8 = 40,
    /// The detail pane starts open.
    detail_open: bool = true,
    /// `▼`/`▶` or `▾`/`▸` — matches mnml's own `$MNML_EXPAND_INDICATOR`.
    expand_indicator: enum { chevron, triangle } = .chevron,
    /// How many comments the detail pane shows, newest first.
    max_comments: u8 = 10,
    /// How many linked PRs a ticket shows before `Show all`.
    max_prs: u8 = 3,
    /// What `o` runs on a URL. Empty picks the platform's opener.
    open_command: []const u8 = "",
};

pub const Config = struct {
    jira: Jira = .{},
    mnml: Mnml = .{},
    tabs: []const Tab = &.{},
};

pub const ValidateError = error{
    NoUrl,
    NoEmail,
    NoTabs,
    TabWithoutName,
    FixVersionWithoutProject,
    FilterWithoutId,
    CustomWithoutJql,
};

/// The rule the pane applies before it tries to fetch anything. `why`
/// gets the line the empty state shows.
pub fn validate(c: Config, why: *[]const u8) ValidateError!void {
    if (c.jira.url.len == 0) {
        why.* = "jira.url is empty — set it to your Atlassian site";
        return error.NoUrl;
    }
    if (c.jira.email.len == 0) {
        why.* = "jira.email is empty — it is the HTTP Basic user name";
        return error.NoEmail;
    }
    if (c.tabs.len == 0) {
        why.* = "no tabs: add at least one .{ .name = \"…\", .kind = … }";
        return error.NoTabs;
    }
    for (c.tabs) |t| {
        if (t.name.len == 0) {
            why.* = "a tab has no name";
            return error.TabWithoutName;
        }
        if (t.kind == .fix_version and t.project.len == 0 and t.jql.len == 0) {
            why.* = "a fix_version tab needs .project = \"<KEY>\"";
            return error.FixVersionWithoutProject;
        }
        if (t.kind == .filter and t.filter_id == 0 and t.jql.len == 0) {
            why.* = "a filter tab needs .filter_id = <n>";
            return error.FilterWithoutId;
        }
        if (t.kind == .custom and t.jql.len == 0) {
            why.* = "a custom tab needs .jql = \"…\"";
            return error.CustomWithoutJql;
        }
    }
}

/// A project key as `projects` accepts it: 1–10 of `[A-Z0-9]`.
pub fn validProjectKey(k: []const u8) bool {
    if (k.len == 0 or k.len > 10) return false;
    for (k) |c| switch (c) {
        'A'...'Z', '0'...'9' => {},
        else => return false,
    };
    return true;
}

pub const Loaded = struct {
    /// Everything below lives on `arena`.
    config: Config,
    /// Where it was read from, or where it would have been.
    path: []const u8,
    /// No file at `path`: `config` is the defaults and the pane says so.
    missing: bool,
    /// The ZON did not parse; the message names the line.
    parse_error: ?[]const u8 = null,
};

pub const LoadOpts = struct {
    /// `--config PATH`.
    explicit: ?[]const u8 = null,
    /// `$MNML_WORKSPACE`, for the per-project file.
    workspace: ?[]const u8 = null,
    /// mnml's data root (`manifest.dataRoot`).
    data_root: ?[]const u8 = null,
};

/// The first candidate that exists, else the last one (the data-root
/// path — what the user should create).
pub fn resolvePath(arena: Allocator, io: Io, opts: LoadOpts, env_value: ?[]const u8) Allocator.Error![]const u8 {
    var last: []const u8 = file_name;
    if (opts.explicit) |p| return p;
    if (env_value) |p| if (p.len > 0) return p;
    if (opts.workspace) |ws| if (ws.len > 0) {
        const p = try std.fs.path.join(arena, &.{ ws, ".mnml", "integrations", dir_name, file_name });
        if (exists(io, p)) return p;
        last = p;
    };
    if (opts.data_root) |root| if (root.len > 0) {
        const p = try std.fs.path.join(arena, &.{ root, "integrations", dir_name, file_name });
        if (exists(io, p)) return p;
        last = p;
    };
    return last;
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Read and parse. Everything in the result lives on `arena`.
pub fn load(arena: Allocator, io: Io, path: []const u8) Allocator.Error!Loaded {
    const src = Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(max_file_bytes), .of(u8), 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .config = .{}, .path = path, .missing = true },
    };
    return parse(arena, src, path);
}

pub fn parse(arena: Allocator, src: [:0]const u8, path: []const u8) Allocator.Error!Loaded {
    var diag: std.zon.parse.Diagnostics = .{};
    const cfg = std.zon.parse.fromSliceAlloc(Config, arena, src, &diag, .{ .free_on_error = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            const msg = std.fmt.allocPrint(arena, "{f}", .{diag}) catch "could not be parsed";
            return .{ .config = .{}, .path = path, .missing = false, .parse_error = msg };
        },
    };
    return .{ .config = try normalise(arena, cfg), .path = path, .missing = false };
}

/// The tidying both readers want: a trailing `/` off the URL, project
/// keys sanitised, the detail width kept inside a sane band.
pub fn normalise(arena: Allocator, in: Config) Allocator.Error!Config {
    var c = in;
    c.jira.url = std.mem.trimEnd(u8, std.mem.trim(u8, c.jira.url, " \t\r\n"), "/");
    c.jira.email = std.mem.trim(u8, c.jira.email, " \t\r\n");
    if (c.jira.projects.len > 0) {
        var keep: std.ArrayListUnmanaged([]const u8) = .empty;
        for (c.jira.projects) |k| if (validProjectKey(k)) try keep.append(arena, k);
        c.jira.projects = try keep.toOwnedSlice(arena);
    }
    c.mnml.detail_width_pct = std.math.clamp(c.mnml.detail_width_pct, 20, 70);
    if (c.mnml.max_comments == 0) c.mnml.max_comments = 1;
    if (c.mnml.max_prs == 0) c.mnml.max_prs = 1;
    return c;
}

/// What `mnml-jira --write-config` puts on disk, and what the pane's
/// empty state tells the user to write.
pub const example =
    \\// mnml-jira — the Jira ticket viewer. See integrations/jira/README.md.
    \\.{
    \\    .jira = .{
    \\        .url = "https://acme.atlassian.net",
    \\        .email = "you@acme.com",
    \\        // The token is never written here. It comes from this
    \\        // environment variable, or from .token_file.
    \\        .token_env = "JIRA_API_TOKEN",
    \\        // .token_file = "~/.config/mnml/integrations/jira/token",
    \\        .api = .v3,
    \\        // .team_field_id = "customfield_10056",
    \\        // .team_field_name = "Team",
    \\        .projects = .{"ENG"},
    \\    },
    \\    .mnml = .{
    \\        .refresh_interval_secs = 60,
    \\        .detail_width_pct = 40,
    \\    },
    \\    .tabs = .{
    \\        .{ .name = "Mine", .kind = .work_assigned },
    \\        .{ .name = "Recent", .kind = .work_recent },
    \\        .{
    \\            .name = "Release",
    \\            .kind = .fix_version,
    \\            .project = "ENG",
    \\            .mode = .current_release,
    \\        },
    \\    },
    \\}
    \\
;

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "the example config parses, normalises and validates" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const src = try a.allocator().dupeZ(u8, example);
    const loaded = try parse(a.allocator(), src, "example");
    try testing.expect(loaded.parse_error == null);
    const c = loaded.config;
    try testing.expectEqualStrings("https://acme.atlassian.net", c.jira.url);
    try testing.expectEqual(ApiVersion.v3, c.jira.api);
    try testing.expectEqual(@as(usize, 1), c.jira.projects.len);
    try testing.expectEqual(@as(usize, 3), c.tabs.len);
    try testing.expectEqual(TabKind.work_assigned, c.tabs[0].kind);
    try testing.expectEqual(TabKind.fix_version, c.tabs[2].kind);
    try testing.expectEqual(ResolveMode.current_release, c.tabs[2].mode);
    // The defaults every tab inherits.
    try testing.expectEqual(GroupBy.hierarchy, c.tabs[0].group_by);
    try testing.expectEqualSlices(Column, &default_columns, c.tabs[0].columns);
    var why: []const u8 = "";
    try validate(c, &why);
}

test "normalise strips the trailing slash, drops bad project keys and clamps the split" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const c = try normalise(a.allocator(), .{
        .jira = .{ .url = " https://x.atlassian.net/ ", .email = " me@x ", .projects = &.{ "ENG", "eng", "", "TOOLONGPROJECTKEY", "A1" } },
        .mnml = .{ .detail_width_pct = 95, .max_comments = 0, .max_prs = 0 },
    });
    try testing.expectEqualStrings("https://x.atlassian.net", c.jira.url);
    try testing.expectEqualStrings("me@x", c.jira.email);
    try testing.expectEqual(@as(usize, 2), c.jira.projects.len);
    try testing.expectEqualStrings("ENG", c.jira.projects[0]);
    try testing.expectEqualStrings("A1", c.jira.projects[1]);
    try testing.expectEqual(@as(u8, 70), c.mnml.detail_width_pct);
    try testing.expectEqual(@as(u8, 1), c.mnml.max_comments);
    try testing.expectEqual(@as(u8, 1), c.mnml.max_prs);
}

test "validate names the one thing that is wrong" {
    var why: []const u8 = "";
    try testing.expectError(error.NoUrl, validate(.{}, &why));
    try testing.expect(std.mem.indexOf(u8, why, "jira.url") != null);
    const site: Jira = .{ .url = "https://x", .email = "me@x" };
    try testing.expectError(error.NoTabs, validate(.{ .jira = site }, &why));
    try testing.expectError(error.FixVersionWithoutProject, validate(.{
        .jira = site,
        .tabs = &.{.{ .name = "R", .kind = .fix_version }},
    }, &why));
    try testing.expect(std.mem.indexOf(u8, why, ".project") != null);
    try testing.expectError(error.FilterWithoutId, validate(.{
        .jira = site,
        .tabs = &.{.{ .name = "F", .kind = .filter }},
    }, &why));
    try testing.expectError(error.CustomWithoutJql, validate(.{
        .jira = site,
        .tabs = &.{.{ .name = "C" }},
    }, &why));
    try testing.expectError(error.TabWithoutName, validate(.{
        .jira = site,
        .tabs = &.{.{ .name = "", .jql = "x" }},
    }, &why));
    // A fix_version tab with an explicit JQL needs no project.
    try validate(.{ .jira = site, .tabs = &.{.{ .name = "R", .kind = .fix_version, .jql = "project = X" }} }, &why);
}

test "staticJql: the explicit one wins, then the filter form, then the kind's default; fix_version has to ask" {
    const gpa = testing.allocator;
    const mine = (try (Tab{ .name = "M", .kind = .work_assigned }).staticJql(gpa)).?;
    defer gpa.free(mine);
    try testing.expect(std.mem.startsWith(u8, mine, "assignee = currentUser()"));
    const over = (try (Tab{ .name = "M", .kind = .work_assigned, .jql = "project = X" }).staticJql(gpa)).?;
    defer gpa.free(over);
    try testing.expectEqualStrings("project = X", over);
    const filt = (try (Tab{ .name = "F", .kind = .filter, .filter_id = 12 }).staticJql(gpa)).?;
    defer gpa.free(filt);
    try testing.expectEqualStrings("filter = 12 ORDER BY updated DESC", filt);
    try testing.expect((try (Tab{ .name = "R", .kind = .fix_version, .project = "X" }).staticJql(gpa)) == null);
    try testing.expect((try (Tab{ .name = "C" }).staticJql(gpa)) == null);
}

test "a broken config comes back as a parse error, not a crash; a missing one is missing" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const src = try a.allocator().dupeZ(u8, ".{ .jira = .{ .url = ");
    const bad = try parse(a.allocator(), src, "bad.zon");
    try testing.expect(bad.parse_error != null);
    try testing.expect(!bad.missing);
    const gone = try load(a.allocator(), testing.io, "/nowhere/at/all/config.zon");
    try testing.expect(gone.missing);
    try testing.expectEqual(@as(usize, 0), gone.config.tabs.len);
}

test "columns carry their width and header; summary is the flexible one" {
    try testing.expectEqual(@as(?u16, 14), Column.key.width());
    try testing.expect(Column.summary.width() == null);
    try testing.expectEqualStrings("FIXVERSION", Column.fix_version.header());
}

test "resolvePath prefers the workspace file, then the data root, and names the data root when neither is there" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    const ws = try std.fs.path.join(arena, &.{ root, "ws" });
    const data = try std.fs.path.join(arena, &.{ root, "data" });
    // Neither exists: the data-root path is what the pane names.
    const none = try resolvePath(arena, testing.io, .{ .workspace = ws, .data_root = data }, null);
    try testing.expect(std.mem.endsWith(u8, none, "data/integrations/jira/config.zon"));
    // The data-root one exists: it wins over the absent workspace one.
    try tmp.dir.createDirPath(testing.io, "data/integrations/jira");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data/integrations/jira/config.zon", .data = ".{}" });
    const in_data = try resolvePath(arena, testing.io, .{ .workspace = ws, .data_root = data }, null);
    try testing.expect(std.mem.endsWith(u8, in_data, "data/integrations/jira/config.zon"));
    // The workspace one exists: it wins over both.
    try tmp.dir.createDirPath(testing.io, "ws/.mnml/integrations/jira");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/.mnml/integrations/jira/config.zon", .data = ".{}" });
    const in_ws = try resolvePath(arena, testing.io, .{ .workspace = ws, .data_root = data }, null);
    try testing.expect(std.mem.endsWith(u8, in_ws, "ws/.mnml/integrations/jira/config.zon"));
    // The environment beats the lot; `--config` beats that.
    try testing.expectEqualStrings("/from/env.zon", try resolvePath(arena, testing.io, .{ .workspace = ws, .data_root = data }, "/from/env.zon"));
    try testing.expectEqualStrings("/flag.zon", try resolvePath(arena, testing.io, .{ .explicit = "/flag.zon", .workspace = ws }, "/from/env.zon"));
}
