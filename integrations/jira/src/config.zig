//! `config.zon` — the reference tracker's TOML config, key for key, in
//! ZON. Every top-level key of `~/.config/mnml-tracker-jira.toml`
//! (`jira_url`, `email`, `refresh_interval_secs`, `release_cut`,
//! `team_field_id`, `team_field_name`, `dispatch_workspace`, `projects`,
//! `[detail_modal]`, `[[tabs]]`) and every `[[tabs]]` key (`name`,
//! `kind`, `mode`, `jql`, `project`, `component`, `columns`,
//! `status_order`, `bumps`, `version_name_contains`, `team`,
//! `issue_type`, `label`, `board_id`, `filter_id`, `reported_window_days`)
//! is the same word
//! here, so a file converts mechanically:
//!
//!   jira_url = "https://x"           .jira_url = "https://x",
//!   [[tabs]] name = "Sprint"         .tabs = .{ .{ .name = "Sprint",
//!     kind = "board_active_sprint"       .kind = .board_active_sprint,
//!     board_id = 200                     .board_id = 200 } },
//!   [tabs.bumps]                     .bumps = .{
//!     pr_approved = "Testing"            .pr_approved = "Testing",
//!     release_cut = { Done = "top" }     .release_cut = .{ .{ .status = "Done", .target = "top" } } },
//!   [detail_modal] fields = [        .detail_modal = .{ .fields = .{
//!     "assignee",                        .{ .id = "assignee" },
//!     { id = "customfield_1", label = "X" } ]   .{ .id = "customfield_1", .label = "X" } } },
//!   [detail_modal.field_alias]       .field_alias = .{ .{ .name = "problem", .id = "customfield_1" } }
//!     problem = "customfield_1"
//!
//! The two shapes ZON cannot spell the TOML way — a string-or-table list
//! and a string-keyed map — are lists of small structs; the README has
//! the table. Keys the reference does not have (`token_file`,
//! `token_env`, `api`, `rate`, `bitbucket_api_url`) are the port's own
//! and default sensibly.
//!
//! Where the file lives, first hit wins: `--config PATH`,
//! `$MNML_JIRA_CONFIG`, `<workspace>/.mnml/integrations/jira/config.zon`,
//! `<data root>/integrations/jira/config.zon`.
//!
//! One key can be overridden from the environment: `$JIRA_BASE_URL`
//! wins over `.jira_url`, literally or as `@<path>` naming a file that
//! holds it. That is how a test points the pane at a server on a port
//! nobody chose — `mnml-fake-jira --port 0 --url-file jira.url` — the
//! same shape as Bitbucket's `$BITBUCKET_BASE_URL`, which in turn wins
//! over `.bitbucket_api_url` (the linked pull requests' server). Both
//! are read by `sdk.base_url`: an `@<path>` whose file never arrives is
//! `Loaded.base_url_error`, and nothing is asked of any server.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sdk = @import("mnml_sdk");

pub const file_name = "config.zon";
pub const dir_name = "jira";
pub const env_path = "MNML_JIRA_CONFIG";
/// The base URL override — see `envBaseUrl`.
pub const base_url_env = "JIRA_BASE_URL";
/// The linked pull requests' server, overridden the same way.
pub const forge_base_url_env = "BITBUCKET_BASE_URL";
/// How long a missing `@<path>` is waited for: the fake writes it once
/// it listens. A test that proves the refusal does not sit out 5 s.
pub const url_file_wait_ms: u32 = if (@import("builtin").is_test) 50 else 5000;
pub const max_file_bytes = 1 << 20;

pub const ApiVersion = enum { v3, v2 };
pub const ResolveMode = enum { current_release, next_release };

/// The three chips the reference ships — `--only work` / `fix-versions`
/// / `boards` — and which tab kinds each keeps.
pub const Family = enum {
    work,
    fix_versions,
    boards,

    /// The CLI spelling(s) the reference accepts.
    pub fn fromCli(s: []const u8) ?Family {
        if (std.mem.eql(u8, s, "work") or std.mem.eql(u8, s, "jira_work")) return .work;
        if (std.mem.eql(u8, s, "fix-versions") or std.mem.eql(u8, s, "fix_versions") or std.mem.eql(u8, s, "fix_version")) return .fix_versions;
        if (std.mem.eql(u8, s, "boards") or std.mem.eql(u8, s, "jira_boards")) return .boards;
        return null;
    }

    pub fn cli(f: Family) []const u8 {
        return switch (f) {
            .work => "work",
            .fix_versions => "fix-versions",
            .boards => "boards",
        };
    }

    /// The manifest id.
    pub fn id(f: Family) []const u8 {
        return switch (f) {
            .work => "jira_work",
            .fix_versions => "jira_fix_versions",
            .boards => "jira_boards",
        };
    }

    pub fn label(f: Family) []const u8 {
        return switch (f) {
            .work => "Jira Work",
            .fix_versions => "Jira Fix Versions",
            .boards => "Jira Boards",
        };
    }

    /// The pane's caps title.
    pub fn title(f: Family) []const u8 {
        return switch (f) {
            .work => "JIRA WORK",
            .fix_versions => "JIRA FIX VERSIONS",
            .boards => "JIRA BOARDS",
        };
    }
};

pub const TabKind = enum {
    work_assigned,
    /// "Reported by me" — everything still open that you filed.
    work_reported,
    /// "My open work items" — the assigned-and-unresolved query under
    /// the name it reads as on a tab strip. The count it publishes is
    /// the first statusline figure.
    work_open,
    work_recently_done,
    work_recent,
    work_unified,
    /// A tab whose JQL is the user's, written with `{name}` holes its
    /// `vars` fill in. The holes are what the pane's `E` editor edits,
    /// so a fixVersion list can be changed without opening the config.
    jql_editable,
    filter,
    fix_version_tree,
    board_active_sprint,
    board_backlog,

    pub fn family(k: TabKind) Family {
        return switch (k) {
            .work_assigned, .work_reported, .work_open, .work_recently_done, .work_recent, .work_unified, .jql_editable, .filter => .work,
            .fix_version_tree => .fix_versions,
            .board_active_sprint, .board_backlog => .boards,
        };
    }

    /// The reference's JQL for the kind, where it is static. Release
    /// tabs resolve a version first; filter tabs need their id; an
    /// editable tab's JQL is the user's own.
    pub fn defaultJql(k: TabKind) ?[]const u8 {
        return switch (k) {
            .work_assigned, .work_open => "assignee = currentUser() AND resolution = Unresolved AND status not in (\"Done\", \"Done in Staging\", \"Done in Production\") ORDER BY updated DESC",
            .work_reported => reported_default_jql,
            .work_recently_done => "assignee = currentUser() AND status in (Done, Closed, Resolved) AND resolved >= -30d ORDER BY resolved DESC",
            .work_recent => "(assignee was currentUser() OR reporter = currentUser() OR worklogAuthor = currentUser() OR commentedBy = currentUser()) AND updated >= -30d ORDER BY updated DESC",
            .work_unified => "assignee = currentUser() AND (resolution is EMPTY OR resolved >= -30d) ORDER BY resolved DESC, updated DESC",
            .board_active_sprint => "sprint in openSprints() ORDER BY rank ASC",
            .board_backlog => "sprint is EMPTY AND status != Done ORDER BY rank ASC",
            .fix_version_tree, .filter, .jql_editable => null,
        };
    }

    /// Which tab feeds the first statusline figure — how much is on
    /// your plate. `work_open` is the name it is meant to be read
    /// under; `work_assigned` is the same query under the old one.
    pub fn isAssignedOpen(k: TabKind) bool {
        return k == .work_assigned or k == .work_open;
    }

    pub fn isKanban(k: TabKind) bool {
        return k == .board_active_sprint or k == .board_backlog;
    }
};

// ─── the Reported-by-me window ──────────────────────────────────────────

/// How far back "Reported by me" looks, in days, before anything is
/// widened: the reference's own filter is every ticket you ever filed,
/// newest first, which on a long-lived account is thousands of rows and
/// a slow tab. Two weeks is the day's worth of it.
pub const reported_window_default: u16 = 14;

/// The steps the window widens through, in order. Past the last one it
/// widens to no window at all, and then there is nothing left to press.
pub const reported_window_steps = [_]u16{ 14, 30, 90 };

/// The unwidened query, as a literal so `defaultJql` can stay one.
pub const reported_default_jql = "reporter = currentUser() AND created >= -14d ORDER BY created DESC";

/// Jira's own "Reported by me" is `reporter = currentUser() ORDER BY
/// created DESC` — newest FILED first, every resolution. The port's was
/// `resolution = Unresolved ORDER BY updated DESC`, which is a
/// different tab wearing the same name. This is the reference's, with
/// the created window bolted on; `days` of 0 is no window, which is the
/// reference's query exactly.
pub fn reportedJql(arena: Allocator, days: u16) Allocator.Error![]const u8 {
    if (days == 0) return "reporter = currentUser() ORDER BY created DESC";
    if (days == reported_window_default) return reported_default_jql;
    return std.fmt.allocPrint(arena, "reporter = currentUser() AND created >= -{d}d ORDER BY created DESC", .{days});
}

/// The step out from a window of `days`: the next one up the table, or
/// 0 (no window) once past the last. Null when there is nowhere left to
/// go — already at no window — which is what makes the row disappear.
/// A hand-set `reported_window_days` that is not in the table lands on
/// the first step wider than it, so a custom 45 still widens to 90.
pub fn nextReportedWindow(days: u16) ?u16 {
    if (days == 0) return null;
    for (reported_window_steps) |step| if (step > days) return step;
    return 0;
}

/// How a window reads in the row that widens it: `2 weeks`, `30 days`,
/// `all time`. Two weeks is spelled the way the ask spelled it.
pub fn windowLabel(buf: []u8, days: u16) []const u8 {
    if (days == 0) return "all time";
    if (days == reported_window_default) return "2 weeks";
    return std.fmt.bufPrint(buf, "{d} days", .{days}) catch "a while";
}

/// One `{name}` hole in a `jql_editable` tab's JQL, and what fills it.
///
/// ZON has no string-keyed map, so `vars` is a list of these — the same
/// shape `bumps.release_cut` and `detail_modal.field_alias` use. A var
/// carries either one `value` (`project = {project}`) or a list of
/// `values` (`fixVersion in ({versions})`, which expands to the quoted,
/// comma-joined list). `values` wins when both are set.
pub const Var = struct {
    name: []const u8,
    value: []const u8 = "",
    values: []const []const u8 = &.{},

    pub fn isList(v: Var) bool {
        return v.values.len > 0 or v.value.len == 0;
    }
};

/// `{name}` holes in `jql` filled from `vars`; a name with no var is
/// left exactly as it was, so a typo shows up in the JQL rather than
/// silently becoming an empty clause.
pub fn expandVars(arena: Allocator, jql: []const u8, vars: []const Var) Allocator.Error![]const u8 {
    if (vars.len == 0 or std.mem.indexOfScalar(u8, jql, '{') == null) return jql;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < jql.len) {
        if (jql[i] != '{') {
            try out.append(arena, jql[i]);
            i += 1;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, jql, i + 1, '}') orelse {
            try out.append(arena, jql[i]);
            i += 1;
            continue;
        };
        const name = jql[i + 1 .. close];
        const v: ?Var = blk: {
            for (vars) |candidate| if (std.mem.eql(u8, candidate.name, name)) break :blk candidate;
            break :blk null;
        };
        if (v) |found| {
            if (found.values.len > 0) {
                for (found.values, 0..) |one, n| {
                    if (n > 0) try out.appendSlice(arena, ", ");
                    try out.append(arena, '"');
                    for (one) |c| {
                        if (c == '"' or c == '\\') try out.append(arena, '\\');
                        try out.append(arena, c);
                    }
                    try out.append(arena, '"');
                }
            } else try out.appendSlice(arena, found.value);
            i = close + 1;
        } else {
            try out.append(arena, jql[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

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

    /// Cells; `summary` takes what is left. KEY is the tree's width
    /// (chevron, indent, key, bump star).
    pub fn width(c: Column) ?u16 {
        return switch (c) {
            .key => 18,
            .status => 14,
            .assignee => 20,
            .reporter => 20,
            .priority => 10,
            .type => 10,
            .updated => 12,
            .fix_version => 14,
            .actions => 11,
            .summary => null,
        };
    }

    /// The narrowest the column still reads at — a date's ten cells
    /// and a space, a name's first word. KEY's is the longest key on
    /// the tab (`screen.zig` works it out); SUMMARY takes what is left.
    pub fn minWidth(c: Column) u16 {
        return switch (c) {
            .key => 12,
            .status => 8,
            .assignee, .reporter => 10,
            .priority, .type => 7,
            .updated => 11,
            .fix_version => 9,
            .actions => 11,
            .summary => 20,
        };
    }

    /// When a narrow pane runs out of width, the columns go whole in
    /// this order (1 first); KEY and SUMMARY never do — the key is what
    /// a row is known by, and the summary is what is elided instead.
    pub fn dropRank(c: Column) u8 {
        return switch (c) {
            .actions => 1,
            .fix_version => 2,
            .type => 3,
            .priority => 4,
            .reporter => 5,
            .assignee => 6,
            .updated => 7,
            .status => 8,
            .key, .summary => 0,
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

/// The reference's tree columns.
pub const default_columns = [_]Column{ .key, .status, .assignee, .updated, .summary };

/// `release_cut = { Done = "top" }` as a list: one rule per status.
pub const StatusRule = struct { status: []const u8, target: []const u8 };

pub const Bumps = struct {
    /// PR-review tickets with an approved PR go into this group.
    pr_approved: []const u8 = "",
    /// PR-review tickets with no open PR left go into this group.
    no_open_prs: []const u8 = "",
    /// With the global `release_cut` on: status → target group, or `top`.
    release_cut: []const StatusRule = &.{},
};

pub const Tab = struct {
    name: []const u8 = "",
    kind: ?TabKind = null,
    mode: ?ResolveMode = null,
    jql: []const u8 = "",
    project: []const u8 = "",
    component: []const u8 = "",
    columns: ?[]const Column = null,
    status_order: ?[]const []const u8 = null,
    bumps: ?Bumps = null,
    version_name_contains: []const u8 = "",
    team: []const u8 = "",
    issue_type: []const u8 = "",
    label: []const u8 = "",
    board_id: u64 = 0,
    filter_id: u64 = 0,
    /// How far back a `work_reported` tab looks when it opens, in days.
    /// 0 opens it on every ticket you ever filed. Ignored on every other
    /// kind. The tab widens from here at runtime; this is only where it
    /// starts, and a restart starts it here again.
    reported_window_days: u16 = reported_window_default,
    /// A `jql_editable` tab's `{name}` holes. Ignored on every other kind.
    vars: []const Var = &.{},

    /// A kinded tab is a tree (or a kanban); a legacy one a flat table.
    pub fn isTree(t: Tab) bool {
        return t.kind != null and !t.isKanban();
    }

    pub fn isKanban(t: Tab) bool {
        return if (t.kind) |k| k.isKanban() else false;
    }

    pub fn isFixVersions(t: Tab) bool {
        return t.kind == .fix_version_tree;
    }

    pub fn isWorkFamily(t: Tab) bool {
        return if (t.kind) |k| k.family() == .work else false;
    }

    /// The JQL known before any call: the explicit one, a saved filter,
    /// or the kind's default. Null means "resolve a version first".
    pub fn staticJql(t: Tab, arena: Allocator) Allocator.Error!?[]const u8 {
        if (t.jql.len > 0) return try expandVars(arena, t.jql, t.vars);
        if (t.kind) |k| {
            if (k == .filter) {
                if (t.filter_id == 0) return null;
                return try std.fmt.allocPrint(arena, "filter = {d} ORDER BY updated DESC", .{t.filter_id});
            }
            if (k == .work_reported) return try reportedJql(arena, t.reported_window_days);
            return k.defaultJql();
        }
        return null;
    }

    pub fn isEditableJql(t: Tab) bool {
        return t.kind == .jql_editable;
    }

    pub fn statusOrder(t: Tab) []const []const u8 {
        return t.status_order orelse &default_status_order;
    }

    pub fn columnSet(t: Tab) []const Column {
        return t.columns orelse &default_columns;
    }
};

/// One entry of `[detail_modal] fields`: a bare TOML string is
/// `.{ .id = "assignee" }`; an inline table keeps its `label`.
pub const FieldSpec = struct { id: []const u8, label: []const u8 = "" };
pub const Alias = struct { name: []const u8, id: []const u8 };

pub const default_detail_fields = [_]FieldSpec{
    .{ .id = "type" },       .{ .id = "priority" },    .{ .id = "assignee" }, .{ .id = "reporter" }, .{ .id = "labels" },
    .{ .id = "components" }, .{ .id = "fix_version" }, .{ .id = "sprint" },   .{ .id = "parent" },   .{ .id = "description" },
};

pub const DetailModal = struct {
    fields: []const FieldSpec = &default_detail_fields,
    field_alias: []const Alias = &.{},

    /// The Jira field id a spec names, after the alias map.
    pub fn resolveId(m: DetailModal, spec: FieldSpec) []const u8 {
        for (m.field_alias) |a| if (std.mem.eql(u8, a.name, spec.id)) return a.id;
        return spec.id;
    }

    /// The label beside the value: the spec's own, an alias name whose
    /// id this is, or the built-in title case.
    pub fn resolveLabel(m: DetailModal, spec: FieldSpec) []const u8 {
        if (spec.label.len > 0) return spec.label;
        for (m.field_alias) |a| if (std.mem.eql(u8, a.id, spec.id)) return a.name;
        return defaultLabel(spec.id);
    }
};

pub fn defaultLabel(name: []const u8) []const u8 {
    const table = [_][2][]const u8{
        .{ "title", "Title" },       .{ "summary", "Title" },         .{ "status", "Status" },           .{ "type", "Type" },
        .{ "issuetype", "Type" },    .{ "priority", "Priority" },     .{ "assignee", "Assignee" },       .{ "reporter", "Reporter" },
        .{ "labels", "Labels" },     .{ "components", "Components" }, .{ "fix_version", "Fix version" }, .{ "fixversions", "Fix version" },
        .{ "sprint", "Sprint" },     .{ "parent", "Parent" },         .{ "description", "Description" }, .{ "environment", "Environment" },
        .{ "severity", "Severity" },
    };
    for (table) |row| if (std.mem.eql(u8, row[0], name)) return row[1];
    return name;
}

/// The limiter's numbers — the reference's Jira row.
pub const Rate = struct {
    per_sec: f64 = 0.33,
    burst: u32 = 60,
    cooldown_secs: u32 = 45,
    max_block_secs: u32 = 120,
};

pub const Config = struct {
    jira_url: []const u8 = "",
    email: []const u8 = "",
    refresh_interval_secs: u32 = 60,
    release_cut: bool = false,
    team_field_id: []const u8 = "",
    team_field_name: []const u8 = "",
    dispatch_workspace: []const u8 = "",
    projects: []const []const u8 = &.{},
    detail_modal: DetailModal = .{},
    tabs: []const Tab = &.{},
    // ── the port's own keys ──
    /// A token file; `~` expands. Empty: `$token_env`, then the default
    /// file, then the reference's own `~/.config/mnml-tracker-jira/token`.
    token_file: []const u8 = "",
    token_env: []const u8 = "",
    api: ApiVersion = .v3,
    rate: Rate = .{},
    /// How often each kind of thing is kept fresh. A listing drifts,
    /// a pipeline mid-run does not wait, and whether a pull request
    /// may merge is only ever asked about the row under the cursor —
    /// so they move at three speeds rather than one.
    /// `readiness_secs = 0` means what it says: on demand only.
    intervals: sdk.warm.Intervals = .{},
    /// The forge the post-merge pipeline rows come from.
    bitbucket_api_url: []const u8 = "https://api.bitbucket.org/2.0",
    /// Approvals a pull request needs before its `[ Merge ]` stops
    /// being dim. Bitbucket keeps this per repository and the API does
    /// not offer it, so it is stated here rather than guessed at.
    required_approvals: usize = 1,
    bitbucket_token_env: []const u8 = "BITBUCKET_ACCESS_TOKEN",
    /// The browser opener; empty picks the platform's.
    open_command: []const u8 = "",

    /// The team field the JQL clause uses: the display name where there
    /// is one, else the id.
    pub fn teamField(c: Config) []const u8 {
        return if (c.team_field_name.len > 0) c.team_field_name else c.team_field_id;
    }
};

/// The reference's built-in status order for release tabs.
pub const default_status_order = [_][]const u8{ "Testing", "In PR Review", "Code Review", "In Progress", "To Do", "Open", "Done" };

pub const ValidateError = error{ NoUrl, NoEmail, NoTabs, TabWithoutName, TabNeedsProject, FilterWithoutId, EditableWithoutJql, TabNeedsJqlOrMode, TabJqlAndMode };

/// The reference's rules, so a converted file fails the same way.
pub fn validate(c: Config, why: *[]const u8) ValidateError!void {
    if (c.jira_url.len == 0) {
        why.* = ".jira_url is empty";
        return error.NoUrl;
    }
    if (c.email.len == 0) {
        why.* = ".email is empty";
        return error.NoEmail;
    }
    if (c.tabs.len == 0) {
        why.* = ".tabs needs at least one entry";
        return error.NoTabs;
    }
    for (c.tabs) |t| {
        if (t.name.len == 0) {
            why.* = "a tab has no .name";
            return error.TabWithoutName;
        }
        if (t.kind) |k| {
            if (t.jql.len > 0 and t.mode != null) {
                why.* = "a tab sets both .jql and .mode (the kind supplies a default)";
                return error.TabJqlAndMode;
            }
            switch (k) {
                .fix_version_tree, .board_active_sprint, .board_backlog => if (t.project.len == 0) {
                    why.* = "a fix_version_tree / board tab needs .project = \"<KEY>\"";
                    return error.TabNeedsProject;
                },
                .filter => if (t.filter_id == 0) {
                    why.* = "a filter tab needs .filter_id = <n>";
                    return error.FilterWithoutId;
                },
                .jql_editable => if (t.jql.len == 0) {
                    why.* = "a jql_editable tab needs .jql = \"…\" (with `{name}` holes its .vars fill in)";
                    return error.EditableWithoutJql;
                },
                else => {},
            }
            continue;
        }
        if (t.jql.len > 0 and t.mode != null) {
            why.* = "a tab sets both .jql and .mode";
            return error.TabJqlAndMode;
        }
        if (t.jql.len == 0 and t.mode == null) {
            why.* = "a tab needs .kind, .jql or .mode";
            return error.TabNeedsJqlOrMode;
        }
        if (t.mode != null and t.project.len == 0) {
            why.* = "a .mode tab needs .project = \"<KEY>\"";
            return error.TabNeedsProject;
        }
    }
}

/// The tabs `--only <family>` keeps; a legacy tab (no kind) is dropped
/// by any `--only`, as in the reference.
pub fn tabsOfFamily(arena: Allocator, tabs: []const Tab, family: ?Family) Allocator.Error![]const Tab {
    const f = family orelse return tabs;
    var out: std.ArrayList(Tab) = .empty;
    for (tabs) |t| if (t.kind) |k| if (k.family() == f) try out.append(arena, t);
    return out.toOwnedSlice(arena);
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
    config: Config,
    path: []const u8,
    missing: bool,
    parse_error: ?[]const u8 = null,
    /// A `$JIRA_BASE_URL` / `$BITBUCKET_BASE_URL` of `@<path>` whose
    /// file never arrived — the sentence to show. Set: no client is
    /// built and no request goes out.
    base_url_error: ?[]const u8 = null,
};

pub const LoadOpts = struct {
    explicit: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    data_root: ?[]const u8 = null,
};

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

/// `$JIRA_BASE_URL` overrides the config's `.jira_url` — literally, or
/// as `@<path>` naming a file that holds it. The fake server writes the
/// port it was actually given to `--url-file`, so a test script names
/// the server without ever picking a number and two runs of the corpus
/// never collide. Bitbucket's `$BITBUCKET_BASE_URL` is the same shape
/// (`sdk.base_url` reads both).
///
/// The file is written once the socket is listening, and a script may
/// start the server and the pane in either order, so a missing or
/// empty file is waited out rather than failed on — for a while. One
/// that never arrives is `.unreadable`: the fake did not start, and the
/// config's URL (a real site, as often as not) is NOT the fallback.
pub fn envBaseUrl(arena: Allocator, io: Io, env: *const std.process.Environ.Map, name: []const u8) Allocator.Error!sdk.base_url.Override {
    return sdk.base_url.fromEnv(arena, io, env, name, .{ .wait_ms = url_file_wait_ms });
}

/// `load`, then `$JIRA_BASE_URL` and `$BITBUCKET_BASE_URL` over the
/// top. Every entry point that reaches the network goes through this
/// rather than `load`, so the pane, `--values`, `--check` and
/// `--prefetch` all answer about the same server — and every one of
/// them refuses when `base_url_error` is set.
pub fn loadWithEnv(arena: Allocator, io: Io, env: *const std.process.Environ.Map, path: []const u8) Allocator.Error!Loaded {
    var loaded = try load(arena, io, path);
    if (loaded.missing or loaded.parse_error != null) return loaded;
    switch (try envBaseUrl(arena, io, env, base_url_env)) {
        .url => |u| loaded.config.jira_url = std.mem.trimEnd(u8, u, "/"),
        .unreadable => |why| {
            loaded.base_url_error = why;
            return loaded;
        },
        .unset => {},
    }
    switch (try envBaseUrl(arena, io, env, forge_base_url_env)) {
        .url => |u| loaded.config.bitbucket_api_url = std.mem.trimEnd(u8, u, "/"),
        .unreadable => |why| loaded.base_url_error = why,
        .unset => {},
    }
    return loaded;
}

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

pub fn normalise(arena: Allocator, in: Config) Allocator.Error!Config {
    var c = in;
    c.jira_url = std.mem.trimEnd(u8, std.mem.trim(u8, c.jira_url, " \t\r\n"), "/");
    c.bitbucket_api_url = std.mem.trimEnd(u8, std.mem.trim(u8, c.bitbucket_api_url, " \t\r\n"), "/");
    c.email = std.mem.trim(u8, c.email, " \t\r\n");
    if (c.projects.len > 0) {
        var keep: std.ArrayList([]const u8) = .empty;
        for (c.projects) |k| if (validProjectKey(k)) try keep.append(arena, k);
        c.projects = try keep.toOwnedSlice(arena);
    }
    return c;
}

/// What `--write-config` puts on disk: the reference's example, in ZON.
pub const example =
    \\// mnml-jira — the config, the reference tracker's TOML keys in ZON.
    \\// See integrations/jira/README.md for the key-by-key table.
    \\.{
    \\    .jira_url = "https://yourorg.atlassian.net",
    \\    .email = "you@example.com",
    \\    // The token is never written here: $JIRA_API_TOKEN, or .token_file.
    \\    // .token_file = "~/.config/mnml-tracker-jira/token",
    \\    .refresh_interval_secs = 60,
    \\    // How often each kind of thing is kept fresh. A listing
    \\    // drifts; a pipeline mid-run does not wait; whether a pull
    \\    // request may merge is only asked about the row under the
    \\    // cursor, so `readiness_secs = 0` means on demand only.
    \\    .intervals = .{ .listing_secs = 300, .builds_secs = 90, .readiness_secs = 0 },
    \\    .release_cut = false,
    \\    // .team_field_id = "customfield_10056",
    \\    // .team_field_name = "Team",
    \\    // .dispatch_workspace = "/path/to/agent/workspace",
    \\    .tabs = .{
    \\        .{ .name = "My open work items", .kind = .work_open },
    \\        .{ .name = "Reported by me", .kind = .work_reported },
    \\        .{
    \\            // The JQL is yours; `{name}` holes come from .vars, and
    \\            // the pane's `E` edits the vars (not the JQL) and writes
    \\            // them back here, comments and all.
    \\            .name = "QA Actionable now",
    \\            .kind = .jql_editable,
    \\            .jql = "project = {project} AND (status = \"Testing\" OR (status = \"Done\" AND fixVersion in ({versions}))) ORDER BY status ASC, updated DESC",
    \\            .vars = .{
    \\                .{ .name = "project", .value = "ENG" },
    \\                .{ .name = "versions", .values = .{ "1.2.0", "Mobile 1.0.X" } },
    \\            },
    \\        },
    \\        .{ .name = "Recently Done", .kind = .work_recently_done },
    \\        .{
    \\            .name = "Current Release",
    \\            .kind = .fix_version_tree,
    \\            .project = "TE",
    \\            .mode = .current_release,
    \\            .status_order = .{ "Testing", "In PR Review", "In Progress", "To Do", "Done" },
    \\            .bumps = .{
    \\                .pr_approved = "Testing",
    \\                .no_open_prs = "Testing",
    \\                .release_cut = .{ .{ .status = "Done", .target = "top" } },
    \\            },
    \\        },
    \\        .{ .name = "Sprint", .kind = .board_active_sprint, .project = "TE", .board_id = 200 },
    \\        .{ .name = "Backlog", .kind = .board_backlog, .project = "TE" },
    \\    },
    \\}
    \\
;

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "the example parses, validates, and reads as the reference's config" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const src = try a.allocator().dupeZ(u8, example);
    const loaded = try parse(a.allocator(), src, "example");
    try testing.expect(loaded.parse_error == null);
    const c = loaded.config;
    try testing.expectEqualStrings("https://yourorg.atlassian.net", c.jira_url);
    try testing.expectEqual(@as(u32, 60), c.refresh_interval_secs);
    try testing.expectEqual(@as(usize, 7), c.tabs.len);
    try testing.expectEqual(TabKind.work_open, c.tabs[0].kind.?);
    try testing.expectEqual(TabKind.work_reported, c.tabs[1].kind.?);
    try testing.expectEqual(TabKind.jql_editable, c.tabs[2].kind.?);
    try testing.expectEqual(@as(usize, 2), c.tabs[2].vars.len);
    try testing.expectEqualStrings("ENG", c.tabs[2].vars[0].value);
    try testing.expectEqual(@as(usize, 2), c.tabs[2].vars[1].values.len);
    try testing.expectEqualStrings("Mobile 1.0.X", c.tabs[2].vars[1].values[1]);
    // The scaffold's holes are filled, not left in the JQL.
    const filled = (try c.tabs[2].staticJql(a.allocator())).?;
    try testing.expect(std.mem.indexOf(u8, filled, "{") == null);
    try testing.expect(std.mem.indexOf(u8, filled, "project = ENG") != null);
    try testing.expect(std.mem.indexOf(u8, filled, "fixVersion in (\"1.2.0\", \"Mobile 1.0.X\")") != null);
    try testing.expectEqual(TabKind.fix_version_tree, c.tabs[4].kind.?);
    try testing.expectEqual(ResolveMode.current_release, c.tabs[4].mode.?);
    try testing.expectEqualStrings("Testing", c.tabs[4].bumps.?.pr_approved);
    try testing.expectEqualStrings("Done", c.tabs[4].bumps.?.release_cut[0].status);
    try testing.expectEqualStrings("top", c.tabs[4].bumps.?.release_cut[0].target);
    try testing.expectEqual(@as(u64, 200), c.tabs[5].board_id);
    try testing.expectEqual(@as(usize, 5), c.tabs[4].status_order.?.len);
    try testing.expectEqual(@as(usize, 7), c.tabs[0].statusOrder().len);
    var why: []const u8 = "";
    try validate(c, &why);
}

test "the families split the tabs the way --only does, and a legacy tab is dropped by any --only" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const tabs = [_]Tab{
        .{ .name = "A", .kind = .work_assigned },
        .{ .name = "R", .kind = .work_recently_done },
        .{ .name = "C", .kind = .fix_version_tree, .project = "TE" },
        .{ .name = "S", .kind = .board_active_sprint, .project = "TE" },
        .{ .name = "B", .kind = .board_backlog, .project = "TE" },
        .{ .name = "L", .jql = "project = X" },
    };
    try testing.expectEqual(@as(usize, 2), (try tabsOfFamily(a.allocator(), &tabs, .work)).len);
    _ = &tabs;
    try testing.expectEqual(@as(usize, 1), (try tabsOfFamily(a.allocator(), &tabs, .fix_versions)).len);
    try testing.expectEqual(@as(usize, 2), (try tabsOfFamily(a.allocator(), &tabs, .boards)).len);
    try testing.expectEqual(@as(usize, 6), (try tabsOfFamily(a.allocator(), &tabs, null)).len);
    try testing.expectEqual(Family.work, Family.fromCli("work").?);
    try testing.expectEqual(Family.fix_versions, Family.fromCli("fix-versions").?);
    try testing.expectEqual(Family.boards, Family.fromCli("jira_boards").?);
    try testing.expect(Family.fromCli("bogus") == null);
    try testing.expectEqualStrings("JIRA FIX VERSIONS", Family.fix_versions.title());
    try testing.expect(tabs[3].isKanban() and !tabs[3].isTree() and tabs[0].isTree() and !tabs[5].isTree());
}

test "the two new work kinds: Reported by me is the reporter query, My open work items the assigned one" {
    const reported = TabKind.work_reported.defaultJql().?;
    // Jira's own filter, windowed: newest FILED first, every
    // resolution, two weeks back.
    try testing.expectEqualStrings("reporter = currentUser() AND created >= -14d ORDER BY created DESC", reported);
    try testing.expect(std.mem.indexOf(u8, reported, "resolution") == null);
    try testing.expectEqualStrings(TabKind.work_assigned.defaultJql().?, TabKind.work_open.defaultJql().?);
    try testing.expect(TabKind.work_open.isAssignedOpen() and TabKind.work_assigned.isAssignedOpen());
    try testing.expect(!TabKind.work_reported.isAssignedOpen() and !TabKind.jql_editable.isAssignedOpen());
    try testing.expectEqual(Family.work, TabKind.work_reported.family());
    try testing.expectEqual(Family.work, TabKind.work_open.family());
    try testing.expectEqual(Family.work, TabKind.jql_editable.family());
    try testing.expect(TabKind.jql_editable.defaultJql() == null);
}

test "the Reported-by-me window: the query per step, the widen sequence 14 -> 30 -> 90 -> none, and how each step reads" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expectEqualStrings("reporter = currentUser() AND created >= -14d ORDER BY created DESC", try reportedJql(arena, 14));
    try testing.expectEqualStrings("reporter = currentUser() AND created >= -30d ORDER BY created DESC", try reportedJql(arena, 30));
    try testing.expectEqualStrings("reporter = currentUser() AND created >= -90d ORDER BY created DESC", try reportedJql(arena, 90));
    // 0 is no window at all: the reference's filter, to the byte.
    try testing.expectEqualStrings("reporter = currentUser() ORDER BY created DESC", try reportedJql(arena, 0));
    try testing.expectEqualStrings(reported_default_jql, try reportedJql(arena, reported_window_default));

    // The widen sequence, and the end of it.
    try testing.expectEqual(@as(?u16, 30), nextReportedWindow(14));
    try testing.expectEqual(@as(?u16, 90), nextReportedWindow(30));
    try testing.expectEqual(@as(?u16, 0), nextReportedWindow(90));
    try testing.expect(nextReportedWindow(0) == null);
    // A hand-set window off the table lands on the first step past it.
    try testing.expectEqual(@as(?u16, 90), nextReportedWindow(45));
    try testing.expectEqual(@as(?u16, 0), nextReportedWindow(200));

    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("2 weeks", windowLabel(&buf, 14));
    try testing.expectEqualStrings("30 days", windowLabel(&buf, 30));
    try testing.expectEqualStrings("90 days", windowLabel(&buf, 90));
    try testing.expectEqualStrings("all time", windowLabel(&buf, 0));

    // The knob moves where the tab OPENS, and only on this kind.
    const windowed: Tab = .{ .name = "R", .kind = .work_reported, .reported_window_days = 30 };
    try testing.expectEqualStrings("reporter = currentUser() AND created >= -30d ORDER BY created DESC", (try windowed.staticJql(arena)).?);
    const unwindowed: Tab = .{ .name = "R", .kind = .work_reported, .reported_window_days = 0 };
    try testing.expectEqualStrings("reporter = currentUser() ORDER BY created DESC", (try unwindowed.staticJql(arena)).?);
    const other: Tab = .{ .name = "O", .kind = .work_open, .reported_window_days = 30 };
    try testing.expectEqualStrings(TabKind.work_open.defaultJql().?, (try other.staticJql(arena)).?);
}

test "expandVars fills {name} holes, quotes a list, and leaves an unknown name alone" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const vars = [_]Var{
        .{ .name = "project", .value = "ENG" },
        .{ .name = "versions", .values = &.{ "1.2.0", "Mobile 1.0.X" } },
    };
    try testing.expectEqualStrings(
        "project = ENG AND fixVersion in (\"1.2.0\", \"Mobile 1.0.X\")",
        try expandVars(arena, "project = {project} AND fixVersion in ({versions})", &vars),
    );
    // An unknown hole survives verbatim: a typo is visible in the JQL
    // rather than quietly becoming an empty clause.
    try testing.expectEqualStrings("a = {nope}", try expandVars(arena, "a = {nope}", &vars));
    // A quote inside a value is escaped, not closed.
    const q = [_]Var{.{ .name = "v", .values = &.{"say \"hi\""} }};
    try testing.expectEqualStrings("x in (\"say \\\"hi\\\"\")", try expandVars(arena, "x in ({v})", &q));
    // No vars, or no holes: the same bytes back.
    try testing.expectEqualStrings("a = 1", try expandVars(arena, "a = 1", &vars));
    try testing.expectEqualStrings("a = {b}", try expandVars(arena, "a = {b}", &.{}));
    // An unclosed brace is not a hole.
    try testing.expectEqualStrings("a = {project", try expandVars(arena, "a = {project", &vars));
    try testing.expect(Var.isList(.{ .name = "v", .values = &.{"x"} }));
    try testing.expect(!Var.isList(.{ .name = "v", .value = "x" }));
}

test "the default JQLs are the reference's, and the release kind has none" {
    const mine = TabKind.work_assigned.defaultJql().?;
    try testing.expect(std.mem.indexOf(u8, mine, "resolution = Unresolved") != null);
    try testing.expect(std.mem.indexOf(u8, mine, "Done in Production") != null);
    try testing.expect(std.mem.indexOf(u8, TabKind.board_backlog.defaultJql().?, "sprint is EMPTY") != null);
    try testing.expect(TabKind.fix_version_tree.defaultJql() == null);
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    try testing.expectEqualStrings("filter = 12 ORDER BY updated DESC", (try (Tab{ .name = "F", .kind = .filter, .filter_id = 12 }).staticJql(a.allocator())).?);
    try testing.expectEqualStrings("project = X", (try (Tab{ .name = "M", .kind = .work_assigned, .jql = "project = X" }).staticJql(a.allocator())).?);
    try testing.expect((try (Tab{ .name = "R", .kind = .fix_version_tree, .project = "X" }).staticJql(a.allocator())) == null);
}

test "validate: the reference's rules" {
    var why: []const u8 = "";
    try testing.expectError(error.NoUrl, validate(.{}, &why));
    const site: Config = .{ .jira_url = "https://x", .email = "me@x" };
    try testing.expectError(error.NoTabs, validate(site, &why));
    var c = site;
    c.tabs = &.{.{ .name = "R", .kind = .fix_version_tree }};
    try testing.expectError(error.TabNeedsProject, validate(c, &why));
    c.tabs = &.{.{ .name = "F", .kind = .filter }};
    try testing.expectError(error.FilterWithoutId, validate(c, &why));
    c.tabs = &.{.{ .name = "Q", .kind = .jql_editable }};
    try testing.expectError(error.EditableWithoutJql, validate(c, &why));
    c.tabs = &.{.{ .name = "Q", .kind = .jql_editable, .jql = "project = {p}", .vars = &.{.{ .name = "p", .value = "TE" }} }};
    try validate(c, &why);
    c.tabs = &.{.{ .name = "B", .kind = .work_assigned, .jql = "x", .mode = .next_release }};
    try testing.expectError(error.TabJqlAndMode, validate(c, &why));
    c.tabs = &.{.{ .name = "L" }};
    try testing.expectError(error.TabNeedsJqlOrMode, validate(c, &why));
    c.tabs = &.{.{ .name = "L", .mode = .current_release }};
    try testing.expectError(error.TabNeedsProject, validate(c, &why));
    c.tabs = &.{ .{ .name = "T", .jql = "status = Testing" }, .{ .name = "C", .mode = .current_release, .project = "TE" } };
    try validate(c, &why);
}

test "the detail modal resolves aliases both ways and titles the built-ins" {
    const m: DetailModal = .{ .field_alias = &.{.{ .name = "problem", .id = "customfield_10101" }} };
    try testing.expectEqualStrings("customfield_10101", m.resolveId(.{ .id = "problem" }));
    try testing.expectEqualStrings("assignee", m.resolveId(.{ .id = "assignee" }));
    try testing.expectEqualStrings("problem", m.resolveLabel(.{ .id = "customfield_10101" }));
    try testing.expectEqualStrings("Fix version", m.resolveLabel(.{ .id = "fix_version" }));
    try testing.expectEqualStrings("What", m.resolveLabel(.{ .id = "customfield_2", .label = "What" }));
    try testing.expectEqual(@as(usize, 10), default_detail_fields.len);
}

test "a broken config is a parse error, a missing one is missing, normalise tidies" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const src = try a.allocator().dupeZ(u8, ".{ .jira_url = ");
    const bad = try parse(a.allocator(), src, "bad.zon");
    try testing.expect(bad.parse_error != null);
    const gone = try load(a.allocator(), testing.io, "/nowhere/at/all/config.zon");
    try testing.expect(gone.missing);
    const c = try normalise(a.allocator(), .{ .jira_url = " https://x/ ", .projects = &.{ "TE", "te", "TOOLONGPROJECTKEY" } });
    try testing.expectEqualStrings("https://x", c.jira_url);
    try testing.expectEqual(@as(usize, 1), c.projects.len);
}

test "resolvePath prefers the workspace file, then the data root, and names the data root when neither exists" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    const ws = try std.fs.path.join(arena, &.{ root, "ws" });
    const data = try std.fs.path.join(arena, &.{ root, "data" });
    const none = try resolvePath(arena, testing.io, .{ .workspace = ws, .data_root = data }, null);
    try testing.expect(std.mem.endsWith(u8, none, "data/integrations/jira/config.zon"));
    try tmp.dir.createDirPath(testing.io, "data/integrations/jira");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data/integrations/jira/config.zon", .data = ".{}" });
    try testing.expect(std.mem.endsWith(u8, try resolvePath(arena, testing.io, .{ .workspace = ws, .data_root = data }, null), "data/integrations/jira/config.zon"));
    try tmp.dir.createDirPath(testing.io, "ws/.mnml/integrations/jira");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/.mnml/integrations/jira/config.zon", .data = ".{}" });
    try testing.expect(std.mem.endsWith(u8, try resolvePath(arena, testing.io, .{ .workspace = ws, .data_root = data }, null), "ws/.mnml/integrations/jira/config.zon"));
    try testing.expectEqualStrings("/from/env.zon", try resolvePath(arena, testing.io, .{ .workspace = ws }, "/from/env.zon"));
    try testing.expectEqualStrings("/flag.zon", try resolvePath(arena, testing.io, .{ .explicit = "/flag.zon" }, "/from/env.zon"));
}

test "$JIRA_BASE_URL wins over .jira_url, literally or as @<file>" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    const cfg_path = try std.fs.path.join(arena, &.{ root, "config.zon" });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config.zon",
        .data = ".{ .jira_url = \"https://acme.atlassian.net\", .email = \"me@acme.com\", .tabs = .{ .{ .name = \"Assigned\", .kind = .work_assigned } } }",
    });

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    // Nothing set: the config stands.
    try testing.expectEqualStrings("https://acme.atlassian.net", (try loadWithEnv(arena, testing.io, &env, cfg_path)).config.jira_url);

    // A literal, with the trailing slash trimmed the way `.jira_url` is.
    try env.put(base_url_env, "http://127.0.0.1:1234/");
    try testing.expectEqualStrings("http://127.0.0.1:1234", (try loadWithEnv(arena, testing.io, &env, cfg_path)).config.jira_url);

    // `@<path>`: the file the fake server writes its port into.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "jira.url", .data = "http://127.0.0.1:54321" });
    const at = try std.fmt.allocPrint(arena, "@{s}/jira.url", .{root});
    try env.put(base_url_env, at);
    try testing.expectEqualStrings("http://127.0.0.1:54321", (try loadWithEnv(arena, testing.io, &env, cfg_path)).config.jira_url);
    try testing.expect((try loadWithEnv(arena, testing.io, &env, cfg_path)).base_url_error == null);

    // `$BITBUCKET_BASE_URL` points the linked pull requests at the
    // forge's fake the same way.
    try env.put(forge_base_url_env, "http://127.0.0.1:777/");
    try testing.expectEqualStrings("http://127.0.0.1:777", (try loadWithEnv(arena, testing.io, &env, cfg_path)).config.bitbucket_api_url);
}

test "an @<path> override whose file never arrives is an error — never the config's site" {
    // hunt/findings-2026-09-23/integ-bb-base-url-falls-back-to-production.md:
    // the fake did not start; the answer is no server, not the real one.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    const cfg_path = try std.fs.path.join(arena, &.{ root, "config.zon" });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config.zon",
        .data = ".{ .jira_url = \"https://acme.atlassian.net\", .email = \"me@acme.com\", .tabs = .{ .{ .name = \"Assigned\", .kind = .work_assigned } } }",
    });
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    for ([_][]const u8{ base_url_env, forge_base_url_env }) |name| {
        _ = env.swapRemove(base_url_env);
        _ = env.swapRemove(forge_base_url_env);
        try env.put(name, try std.fmt.allocPrint(arena, "@{s}/never.url", .{root}));
        const l = try loadWithEnv(arena, testing.io, &env, cfg_path);
        const why = l.base_url_error orelse return error.TestExpectedError;
        try testing.expect(std.mem.indexOf(u8, why, name) != null);
        try testing.expect(std.mem.indexOf(u8, why, "never.url") != null);
    }
}
