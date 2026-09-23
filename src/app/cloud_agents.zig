//! The cloud scanner and the cloud actions — the third source behind
//! `sessions.Item` (`where = .cloud`). A run is a row of the ECS
//! runner's DynamoDB table (`[cloud_agents] runs_table`), read with the
//! `aws` CLI on the sessions cadence, only when the API is configured
//! (`configured`: a table and a region). Its actions are `Open run`
//! (the task described in a pty), `Tail log` (`aws logs tail` on the
//! run's stream prefix) and `Cancel run…` (`aws ecs stop-task` after a
//! confirm); the two wizards — a run by ticket, a run through the
//! prompt chain — are choices under the SESSIONS `+ New session` row.
//!
//! // changed (sessions-merge): replaces the CLOUD AGENTS rail section
//! and its "not in this build" runners. Nothing here is reachable
//! without the config, and every AWS call is a subprocess a pty pane
//! shows — no client library, no hidden requests.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const Config = @import("../config/Config.zig");
const sessions = @import("../sessions.zig");
const pty_pane = @import("pty_pane.zig");
const agents = @import("agents.zig");

pub const Item = sessions.Item;

pub const table = .{
    .@"cloud_agents.refresh" = &refreshCmd,
    .@"cloud_agents.new_run" = &newRunCmd,
    .@"cloud_agents.new_run_wizard" = &newRunWizardCmd,
    .@"sessions.cloud_open" = &openRunCmd,
    .@"sessions.cloud_tail" = &tailLogCmd,
    .@"sessions.cloud_cancel" = &cancelRunCmd,
};

/// What the scanner and the actions need, duped off the config so a
/// worker in flight never reads a slice the config could free.
pub const Opts = struct {
    region: []u8,
    profile: ?[]u8,
    runs_table: []u8,
    cluster: []u8,
    log_group: []u8,
    task_definition: []u8,
    /// The group label of every cloud row (`default_workspace_label`,
    /// `cloud` when empty).
    label: []u8,

    /// Null when the API is not configured.
    pub fn fromConfig(gpa: Allocator, cfg: *const Config.CloudAgents, env: *const std.process.Environ.Map) Allocator.Error!?Opts {
        if (!configured(cfg, env)) return null;
        const region = try gpa.dupe(u8, regionOf(cfg, env));
        errdefer gpa.free(region);
        const profile_src = env.get("MNML_AWS_PROFILE") orelse cfg.aws_profile_fallback;
        const profile: ?[]u8 = if (profile_src.len > 0) try gpa.dupe(u8, profile_src) else null;
        errdefer if (profile) |p| gpa.free(p);
        const runs_table = try gpa.dupe(u8, cfg.runs_table);
        errdefer gpa.free(runs_table);
        const cluster = try gpa.dupe(u8, cfg.cluster);
        errdefer gpa.free(cluster);
        const log_group = try gpa.dupe(u8, cfg.log_group);
        errdefer gpa.free(log_group);
        const task_definition = try gpa.dupe(u8, cfg.task_definition);
        errdefer gpa.free(task_definition);
        const label = try gpa.dupe(u8, labelOf(cfg));
        errdefer gpa.free(label);
        return .{ .region = region, .profile = profile, .runs_table = runs_table, .cluster = cluster, .log_group = log_group, .task_definition = task_definition, .label = label };
    }

    pub fn deinit(self: *Opts, gpa: Allocator) void {
        gpa.free(self.region);
        if (self.profile) |p| gpa.free(p);
        gpa.free(self.runs_table);
        gpa.free(self.cluster);
        gpa.free(self.log_group);
        gpa.free(self.task_definition);
        gpa.free(self.label);
    }
};

/// `MNML_CLOUD_AGENTS_REGION` overrides the config's region.
pub fn regionOf(cfg: *const Config.CloudAgents, env: *const std.process.Environ.Map) []const u8 {
    if (env.get("MNML_CLOUD_AGENTS_REGION")) |r| if (r.len > 0) return r;
    return cfg.region;
}

pub fn labelOf(cfg: *const Config.CloudAgents) []const u8 {
    return if (cfg.default_workspace_label.len > 0) cfg.default_workspace_label else "cloud";
}

/// A runs table and a region: enough to list; the actions check for
/// the rest themselves.
pub fn configured(cfg: *const Config.CloudAgents, env: *const std.process.Environ.Map) bool {
    return cfg.runs_table.len > 0 and regionOf(cfg, env).len > 0;
}

// ─── the scan ───────────────────────────────────────────────────────────

/// `aws dynamodb scan` on the runs table; the rows on `arena`.
pub fn scanArgv(arena: Allocator, o: Opts) Allocator.Error![]const []const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "aws", "dynamodb", "scan", "--table-name", o.runs_table, "--region", o.region, "--output", "json" });
    if (o.profile) |p| try argv.appendSlice(arena, &.{ "--profile", p });
    return argv.items;
}

pub fn scanInto(io: Io, gpa: Allocator, arena: Allocator, o: Opts, rows: *std.ArrayListUnmanaged(Item)) agents.ScanError!void {
    const argv = try scanArgv(arena, o);
    const result = std.process.run(gpa, io, .{ .argv = argv, .stdout_limit = .limited(16 * 1024 * 1024) }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return;
    const now = Io.Timestamp.now(io, .real).toSeconds();
    try parseRuns(arena, result.stdout, o.label, now, rows);
}

/// The runner's word for a run → the row's state.
pub fn mapState(raw: []const u8) agents.AgentState {
    if (std.mem.eql(u8, raw, "started") or std.mem.eql(u8, raw, "approved")) return .streaming;
    if (std.mem.eql(u8, raw, "staged")) return .waiting;
    if (std.mem.eql(u8, raw, "failed")) return .failed;
    return .done;
}

/// The DynamoDB `Items` (type-wrapped, `{"runId":{"S":"…"}}`) as rows:
/// the run id is the session id, the ticket the prompt shown as the
/// name, the flow the assistant's line, `createdAt` / `finishedAt` the
/// activity. A record without a run id is skipped.
pub fn parseRuns(arena: Allocator, text: []const u8, label: []const u8, now: i64, rows: *std.ArrayListUnmanaged(Item)) Allocator.Error!void {
    var scratch = std.heap.ArenaAllocator.init(arena);
    defer scratch.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), text, .{}) catch return;
    if (v != .object) return;
    const items = v.object.get("Items") orelse return;
    if (items != .array) return;
    for (items.array.items) |item| {
        const run_id = attr(item, "runId") orelse continue;
        const ticket = attr(item, "ticket") orelse "";
        const flow = attr(item, "flow") orelse "";
        const raw_state = attr(item, "state") orelse "started";
        const created = attr(item, "createdAt") orelse "";
        const finished = attr(item, "finishedAt");
        const at = (if (finished) |f| isoToUnix(f) else null) orelse isoToUnix(created) orelse now;
        const state = mapState(raw_state);
        const assistant = try std.fmt.allocPrint(arena, "{s} — {s}", .{ raw_state, if (flow.len > 0) flow else "run" });
        try rows.append(arena, .{
            .source = .claude,
            .where = .cloud,
            .session_id = try arena.dupe(u8, run_id),
            .workspace = try arena.dupe(u8, label),
            .cwd = null,
            .transcript_path = "",
            .state = state,
            .pid = null,
            .last_activity_s = at,
            .last_user_msg = if (ticket.len > 0) try arena.dupe(u8, ticket) else null,
            .last_assistant_msg = assistant,
            .pending_tool_uses = if (state == .waiting) 1 else 0,
            .cloud = .{
                .ticket = try arena.dupe(u8, ticket),
                .flow = try arena.dupe(u8, flow),
                .raw_state = try arena.dupe(u8, raw_state),
                .task_arn = if (attr(item, "taskArn")) |a| try arena.dupe(u8, a) else null,
                .pr_url = if (attr(item, "prUrl")) |u| try arena.dupe(u8, u) else null,
            },
        });
    }
}

fn attr(item: std.json.Value, key: []const u8) ?[]const u8 {
    if (item != .object) return null;
    const wrapped = item.object.get(key) orelse return null;
    if (wrapped != .object) return null;
    const s = wrapped.object.get("S") orelse return null;
    return if (s == .string) s.string else null;
}

/// `YYYY-MM-DDTHH:MM:SS` with an optional fraction and `Z` → Unix
/// seconds; null for anything else.
pub fn isoToUnix(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    if (s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != ' ') or s[13] != ':' or s[16] != ':') return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    // Days from civil (Howard Hinnant's algorithm).
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + hour * 3600 + minute * 60 + second;
}

// ─── the actions ────────────────────────────────────────────────────────

fn optsOrFail(app: *App) CommandError!Opts {
    return (try Opts.fromConfig(app.frame.allocator(), &app.cfg.cloud_agents, &app.env)) orelse
        app.diag.fail(app.frame.allocator(), "cloud runs need [cloud_agents] runs_table and region (or MNML_CLOUD_AGENTS_REGION) in the config", .{});
}

fn cloudRow(app: *App) CommandError!Item {
    const it = sessions.current(app) orelse return app.diag.fail(app.frame.allocator(), "sessions: nothing selected", .{});
    if (it.where != .cloud) return app.diag.fail(app.frame.allocator(), "sessions: {s} is a local session", .{sessions.displayName(app, it)});
    return it;
}

fn refreshCmd(app: *App) CommandError!void {
    return sessions.refresh(app);
}

fn openRunCmd(app: *App) CommandError!void {
    return openRun(app, try cloudRow(app));
}

fn tailLogCmd(app: *App) CommandError!void {
    return tailLog(app, try cloudRow(app));
}

fn cancelRunCmd(app: *App) CommandError!void {
    return cancelRun(app, try cloudRow(app));
}

/// Rust's `EcsRunMeta::cloudwatch_url`: a Logs Insights query for the
/// run id over the last day, in the console. Null without an account,
/// a region and a log group — the row is not offered then.
pub fn cloudwatchUrl(arena: Allocator, region: []const u8, account: []const u8, log_group: []const u8, run_id: []const u8) Allocator.Error!?[]const u8 {
    if (region.len == 0 or account.len == 0 or log_group.len == 0) return null;
    const group = try std.mem.replaceOwned(u8, arena, log_group, "/", "$252F");
    const query = try std.fmt.allocPrint(arena, "fields @timestamp, @message | filter @message like /{s}/ | sort @timestamp desc", .{run_id});
    // The console's own escaping of the query (Rust `urlencoding_minimal`).
    var enc: std.ArrayListUnmanaged(u8) = .empty;
    for (query) |c| {
        const rep: ?[]const u8 = switch (c) {
            ' ' => "*20",
            '|' => "*7c",
            '/' => "*2f",
            '.' => "*2e",
            ',' => "*2c",
            '\'' => "*27",
            '(' => "*28",
            ')' => "*29",
            '@' => "*40",
            else => null,
        };
        if (rep) |r| try enc.appendSlice(arena, r) else try enc.append(arena, c);
    }
    return try std.fmt.allocPrint(arena, "https://{s}.console.aws.amazon.com/cloudwatch/home?region={s}#logsV2:logs-insights$3FqueryDetail$3D~(end~0~start~-86400~timeType~'RELATIVE~unit~'seconds~editorString~'{s}~source~(~'{s}))?account={s}", .{ region, region, enc.items, group, account });
}

/// `aws logs tail` on the run's stream prefix; `--follow` keeps it up.
pub fn tailArgv(arena: Allocator, o: Opts, run_id: []const u8, follow: bool) Allocator.Error![]const []const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "aws", "logs", "tail", o.log_group, "--log-stream-name-prefix", run_id, "--since", "1d", "--region", o.region });
    if (follow) try argv.append(arena, "--follow");
    if (o.profile) |p| try argv.appendSlice(arena, &.{ "--profile", p });
    return argv.items;
}

/// `aws ecs describe-tasks` for the run's task, else the run's record.
pub fn describeArgv(arena: Allocator, o: Opts, it: Item) Allocator.Error![]const []const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    const arn: ?[]const u8 = if (it.cloud) |c| c.task_arn else null;
    if (arn) |a| {
        try argv.appendSlice(arena, &.{ "aws", "ecs", "describe-tasks", "--cluster", o.cluster, "--tasks", a, "--region", o.region, "--output", "yaml" });
    } else {
        const key = try std.fmt.allocPrint(arena, "{{\"runId\":{{\"S\":\"{s}\"}}}}", .{it.session_id});
        try argv.appendSlice(arena, &.{ "aws", "dynamodb", "get-item", "--table-name", o.runs_table, "--key", key, "--region", o.region, "--output", "yaml" });
    }
    if (o.profile) |p| try argv.appendSlice(arena, &.{ "--profile", p });
    return argv.items;
}

pub fn stopArgv(arena: Allocator, o: Opts, task_arn: []const u8) Allocator.Error![]const []const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "aws", "ecs", "stop-task", "--cluster", o.cluster, "--task", task_arn, "--reason", "cancelled from mnml", "--region", o.region });
    if (o.profile) |p| try argv.appendSlice(arena, &.{ "--profile", p });
    return argv.items;
}

/// `aws ecs run-task` with the ticket (and a model) as the container's
/// environment — what the runner's task definition reads.
pub fn runTaskArgv(arena: Allocator, o: Opts, ticket: []const u8, model: ?[]const u8) Allocator.Error![]const []const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    const env = if (model) |m|
        try std.fmt.allocPrint(arena, "{{\"containerOverrides\":[{{\"name\":\"runner\",\"environment\":[{{\"name\":\"TICKET\",\"value\":\"{s}\"}},{{\"name\":\"MODEL\",\"value\":\"{s}\"}}]}}]}}", .{ ticket, m })
    else
        try std.fmt.allocPrint(arena, "{{\"containerOverrides\":[{{\"name\":\"runner\",\"environment\":[{{\"name\":\"TICKET\",\"value\":\"{s}\"}}]}}]}}", .{ticket});
    try argv.appendSlice(arena, &.{ "aws", "ecs", "run-task", "--cluster", o.cluster, "--task-definition", o.task_definition, "--launch-type", "FARGATE", "--overrides", env, "--region", o.region });
    if (o.profile) |p| try argv.appendSlice(arena, &.{ "--profile", p });
    return argv.items;
}

/// `Open run`: the task (or the record) described in a pty to the right.
pub fn openRun(app: *App, it: Item) CommandError!void {
    const o = try optsOrFail(app);
    const arena = app.frame.allocator();
    if (it.cloud != null and it.cloud.?.task_arn != null and o.cluster.len == 0) return app.diag.fail(arena, "cloud runs need [cloud_agents] cluster to describe a task", .{});
    const argv = try describeArgv(arena, o, it);
    _ = try pty_pane.open(app, .{ .argv = argv, .label = try std.fmt.allocPrint(arena, "run {s}", .{it.session_id[0..@min(8, it.session_id.len)]}), .placement = .right, .kind = .command });
}

/// `Tail log`: the run's CloudWatch stream, following.
pub fn tailLog(app: *App, it: Item) CommandError!void {
    const o = try optsOrFail(app);
    const arena = app.frame.allocator();
    if (o.log_group.len == 0) return app.diag.fail(arena, "cloud runs need [cloud_agents] log_group to tail a log", .{});
    const argv = try tailArgv(arena, o, it.session_id, true);
    _ = try pty_pane.open(app, .{ .argv = argv, .label = try std.fmt.allocPrint(arena, "log {s}", .{it.session_id[0..@min(8, it.session_id.len)]}), .placement = .below, .kind = .command });
}

/// `Cancel run…`: a confirm, then `aws ecs stop-task`.
pub fn cancelRun(app: *App, it: Item) CommandError!void {
    const arena = app.frame.allocator();
    const o = try optsOrFail(app);
    if (o.cluster.len == 0) return app.diag.fail(arena, "cloud runs need [cloud_agents] cluster to cancel a task", .{});
    const arn = (if (it.cloud) |c| c.task_arn else null) orelse return app.diag.fail(arena, "sessions: run {s} has no task to stop (it may already be done)", .{it.session_id});
    const owned = try app.gpa.dupe(u8, arn);
    errdefer app.gpa.free(owned);
    const msg = try std.fmt.allocPrint(app.gpa, "Stop cloud run {s}?", .{sessions.displayName(app, it)});
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Cancel run", .message = msg, .choices = &cancel_choices },
        .purpose = .{ .cloud_cancel = owned },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub const cancel_choices = [_]app_mod.Confirm.Choice{ .{ .key = 's', .label = "Stop" }, .{ .key = 'c', .label = "Cancel" } };

/// The confirm's yes: the stop in a pty so its answer is visible.
pub fn cancelAccept(app: *App, task_arn: []const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    const o = (Opts.fromConfig(arena, &app.cfg.cloud_agents, &app.env) catch null) orelse return;
    const argv = stopArgv(arena, o, task_arn) catch return;
    _ = pty_pane.open(app, .{ .argv = argv, .label = "stop run", .placement = .below, .kind = .command }) catch |err| {
        app.toast("cloud: stop-task: {s}", .{@errorName(err)});
    };
}

// ─── the wizards ────────────────────────────────────────────────────────

/// `+ New cloud run…`: one prompt — the ticket — then the run fires.
fn newRunCmd(app: *App) CommandError!void {
    _ = try optsOrFail(app);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "New cloud run — Jira ticket (or a prompt)"), .purpose = .cloud_run_ticket } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// `+ New cloud run (wizard)…`: the ticket, then the model, then the run.
fn newRunWizardCmd(app: *App) CommandError!void {
    _ = try optsOrFail(app);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "New cloud run 1/2 — Jira ticket (or a prompt)"), .purpose = .cloud_run_wizard_ticket } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The first wizard step's accept: keep the ticket, ask for the model
/// (empty keeps the config's default).
pub fn acceptWizardTicket(app: *App, text: []const u8) Allocator.Error!void {
    const ticket = std.mem.trim(u8, text, " \t\r\n");
    if (ticket.len == 0) {
        app.toast("cloud run: a ticket is needed", .{});
        return;
    }
    const owned = try app.gpa.dupe(u8, ticket);
    errdefer app.gpa.free(owned);
    const seed = app.cfg.cloud_run.defaults.model;
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "New cloud run 2/2 — model (empty = the default)"), .purpose = .{ .cloud_run_model = owned } } };
    app.overlay.prompt.state.setText(app.gpa, seed) catch return error.OutOfMemory;
    app.focus = .overlay;
    app.needs_render = true;
}

/// The one-prompt wizard's accept, and the two-step wizard's last.
pub fn acceptRun(app: *App, ticket_in: []const u8, model_in: ?[]const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    const ticket = std.mem.trim(u8, ticket_in, " \t\r\n");
    if (ticket.len == 0) {
        app.toast("cloud run: a ticket is needed", .{});
        return;
    }
    const o = (try Opts.fromConfig(arena, &app.cfg.cloud_agents, &app.env)) orelse return;
    if (o.cluster.len == 0 or o.task_definition.len == 0) {
        app.toast("cloud runs need [cloud_agents] cluster and task_definition to start one", .{});
        return;
    }
    var model: ?[]const u8 = if (model_in) |m| std.mem.trim(u8, m, " \t\r\n") else null;
    if (model != null and model.?.len == 0) model = if (app.cfg.cloud_run.defaults.model.len > 0) app.cfg.cloud_run.defaults.model else null;
    const argv = try runTaskArgv(arena, o, ticket, model);
    _ = pty_pane.open(app, .{ .argv = argv, .label = try std.fmt.allocPrint(arena, "run {s}", .{ticket}), .placement = .below, .kind = .command }) catch |err| {
        app.toast("cloud: run-task: {s}", .{@errorName(err)});
        return;
    };
    // The pane is `aws ecs run-task` starting, not the run: whether a
    // task started is what its output says (an `aws` that exits 1 leaves
    // `[exited 1]` there). Claiming "started" here was a lie on failure.
    app.toast("cloud run for {s}: `aws ecs run-task` is running below — its output says whether the task started", .{ticket});
    sessions.refresh(app) catch {};
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "configured needs a runs table and a region; the env region and profile override" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var cfg = Config.CloudAgents{};
    try t.expect(!configured(&cfg, &env));
    cfg.runs_table = "runs";
    try t.expect(!configured(&cfg, &env));
    try env.put("MNML_CLOUD_AGENTS_REGION", "eu-west-1");
    try t.expect(configured(&cfg, &env));
    cfg.region = "us-east-1";
    try t.expectEqualStrings("eu-west-1", regionOf(&cfg, &env));
    try env.put("MNML_AWS_PROFILE", "work");
    var o = (try Opts.fromConfig(t.allocator, &cfg, &env)).?;
    defer o.deinit(t.allocator);
    try t.expectEqualStrings("work", o.profile.?);
    try t.expectEqualStrings("cloud", o.label);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const argv = try scanArgv(arena.allocator(), o);
    try t.expectEqualStrings("dynamodb", argv[1]);
    try t.expectEqualStrings("--profile", argv[argv.len - 2]);
    const tail = try tailArgv(arena.allocator(), o, "run-1", true);
    try t.expectEqualStrings("--follow", tail[tail.len - 3]);
}

test "parseRuns: the DynamoDB items become cloud rows — the ticket as the prompt, the runner's state mapped, staged is waiting" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\{"Items":[
        \\ {"runId":{"S":"run-aaa"},"ticket":{"S":"TE-1"},"flow":{"S":"fix"},"state":{"S":"staged"},"createdAt":{"S":"2026-09-01T10:00:00Z"},"taskArn":{"S":"arn:aws:ecs:x"}},
        \\ {"runId":{"S":"run-bbb"},"ticket":{"S":"TE-2"},"state":{"S":"shipped"},"createdAt":{"S":"2026-09-01T10:00:00Z"},"finishedAt":{"S":"2026-09-02T00:00:00.123Z"},"prUrl":{"S":"https://x/pr/1"}},
        \\ {"runId":{"S":"run-ccc"},"state":{"S":"failed"},"createdAt":{"S":"bogus"}},
        \\ {"ticket":{"S":"no id"}}
        \\]}
    ;
    var rows: std.ArrayListUnmanaged(Item) = .empty;
    try parseRuns(a, text, "cloud", 42, &rows);
    try t.expectEqual(@as(usize, 3), rows.items.len);
    const r0 = rows.items[0];
    try t.expectEqual(sessions.Where.cloud, r0.where);
    try t.expectEqual(agents.AgentState.waiting, r0.state);
    try t.expectEqualStrings("TE-1", r0.last_user_msg.?);
    try t.expectEqualStrings("staged — fix", r0.last_assistant_msg.?);
    try t.expectEqualStrings("arn:aws:ecs:x", r0.cloud.?.task_arn.?);
    try t.expectEqualStrings("cloud", r0.groupKey());
    try t.expectEqual(isoToUnix("2026-09-01T10:00:00Z").?, r0.last_activity_s);
    const r1 = rows.items[1];
    try t.expectEqual(agents.AgentState.done, r1.state);
    try t.expectEqual(isoToUnix("2026-09-02T00:00:00Z").?, r1.last_activity_s);
    try t.expectEqualStrings("https://x/pr/1", r1.cloud.?.pr_url.?);
    const r2 = rows.items[2];
    try t.expectEqual(agents.AgentState.failed, r2.state);
    try t.expectEqual(@as(i64, 42), r2.last_activity_s);
    try t.expect(r2.last_user_msg == null);
    // The duped copy keeps the cloud info.
    const d = try sessions.dupeItem(a, r0);
    try t.expectEqualStrings("TE-1", d.cloud.?.ticket);
}

test "isoToUnix: the epoch, a known instant, and the rejects" {
    try t.expectEqual(@as(i64, 0), isoToUnix("1970-01-01T00:00:00Z").?);
    try t.expectEqual(@as(i64, 1_700_000_000), isoToUnix("2023-11-14T22:13:20Z").?);
    try t.expectEqual(@as(i64, 1_700_000_000), isoToUnix("2023-11-14 22:13:20.5").?);
    try t.expect(isoToUnix("2023-13-01T00:00:00Z") == null);
    try t.expect(isoToUnix("yesterday") == null);
}

test "the argv builders: describe by task or by record, stop, run-task with the ticket and a model" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = Opts{ .region = @constCast("r"), .profile = null, .runs_table = @constCast("runs"), .cluster = @constCast("c"), .log_group = @constCast("g"), .task_definition = @constCast("td"), .label = @constCast("cloud") };
    var it = sessions.testItem("run-1", .streaming, 0, "cloud", "TE-1");
    it.where = .cloud;
    const by_record = try describeArgv(a, o, it);
    try t.expectEqualStrings("get-item", by_record[2]);
    try t.expectEqualStrings("{\"runId\":{\"S\":\"run-1\"}}", by_record[6]);
    it.cloud = .{ .task_arn = "arn:1" };
    const by_task = try describeArgv(a, o, it);
    try t.expectEqualStrings("describe-tasks", by_task[2]);
    try t.expectEqualStrings("arn:1", by_task[6]);
    const stop = try stopArgv(a, o, "arn:1");
    try t.expectEqualStrings("stop-task", stop[2]);
    const run = try runTaskArgv(a, o, "TE-9", "opus");
    try t.expectEqualStrings("run-task", run[2]);
    try t.expect(std.mem.indexOf(u8, run[10], "\"TICKET\",\"value\":\"TE-9\"") != null);
    try t.expect(std.mem.indexOf(u8, run[10], "\"MODEL\",\"value\":\"opus\"") != null);
    const run_plain = try runTaskArgv(a, o, "TE-9", null);
    try t.expect(std.mem.indexOf(u8, run_plain[10], "MODEL") == null);
}

test "cloudwatchUrl: Rust's console link, the query escaped its way; null unless the account, region and group are all set" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(try cloudwatchUrl(a, "r", "", "g", "run-x") == null);
    try t.expect(try cloudwatchUrl(a, "", "1", "g", "run-x") == null);
    try t.expect(try cloudwatchUrl(a, "r", "1", "", "run-x") == null);
    const url = (try cloudwatchUrl(a, "us-east-1", "123", "/ecs/runner", "run-x")).?;
    try t.expect(std.mem.startsWith(u8, url, "https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#logsV2:logs-insights"));
    try t.expect(std.mem.indexOf(u8, url, "fields*20@timestamp") == null);
    try t.expect(std.mem.indexOf(u8, url, "fields*20*40timestamp*2c*20*40message*20*7c*20filter") != null);
    try t.expect(std.mem.indexOf(u8, url, "like*20*2frun-x*2f*20") != null);
    try t.expect(std.mem.indexOf(u8, url, "source~(~'$252Fecs$252Frunner))") != null);
    try t.expect(std.mem.endsWith(u8, url, "?account=123"));
}

test "the wizards refuse without the config; the New menu says so" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"cloud_agents.new_run" }));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "runs_table") != null);
    app.diag.clear();
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"cloud_agents.new_run_wizard" }));
    app.diag.clear();
    // Configured: the one-prompt wizard opens its prompt; the two-step
    // one asks for the model after the ticket.
    app.cfg.cloud_agents.runs_table = "runs";
    app.cfg.cloud_agents.region = "r";
    try command.run(&app, .{ .static = .@"cloud_agents.new_run" });
    try t.expect(app.overlay == .prompt and app.overlay.prompt.purpose == .cloud_run_ticket);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    try command.run(&app, .{ .static = .@"cloud_agents.new_run_wizard" });
    try t.expect(app.overlay == .prompt and app.overlay.prompt.purpose == .cloud_run_wizard_ticket);
    try acceptWizardTicket(&app, "TE-5");
    try t.expect(app.overlay == .prompt and app.overlay.prompt.purpose == .cloud_run_model);
    try t.expectEqualStrings("TE-5", app.overlay.prompt.purpose.cloud_run_model);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // Without a cluster the run does not fire; it says what is missing.
    try acceptRun(&app, "TE-5", null);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "cluster") != null);
}

test "a cloud run's toast never claims the run started — the pane's output says whether it did" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(t.io, &buf)];
    // An `aws` that fails: the run never starts.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "aws", .data = "#!/bin/sh\nexit 1\n" });
    try tmp.dir.setFilePermissions(t.io, "aws", .fromMode(0o755), .{});
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = dir, .cols = 100, .rows = 30 });
    defer app.deinit();
    try app.env.put("PATH", dir);
    app.cfg.cloud_agents.runs_table = "runs";
    app.cfg.cloud_agents.region = "r";
    app.cfg.cloud_agents.cluster = "c";
    app.cfg.cloud_agents.task_definition = "td";
    try acceptRun(&app, "DEMO-1", null);
    const said = app.lastToast().?;
    try t.expect(std.mem.indexOf(u8, said, "started for") == null);
    try t.expect(std.mem.indexOf(u8, said, "DEMO-1") != null);
    try t.expect(std.mem.indexOf(u8, said, "its output says whether") != null);
}
