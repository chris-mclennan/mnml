//! mnml-bitbucket — the Bitbucket Cloud viewer, written on `mnml-sdk`:
//! pull requests and pipeline runs, workspace-scoped, with the
//! reference's tabs (per-repo, mine, workspace-wide trees), its detail,
//! its one write (approve), and the chip the statusline shows.
//!
//!   mnml-bitbucket --install      write both manifests (PRs, Pipelines) + the config scaffold
//!   mnml-bitbucket --uninstall    delete both manifests
//!   mnml-bitbucket --version
//!   mnml-bitbucket --scaffold     write config.zon and say where
//!   mnml-bitbucket --check        resolved config + auth + a live whoami
//!   mnml-bitbucket --diag         the whole tree, for a bug report
//!   mnml-bitbucket --values [--workspace W]   {"open_mine":N,…}; with a
//!                                 workspace, the chip is republished too
//!   mnml-bitbucket --list-prs --json
//!   mnml-bitbucket --find-pipeline-for-pr --owner O --repo R --branch B --json
//!   mnml-bitbucket --refresh [--workspace W]   republish the chip over Tier-2 IPC, headless
//!   mnml-bitbucket --prefetch     fetch every tab and cache it for the next pane open
//!   mnml-bitbucket --only prs|prs-mine|prs-awaiting|pipelines|branches
//!   mnml-bitbucket                connect to `$MNML_MOUNT_SOCKET` and paint
//!
//! The pane never blocks on the network: a reader thread turns the
//! mount's messages into events, a worker thread runs the fetches, a
//! ticker keeps the auto-refresh, and the main loop takes one event at
//! a time — commits a result, answers a key, paints.
//!
//! **No token is ever printed.** `--check` and `--diag` name where it
//! came from and how long it is; `auth.zig` has the test that holds
//! that line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sdk = @import("mnml_sdk");

const cfg = @import("src/config.zig");
const auth = @import("src/auth.zig");
const api = @import("src/api.zig");
const ratelimit = @import("src/ratelimit.zig");
const cache_mod = @import("src/cache.zig");
const review_cache = @import("src/review_cache.zig");
const fetch = @import("src/fetch.zig");
const app_mod = @import("src/app.zig");
const screen = @import("src/screen.zig");
const model = @import("src/model.zig");
const theme_mod = @import("src/theme.zig");
const os = @import("src/os.zig");
const j = @import("src/json.zig");

pub const spec: sdk.Manifest = @import("manifest.zon");
pub const spec_pipelines: sdk.Manifest = @import("manifest_pipelines.zon");

/// The segment the pane and `--refresh` republish: the manifest's
/// entry keyed by mnml as `<id>.<segment id>`.
pub const segment_id = "bitbucket_prs.prs_mine";
pub const segment_color = "green";
pub const segment_click = "bitbucket_prs.open_mine";

/// The second figure: review threads across those pull requests that
/// are still waiting on someone. Its own chip, because it answers a
/// different question from "how many are open".
pub const review_segment_id = "bitbucket_prs.reviews_mine";
pub const review_segment_glyph = "\u{f075}"; // nf-fa-comment
pub const review_segment_color = "yellow";

/// The third figure: open pull requests waiting on YOUR review. Its own
/// chip again, because it is the one of the three that is your move.
pub const awaiting_segment_id = "bitbucket_prs.reviews_pending";
pub const awaiting_segment_glyph = "\u{f0e5}"; // nf-fa-comment_o
pub const awaiting_segment_color = "orange";
pub const awaiting_segment_click = "bitbucket_prs.open_awaiting";

const Opts = struct {
    install: bool = false,
    uninstall: bool = false,
    version: bool = false,
    scaffold: bool = false,
    check: bool = false,
    diag: bool = false,
    values: bool = false,
    list_prs: bool = false,
    find_pipeline: bool = false,
    json: bool = false,
    refresh: bool = false,
    prefetch: bool = false,
    help: bool = false,
    only: ?[]const u8 = null,
    owner: []const u8 = "",
    repo: []const u8 = "",
    branch: []const u8 = "",
    workspace: []const u8 = "",
};

fn parseArgs(args: []const []const u8) !Opts {
    var o: Opts = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--install")) {
            o.install = true;
        } else if (std.mem.eql(u8, a, "--uninstall")) {
            o.uninstall = true;
        } else if (std.mem.eql(u8, a, "--version")) {
            o.version = true;
        } else if (std.mem.eql(u8, a, "--scaffold")) {
            o.scaffold = true;
        } else if (std.mem.eql(u8, a, "--check")) {
            o.check = true;
        } else if (std.mem.eql(u8, a, "--diag")) {
            o.diag = true;
        } else if (std.mem.eql(u8, a, "--values")) {
            o.values = true;
        } else if (std.mem.eql(u8, a, "--list-prs")) {
            o.list_prs = true;
        } else if (std.mem.eql(u8, a, "--find-pipeline-for-pr")) {
            o.find_pipeline = true;
        } else if (std.mem.eql(u8, a, "--json")) {
            o.json = true;
        } else if (std.mem.eql(u8, a, "--refresh")) {
            o.refresh = true;
        } else if (std.mem.eql(u8, a, "--prefetch")) {
            o.prefetch = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            o.help = true;
        } else if (std.mem.eql(u8, a, "--only") and i + 1 < args.len) {
            i += 1;
            o.only = args[i];
        } else if (std.mem.eql(u8, a, "--owner") and i + 1 < args.len) {
            i += 1;
            o.owner = args[i];
        } else if (std.mem.eql(u8, a, "--repo") and i + 1 < args.len) {
            i += 1;
            o.repo = args[i];
        } else if (std.mem.eql(u8, a, "--branch") and i + 1 < args.len) {
            i += 1;
            o.branch = args[i];
        } else if (std.mem.eql(u8, a, "--workspace") and i + 1 < args.len) {
            i += 1;
            o.workspace = args[i];
        } else {
            return error.UnknownArgument;
        }
    }
    return o;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [8192]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const stdout = &out_w.interface;
    defer stdout.flush() catch {};
    var err_buf: [2048]u8 = undefined;
    var err_w: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const stderr = &err_w.interface;
    defer stderr.flush() catch {};

    const opts = parseArgs(args) catch {
        try stderr.print("mnml-bitbucket: unknown argument (see --help)\n{s}", .{usage});
        return 2;
    };
    if (opts.help) {
        try stdout.writeAll(usage);
        return 0;
    }
    if (opts.version) {
        try stdout.print("mnml-bitbucket {s} (bridge protocol {d})\n", .{ spec.version, sdk.protocol });
        return 0;
    }
    if (opts.install) return install(gpa, io, env, stdout, stderr);
    if (opts.uninstall) return uninstall(gpa, io, env, stdout, stderr);
    if (opts.scaffold) {
        const p = cfg.configPath(gpa, env) catch {
            try stderr.writeAll("mnml-bitbucket: no HOME, XDG_CONFIG_HOME or MNML_DATA_ROOT to write into\n");
            return 1;
        };
        defer gpa.free(p);
        cfg.scaffold(io, p) catch {
            try stderr.print("mnml-bitbucket: could not write {s}\n", .{p});
            return 1;
        };
        try stdout.print("{s}\n", .{p});
        return 0;
    }
    if (opts.check or opts.diag) return diagnose(gpa, io, env, stdout, opts.diag);
    if (opts.values) return valuesCmd(gpa, io, env, stdout, stderr, opts.workspace);
    if (opts.list_prs) {
        if (!opts.json) {
            try stderr.writeAll("--list-prs requires --json (only shape supported v1)\n");
            return 2;
        }
        return listPrsCmd(gpa, io, env, stdout, stderr);
    }
    if (opts.find_pipeline) {
        if (!opts.json) {
            try stderr.writeAll("--find-pipeline-for-pr requires --json\n");
            return 2;
        }
        if (opts.owner.len == 0 or opts.repo.len == 0 or opts.branch.len == 0) {
            try stderr.writeAll("--owner, --repo and --branch are required\n");
            return 2;
        }
        return findPipelineCmd(gpa, io, env, stdout, stderr, opts.owner, opts.repo, opts.branch);
    }
    if (opts.refresh) return refreshCmd(gpa, io, env, stdout, stderr, opts.workspace);
    if (opts.prefetch) return prefetchCmd(gpa, io, env, stdout, stderr);

    const mount = sdk.Mount.connectEnv(gpa, io, env) catch |err| switch (err) {
        error.NoSocket => {
            try stderr.writeAll("mnml-bitbucket is an mnml integration: open it from mnml (bitbucket_prs.open / bitbucket_pipelines.open), or run `mnml-bitbucket --install` / `--check`.\n");
            return 2;
        },
        else => return err,
    };
    return pane(gpa, io, env, mount, opts);
}

const usage =
    \\mnml-bitbucket — Bitbucket Cloud pull requests + pipelines as an mnml pane.
    \\
    \\  --install / --uninstall   register both chips with mnml (and scaffold the config)
    \\  --version
    \\  --scaffold                write config.zon and print its path
    \\  --check                   resolved config + auth + a live whoami
    \\  --diag                    the whole tree, for a bug report
    \\  --values [--workspace W]  {"open_mine":N,…}; republishes the chip with a workspace
    \\  --list-prs --json         every open PR the per-repo tabs list
    \\  --find-pipeline-for-pr --owner O --repo R --branch B --json
    \\  --refresh [--workspace W] republish the statusline chip, headless
    \\  --prefetch                warm the pane's cache; 0 complete, 2 partial, 1 could not run
    \\  --only prs|prs-mine|prs-awaiting|pipelines|branches   one family of tabs
    \\
;

// ─── install ─────────────────────────────────────────────────────────────

fn install(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    for ([_]sdk.Manifest{ spec, spec_pipelines }) |m| {
        const path = sdk.manifest.write(gpa, io, env, m) catch |err| {
            try stderr.print("mnml-bitbucket: could not write the manifest for {s}: {s}\n", .{ m.id, @errorName(err) });
            return 1;
        };
        defer gpa.free(path);
        try stdout.print("mnml-bitbucket: wrote {s}\n", .{path});
    }
    // The config is private to this machine and lives beside the
    // manifests, not inside them; scaffold it now so the first run
    // has something to edit rather than an error.
    if (cfg.configPath(gpa, env) catch null) |p| {
        defer gpa.free(p);
        if (Io.Dir.cwd().access(io, p, .{})) |_| {
            try stdout.print("mnml-bitbucket: config already at {s}\n", .{p});
        } else |_| {
            cfg.scaffold(io, p) catch {};
            try stdout.print("mnml-bitbucket: wrote the config scaffold to {s} — set `email`, `workspace` and `repos`\n", .{p});
        }
    }
    return 0;
}

fn uninstall(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    var any = false;
    for ([_][]const u8{ spec.id, spec_pipelines.id }) |id| {
        const went = sdk.manifest.remove(gpa, io, env, id) catch |err| {
            try stderr.print("mnml-bitbucket: could not remove {s}: {s}\n", .{ id, @errorName(err) });
            return 1;
        };
        any = any or went;
    }
    try stdout.print("mnml-bitbucket: {s} (the config stays; delete it by hand)\n", .{if (any) "removed the manifests" else "nothing to remove"});
    return 0;
}

// ─── a session: config, tokens, the client ───────────────────────────────

const Session = struct {
    loaded: cfg.Loaded,
    tokens: auth.Tokens,
    limiter: ratelimit.Limiter,
    client: api.Client,
    base_url: []u8,

    fn deinit(s: *Session, gpa: Allocator) void {
        s.client.deinit();
        s.limiter.deinit();
        s.tokens.deinit();
        s.loaded.deinit();
        gpa.free(s.base_url);
    }
};

const SessionError = error{ NoConfig, NoToken } || Allocator.Error;

/// Load everything a command needs; `why` explains a refusal.
fn openSession(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, why: *[]const u8) SessionError!Session {
    var loaded = cfg.load(gpa, io, env, why) catch return error.NoConfig;
    errdefer loaded.deinit();
    const config_dir = std.fs.path.dirname(loaded.path) orelse ".";
    var tokens = try auth.resolve(gpa, io, env, config_dir);
    errdefer tokens.deinit();
    if (!tokens.hasRead()) {
        why.* = no_token_text;
        return error.NoToken;
    }
    const base_url = try resolveBaseUrl(gpa, io, env, loaded.config);
    errdefer gpa.free(base_url);
    const state_path = if (loaded.config.rate.state_path.len > 0) try gpa.dupe(u8, loaded.config.rate.state_path) else try ratelimit.statePath(gpa, io, env);
    defer gpa.free(state_path);
    var limiter = try ratelimit.Limiter.init(gpa, io, state_path, .{ .rate = loaded.config.rate.rate_per_sec, .capacity = loaded.config.rate.capacity });
    errdefer limiter.deinit();
    var client = try api.Client.init(gpa, io, base_url, loaded.config.email, tokens.read, if (tokens.write_source == .env) tokens.write else "", loaded.config.rate);
    errdefer client.deinit();
    return .{ .loaded = loaded, .tokens = tokens, .limiter = limiter, .client = client, .base_url = base_url };
}

/// `$BITBUCKET_BASE_URL` — literally, or `@<path>` naming a file that
/// holds it (the fake server writes its port there) — then the
/// config's, then the real API.
fn resolveBaseUrl(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, c: cfg.Config) Allocator.Error![]u8 {
    if (cfg.nonEmpty(env.get("BITBUCKET_BASE_URL"))) |v| {
        if (v[0] == '@') {
            var attempts: u32 = 0;
            while (attempts < 50) : (attempts += 1) {
                if (Io.Dir.cwd().readFileAlloc(io, v[1..], gpa, .limited(4096))) |text| {
                    const trimmed = std.mem.trim(u8, text, " \r\n\t");
                    if (trimmed.len > 0) {
                        const out = try gpa.dupe(u8, trimmed);
                        gpa.free(text);
                        return out;
                    }
                    gpa.free(text);
                } else |_| {}
                io.sleep(.fromMilliseconds(100), .awake) catch {};
            }
            return gpa.dupe(u8, api.default_base_url);
        }
        return gpa.dupe(u8, v);
    }
    if (c.base_url.len > 0) return gpa.dupe(u8, c.base_url);
    return gpa.dupe(u8, api.default_base_url);
}

const no_token_text = "no Bitbucket token: set BITBUCKET_ACCESS_TOKEN, or write it to <config dir>/token (BITBUCKET_API_TOKEN / BITBUCKET_APP_PASSWORD / BITBUCKET_PERSONAL_TOKEN also resolve, in that order, between the two)";

fn nowSecs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds();
}

// ─── --check / --diag ────────────────────────────────────────────────────

fn diagnose(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, out: *Io.Writer, full: bool) !u8 {
    var why: []const u8 = "";
    var s = openSession(gpa, io, env, &why) catch |err| {
        const p = cfg.configPath(gpa, env) catch null;
        defer if (p) |x| gpa.free(x);
        try out.print("config: {s}\n", .{p orelse "(no data root)"});
        try out.print("{s}: {s}\n", .{ @errorName(err), why });
        return 1;
    };
    defer s.deinit(gpa);
    s.client.limiter = &s.limiter;
    const c = s.loaded.config;
    const tk = try auth.describe(gpa, &s.tokens);
    defer gpa.free(tk);
    if (!full) {
        try out.print("config: {s}\n{s}", .{ s.loaded.path, tk });
        try out.print("workspace: {s}\nemail: {s}\nrefresh_interval_secs: {d}\nscope: {s}\nrecent_window_days: {d}\n", .{ c.workspace, c.email, c.refresh_interval_secs, @tagName(c.scope), c.recent_window_days });
    } else {
        try out.print("mnml-bitbucket · diagnostics\n\nAuth\n  ├─ {s}  ├─ email: {s}\n", .{ tk, c.email });
    }
    var progress: fetch.Progress = .{};
    var worker = fetch.Worker.init(gpa, io, &s.client, &progress, c.account_id, c.workspace);
    defer worker.deinit();
    var job = try fetch.makeJob(gpa, nowSecs(io), .whoami);
    defer job.deinit();
    var res = try worker.run(&job);
    defer res.deinit();
    const who = res.payload.whoami;
    // Name the question that was actually asked. An access token has
    // no account, so the probe is the workspace, and saying "whoami"
    // there would be the same lie that sent the user hunting a good
    // token in the first place.
    const probe = switch (who.via) {
        .account => "whoami",
        .workspace => "workspace probe",
    };
    if (who.error_text.len > 0) {
        try out.print("{s}{s}: {s} {s}\n", .{ if (full) "  └─ " else "", probe, if (full) "✗" else "FAIL —", who.error_text });
        if (full) try out.writeAll("     mine-only filters, --values, and workspace repo enumeration all depend on this succeeding.\n");
    } else switch (who.via) {
        .account => try out.print("{s}whoami: {s} {s} (account_id: {s})\n", .{ if (full) "  └─ " else "", if (full) "✓" else "ok —", who.display_name, if (who.account_id.len > 0) who.account_id else "<none>" }),
        .workspace => {
            try out.print("{s}workspace probe: {s} {s} reached — an access token has no account to ask about\n", .{ if (full) "  └─ " else "", if (full) "✓" else "ok —", who.display_name });
            if (c.account_id.len == 0) try out.print("{s}set `account_id` in {s}: the `mine` / `reviewing` tabs and --values cannot resolve it from an access token\n", .{ if (full) "     " else "  note: ", s.loaded.path });
        },
    }
    if (full) {
        try out.print("\nConfig\n  ├─ path: {s}\n  ├─ workspace: {s}\n  ├─ scope: {s}\n  ├─ recent_window_days: {d}\n  ├─ refresh_interval_secs: {d}\n", .{ s.loaded.path, c.workspace, @tagName(c.scope), c.recent_window_days, c.refresh_interval_secs });
        if (c.repos.len == 0) {
            try out.writeAll("  ├─ repos allowlist: (none — enumerating all)\n");
        } else {
            try out.print("  ├─ repos allowlist: {d} entries\n", .{c.repos.len});
            for (c.repos[0..@min(c.repos.len, 5)]) |r| try out.print("  │   {s}\n", .{r});
            if (c.repos.len > 5) try out.print("  │   … and {d} more\n", .{c.repos.len - 5});
        }
        try out.print("  └─ tabs: {d}\n", .{c.tabs.len});
    }
    for (c.tabs, 0..) |tab, i| {
        const shape = switch (tab.kind) {
            .pull_requests => if (tab.mode != .none) try std.fmt.allocPrint(gpa, "mode={s}", .{@tagName(tab.mode)}) else if (tab.repo.len > 0) try std.fmt.allocPrint(gpa, "repo={s}", .{tab.repo}) else try gpa.dupe(u8, "q=<custom>"),
            else => try std.fmt.allocPrint(gpa, "kind={s}", .{@tagName(tab.kind)}),
        };
        defer gpa.free(shape);
        if (full) {
            try out.print("      {d}. {s} ({s}, state={s})\n", .{ i + 1, tab.name, shape, @tagName(tab.state) });
        } else {
            try out.print("  tab {d} ({s}): {s}, state={s}\n", .{ i + 1, tab.name, shape, @tagName(tab.state) });
        }
    }
    if (full) {
        if (s.limiter.status()) |st| {
            try out.print("\nRate bucket\n  ├─ file: {s}\n  ├─ tokens: {d:.1} of {d:.0}\n  ├─ rate: {d:.2}/s (baseline {d:.2})\n  ├─ throttles: {d}\n  └─ cooldown: {d:.0}s\n", .{ s.limiter.path, st.tokens, st.capacity, st.rate, st.baseline_rate, st.throttles, st.cooldown_remaining_secs });
        }
        try out.print("\nRuntime\n  ├─ integration: {s}\n  ├─ api: {s}\n  └─ os/arch: {s} / {s}\n", .{ spec.version, s.base_url, @tagName(@import("builtin").os.tag), @tagName(@import("builtin").cpu.arch) });
    }
    return 0;
}

// ─── --values / --refresh ────────────────────────────────────────────────

/// `review_cache` non-null asks for the second figure: the unresolved
/// review threads, one comments request per pull request that has
/// moved since the last run.
fn computeValues(gpa: Allocator, io: Io, s: *Session, rc: ?*review_cache.Cache) !fetch.Result {
    var progress: fetch.Progress = .{};
    var worker = fetch.Worker.init(gpa, io, &s.client, &progress, s.loaded.config.account_id, s.loaded.config.workspace);
    worker.review_cache = rc;
    defer worker.deinit();
    const c = s.loaded.config;
    var job = try fetch.makeJob(gpa, nowSecs(io), .{ .values = .{
        .scope = fetch.scopeOf(c, c.workspace, 1),
        .stale_after_days = c.chip_stale_after_days,
        .excluded_branch_patterns = c.chip_excluded_branch_patterns,
    } });
    defer job.deinit();
    return worker.run(&job);
}

/// The reference's `--values`: the JSON a statusline poller reads —
/// and, with `--workspace W`, the segment published over that
/// workspace's channel too, the way the tracker's `--values` does. The
/// host's poller runs exactly this line, so the chip moves with no pane
/// open and the host parses nothing.
/// Non-zero on any failure, with a line on stderr.
fn valuesCmd(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, out: *Io.Writer, err: *Io.Writer, workspace: []const u8) !u8 {
    var why: []const u8 = "";
    var s = openSession(gpa, io, env, &why) catch {
        try err.print("mnml-bitbucket --values: {s}\n", .{why});
        return 1;
    };
    defer s.deinit(gpa);
    s.client.limiter = &s.limiter;
    // The unresolved-comment count is the poller's figure, and it is
    // paid for out of the same bucket — the cache is what keeps it to
    // one request per pull request that actually moved.
    var rc = try review_cache.Cache.open(gpa, io, s.loaded.path);
    defer rc.deinit();
    var res = try computeValues(gpa, io, &s, &rc);
    defer res.deinit();
    const v = res.payload.values;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var ipc = try ipcFor(gpa, io, env, workspace);
    defer if (ipc) |*x| x.deinit();
    if (ipc) |*x| publishSegments(x, arena_state.allocator(), v) catch {};
    if (v.error_text.len > 0) {
        try err.print("mnml-bitbucket --values: {s}\n", .{v.error_text});
        return 1;
    }
    try out.print("{{\"open_mine\":{d},\"unapproved_mine\":{d},\"approved_mine\":{d},\"reviews_pending\":{d},\"unresolved_comments\":", .{ v.open_mine, v.unapproved_mine, v.approved_mine, v.reviews_pending });
    if (v.unresolved_comments) |n| try out.print("{d}", .{n}) else try out.writeAll("null");
    try out.writeAll("}\n");
    return 0;
}

/// The chip's text for a values result: `󰂨 4(2)`, or `󰂨 !` on a failure.
pub fn segmentText(buf: []u8, v: fetch.ValuesResult) []const u8 {
    if (v.error_text.len > 0) return app_mod.App.chip_glyph ++ " !";
    return std.fmt.bufPrint(buf, app_mod.App.chip_glyph ++ " {d}({d})", .{ v.open_mine, v.unapproved_mine }) catch app_mod.App.chip_glyph;
}

/// The review chip's text: `󰅺 3`, the threads still waiting on someone.
pub fn reviewText(buf: []u8, unresolved: usize) []const u8 {
    return std.fmt.bufPrint(buf, review_segment_glyph ++ " {d}", .{unresolved}) catch review_segment_glyph;
}

/// The awaiting chip's text: ` 2`, the pull requests waiting on you.
pub fn awaitingText(buf: []u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, awaiting_segment_glyph ++ " {d}", .{n}) catch awaiting_segment_glyph;
}

/// ` — “Fix the login redirect”, “Bump the client timeout”`, or nothing
/// when there are no titles. A count alone sends the reader into the
/// pane to find out WHICH; the names answer it under the pointer.
pub fn titleTail(arena: Allocator, titles: []const []const u8) Allocator.Error![]const u8 {
    if (titles.len == 0) return "";
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll(" \u{2014} ") catch return error.OutOfMemory;
    for (titles, 0..) |title, i| {
        if (i > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.print("\u{201c}{s}\u{201d}", .{title}) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// What the PR chip means, on hover. A number with no sentence behind
/// it makes the reader guess, and these two are easy to mix up.
pub fn segmentTooltip(arena: Allocator, v: fetch.ValuesResult) Allocator.Error![]const u8 {
    if (v.error_text.len > 0) return std.fmt.allocPrint(arena, "Bitbucket: {s}", .{v.error_text});
    return std.fmt.allocPrint(
        arena,
        "Bitbucket · {d} open pull request{s} you authored — {d} still unapproved, {d} approved{s}",
        .{ v.open_mine, if (v.open_mine == 1) "" else "s", v.unapproved_mine, v.approved_mine, try titleTail(arena, v.open_titles) },
    );
}

/// What the review chip means, and what it cost: a reader who is
/// rate-limit-shy wants to know how much of the bucket a poll spends.
pub fn reviewTooltip(arena: Allocator, v: fetch.ValuesResult, unresolved: usize) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "Bitbucket · {d} review thread{s} across your open pull requests still waiting on someone (neither resolved nor replied to) — {d} of {d} counted off the cache{s}",
        .{ unresolved, if (unresolved == 1) "" else "s", v.comment_hits, v.comment_hits + v.comment_requests, try titleTail(arena, v.comment_titles) },
    );
}

/// What the awaiting chip means: the pull requests you are a reviewer
/// on and have not voted.
pub fn awaitingTooltip(arena: Allocator, v: fetch.ValuesResult) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "Bitbucket · {d} open pull request{s} waiting on YOUR review — you are a reviewer and have not approved{s}",
        .{ v.reviews_pending, if (v.reviews_pending == 1) "" else "s", try titleTail(arena, v.awaiting_titles) },
    );
}

/// The Tier-2 lines that put the chips on the statusline and the count
/// on the INTEGRATIONS badge — what the pane, `--refresh` and
/// `--values` all send. The unit test below pins the JSON.
///
/// Two chips, because they are two numbers about two different things:
/// how much of yours is open, and how much of it is waiting on a human.
/// The review chip is published only when the count was taken — a zero
/// there would read as "nothing outstanding" when it may mean "not
/// counted this run".
pub fn publishSegments(ipc: *const sdk.Ipc, arena: Allocator, v: fetch.ValuesResult) !void {
    var buf: [64]u8 = undefined;
    try ipc.statuslineSetSegment(.{
        .id = segment_id,
        .text = segmentText(&buf, v),
        .color = if (v.error_text.len > 0) "red" else segment_color,
        .click_command = segment_click,
        .priority = 60,
        .tooltip = try segmentTooltip(arena, v),
    });
    if (v.unresolved_comments) |n| {
        var rbuf: [64]u8 = undefined;
        try ipc.statuslineSetSegment(.{
            .id = review_segment_id,
            .text = reviewText(&rbuf, n),
            .color = if (n > 0) review_segment_color else "green",
            .click_command = segment_click,
            .priority = 59,
            .tooltip = try reviewTooltip(arena, v, n),
        });
    }
    var abuf: [64]u8 = undefined;
    try ipc.statuslineSetSegment(.{
        .id = awaiting_segment_id,
        .text = awaitingText(&abuf, v.reviews_pending),
        .color = if (v.reviews_pending > 0) awaiting_segment_color else "green",
        .click_command = awaiting_segment_click,
        .priority = 58,
        .tooltip = try awaitingTooltip(arena, v),
    });
    try ipc.setActivityBadge("integrations", @intCast(@min(v.open_mine, std.math.maxInt(u32))));
}

/// The one-chip form, for callers with no arena to spare.
pub fn publishSegment(ipc: *const sdk.Ipc, v: fetch.ValuesResult) sdk.ipc.Error!void {
    var buf: [64]u8 = undefined;
    try ipc.statuslineSetSegment(.{
        .id = segment_id,
        .text = segmentText(&buf, v),
        .color = if (v.error_text.len > 0) "red" else segment_color,
        .click_command = segment_click,
        .priority = 60,
    });
    try ipc.setActivityBadge("integrations", @intCast(@min(v.open_mine, std.math.maxInt(u32))));
}

/// The channel a headless run publishes on: `$MNML_IPC_DIR`, else
/// `<workspace>/.mnml/ipc-zig` — a `term` child does not inherit the
/// variable, which is why the ex line passes `--workspace`.
fn ipcFor(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, workspace: []const u8) Allocator.Error!?sdk.Ipc {
    if (try sdk.Ipc.fromEnv(gpa, io, env)) |ipc| return ipc;
    if (workspace.len == 0) return null;
    const dir = try std.fs.path.join(gpa, &.{ workspace, ".mnml", "ipc-zig" });
    defer gpa.free(dir);
    if (Io.Dir.cwd().access(io, dir, .{})) |_| {} else |_| return null;
    return try sdk.Ipc.init(gpa, io, dir);
}

fn refreshCmd(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, out: *Io.Writer, err: *Io.Writer, workspace: []const u8) !u8 {
    var why: []const u8 = "";
    var s = openSession(gpa, io, env, &why) catch {
        try err.print("mnml-bitbucket --refresh: {s}\n", .{why});
        return 1;
    };
    defer s.deinit(gpa);
    s.client.limiter = &s.limiter;
    var rc = try review_cache.Cache.open(gpa, io, s.loaded.path);
    defer rc.deinit();
    var res = try computeValues(gpa, io, &s, &rc);
    defer res.deinit();
    const v = res.payload.values;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var ipc = try ipcFor(gpa, io, env, workspace);
    defer if (ipc) |*x| x.deinit();
    if (ipc) |*x| publishSegments(x, arena_state.allocator(), v) catch {};
    if (v.error_text.len > 0) {
        try err.print("mnml-bitbucket --refresh: {s}\n", .{v.error_text});
        return 1;
    }
    try out.print("{d} open pull requests you authored, {d} still unapproved", .{ v.open_mine, v.unapproved_mine });
    if (v.unresolved_comments) |n| try out.print(", {d} review thread{s} waiting on someone ({d} of {d} off the cache)", .{ n, if (n == 1) "" else "s", v.comment_hits, v.comment_hits + v.comment_requests });
    try out.print("{s}\n", .{if (ipc == null) " (no IPC channel found — pass --workspace)" else ""});
    return 0;
}

// ─── --list-prs / --find-pipeline-for-pr ─────────────────────────────────

fn writeJsonString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// The reference's cross-host list: every open PR the per-repo
/// `pull_requests` tabs list, deduped, in mnml's `SiblingPr` shape.
fn listPrsCmd(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, out: *Io.Writer, err: *Io.Writer) !u8 {
    var why: []const u8 = "";
    var s = openSession(gpa, io, env, &why) catch {
        try err.print("mnml-bitbucket --list-prs: {s}\n", .{why});
        return 1;
    };
    defer s.deinit(gpa);
    s.client.limiter = &s.limiter;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    try out.writeAll("{\"host\":\"bitbucket\",\"prs\":[");
    var n: usize = 0;
    for (s.loaded.config.tabs) |tab| {
        if (tab.kind != .pull_requests or tab.repo.len == 0) continue;
        const ws = s.loaded.config.tabWorkspace(tab);
        var reply = try s.client.listPrs(gpa, ws, tab.repo, @tagName(tab.state), tab.q, 50);
        defer reply.deinit(gpa);
        switch (reply) {
            .ok => |body| {
                const v = std.json.parseFromSliceLeaky(j.Value, a, body.bytes, .{}) catch continue;
                for (try model.parsePullRequests(a, v)) |pr| {
                    const key = try std.fmt.allocPrint(a, "{s}/{s}#{d}", .{ ws, tab.repo, pr.id });
                    if (seen.contains(key)) continue;
                    try seen.put(a, key, {});
                    if (n > 0) try out.writeByte(',');
                    n += 1;
                    var ubuf: [256]u8 = undefined;
                    try out.print("{{\"id\":\"{d}\",\"url\":", .{pr.id});
                    try writeJsonString(out, pr.url(&ubuf, ws, tab.repo));
                    try out.print(",\"owner\":\"{s}\",\"repo\":\"{s}\",\"title\":", .{ ws, tab.repo });
                    try writeJsonString(out, pr.title);
                    try out.writeAll(",\"author\":");
                    try writeJsonString(out, pr.author);
                    try out.writeAll(",\"source_branch\":");
                    try writeJsonString(out, pr.source_branch);
                    try out.writeAll(",\"dest_branch\":");
                    try writeJsonString(out, pr.dest_branch);
                    try out.writeAll(",\"state\":");
                    const lower = try std.ascii.allocLowerString(a, pr.state);
                    try writeJsonString(out, lower);
                    try out.writeAll(",\"updated_at\":");
                    try writeJsonString(out, pr.updated_on);
                    try out.print(",\"remote_url_https\":\"https://bitbucket.org/{s}/{s}.git\",\"remote_url_ssh\":\"git@bitbucket.org:{s}/{s}.git\"}}", .{ ws, tab.repo, ws, tab.repo });
                }
            },
            .failed => |f| {
                var buf: [256]u8 = undefined;
                try err.print("tab '{s}' skipped: {s}\n", .{ tab.name, f.describe(&buf) });
            },
        }
    }
    try out.writeAll("]}\n");
    return 0;
}

fn findPipelineCmd(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, out: *Io.Writer, err: *Io.Writer, owner: []const u8, repo: []const u8, branch: []const u8) !u8 {
    var why: []const u8 = "";
    var s = openSession(gpa, io, env, &why) catch {
        try err.print("mnml-bitbucket --find-pipeline-for-pr: {s}\n", .{why});
        return 1;
    };
    defer s.deinit(gpa);
    s.client.limiter = &s.limiter;
    var reply = try s.client.listPipelines(gpa, owner, repo, 50);
    defer reply.deinit(gpa);
    switch (reply) {
        .ok => |body| {
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const v = std.json.parseFromSliceLeaky(j.Value, arena_state.allocator(), body.bytes, .{}) catch {
                try out.writeAll("{\"url\":null}\n");
                return 0;
            };
            for (try model.parsePipelines(arena_state.allocator(), v)) |p| if (std.mem.eql(u8, p.ref_name, branch)) {
                try out.print("{{\"url\":\"https://bitbucket.org/{s}/{s}/pipelines/results/{d}\"}}\n", .{ owner, repo, p.build_number });
                return 0;
            };
            try out.writeAll("{\"url\":null}\n");
            return 0;
        },
        .failed => |f| {
            var buf: [256]u8 = undefined;
            try err.print("listing pipelines for {s}/{s}: {s}\n", .{ owner, repo, f.describe(&buf) });
            return 1;
        },
    }
}

// ─── --prefetch ──────────────────────────────────────────────────────────

/// Fetch every configured tab once and leave the bodies in the pane's
/// cache, so the next `bitbucket_prs.open` paints rows instead of
/// `loading… 0/13 repos` for the minutes the shared bucket takes.
///
/// It walks the same `App` the pane does, so what is warmed is exactly
/// what the pane will ask for, and every request goes through the same
/// shared limiter — a poller running this is one more well-behaved
/// process on the bucket, not a second opinion about it.
///
/// Exit: 0 the cache is complete · 2 it ran and some repo failed (the
/// cache holds the rest) · 1 it could not run at all.
fn prefetchCmd(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, out: *Io.Writer, err: *Io.Writer) !u8 {
    var why: []const u8 = "";
    var s = openSession(gpa, io, env, &why) catch |e| {
        try err.print("mnml-bitbucket --prefetch: {s}\n", .{if (e == error.NoToken) no_token_text else why});
        return 1;
    };
    defer s.deinit(gpa);
    s.client.limiter = &s.limiter;
    var cache = try cache_mod.Cache.init(gpa, io, s.loaded.path, .fill);
    defer cache.deinit();
    // A repo that left the config must not keep answering from a file.
    cache.clear();
    s.client.cache = &cache;
    s.client.now_secs = nowSecs(io);

    var app = try app_mod.App.init(gpa, io, s.loaded.config, s.loaded.path, .{});
    defer app.deinit();
    if (app.tabs.len == 0) {
        try err.print("mnml-bitbucket --prefetch: no tabs in {s}\n", .{s.loaded.path});
        return 1;
    }
    app.now_secs = s.client.now_secs;
    var progress: fetch.Progress = .{};
    app.progress = &progress;
    var worker = fetch.Worker.init(gpa, io, &s.client, &progress, s.loaded.config.account_id, s.loaded.config.workspace);
    defer worker.deinit();

    try app.startup();
    while (true) {
        const jobs = app.takeJobs();
        if (jobs.len == 0) break;
        defer gpa.free(jobs);
        for (jobs) |*job| {
            defer job.deinit();
            var res = try worker.run(job);
            try app.commit(&res);
        }
    }
    const fx = app.takeEffects();
    app.freeEffects(fx);

    var repos: usize = 0;
    var rows: usize = 0;
    var errored: usize = 0;
    var dead_tabs: usize = 0;
    for (app.tabs) |ts| {
        repos += ts.repos;
        rows += ts.items;
        errored += ts.errored;
        if (ts.error_text.len > 0) dead_tabs += 1;
    }
    try out.print("prefetched {d} tab(s) · {d} repos · {d} rows · {d} requests · {d} cache entries in {s}\n", .{ app.tabs.len, repos, rows, s.client.sent, cache.writes, cache.dir });
    if (dead_tabs == app.tabs.len or cache.writes == 0) {
        try err.print("mnml-bitbucket --prefetch: nothing could be fetched{s}\n", .{if (app.tabs[0].error_text.len > 0) app.tabs[0].error_text else ""});
        return 1;
    }
    if (errored > 0 or dead_tabs > 0) {
        try err.print("mnml-bitbucket --prefetch: {d} repo(s) and {d} tab(s) failed; the cache holds the rest\n", .{ errored, dead_tabs });
        return 2;
    }
    return 0;
}

// ─── the pane ────────────────────────────────────────────────────────────

/// A host message copied off the reader's arena.
const HostEvent = union(enum) {
    key: []u8,
    paste: []u8,
    click: struct { col: u16, row: u16, button: sdk.wire.Button },
    /// A move with a button held.
    drag: struct { col: u16, row: u16 },
    /// A plain move: what a dim button's reason hangs off.
    hover: struct { col: u16, row: u16 },
    session_state: struct { key: []u8, state: sdk.wire.SessionState, session_id: []u8, detail: []u8 },
    scroll: struct { col: u16, row: u16, dy: i16 },
    resize: sdk.wire.Geometry,
    focus: bool,
    goodbye,
    other,
};

const Event = union(enum) {
    host: HostEvent,
    result: *fetch.Result,
    tick,
    host_gone,
};

const EventQueue = Io.Queue(Event);
const JobQueue = Io.Queue(*fetch.Job);

fn readerThread(gpa: Allocator, io: Io, mount: *sdk.Mount, q: *EventQueue) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    while (true) {
        _ = arena.reset(.retain_capacity);
        const msg = (mount.next(arena.allocator()) catch null) orelse {
            q.putOneUncancelable(io, .host_gone) catch {};
            return;
        };
        const ev: HostEvent = switch (msg) {
            .hello => .other,
            // The host's word on the merge session this pane started.
            .session_state => |ss| .{ .session_state = .{
                .key = gpa.dupe(u8, ss.key) catch continue,
                .state = ss.state,
                .session_id = gpa.dupe(u8, ss.session_id) catch continue,
                .detail = gpa.dupe(u8, ss.detail) catch continue,
            } },
            .focus => |f| .{ .focus = f },
            .goodbye => .goodbye,
            .resize => |r| .{ .resize = r.geometry },
            .input => |in| switch (in.event) {
                .key => |k| .{ .key = gpa.dupe(u8, k.spec) catch continue },
                .paste => |p| .{ .paste = gpa.dupe(u8, p.text) catch continue },
                .click => |c| .{ .click = .{ .col = c.col, .row = c.row, .button = c.button } },
                .scroll => |s| .{ .scroll = .{ .col = s.col, .row = s.row, .dy = s.dy } },
                // A plain move matters now: the pointer resting on a
                // dim `[ Merge ]` is what makes it say why.
                .hover => |h| if (h.dragging) HostEvent{ .drag = .{ .col = h.col, .row = h.row } } else HostEvent{ .hover = .{ .col = h.col, .row = h.row } },
            },
        };
        q.putOneUncancelable(io, .{ .host = ev }) catch return;
        if (ev == .goodbye) return;
    }
}

fn workerThread(gpa: Allocator, io: Io, worker: *fetch.Worker, jobs: *JobQueue, events: *EventQueue) void {
    while (true) {
        const job = jobs.getOneUncancelable(io) catch return;
        defer {
            job.deinit();
            gpa.destroy(job);
        }
        const res = gpa.create(fetch.Result) catch continue;
        res.* = worker.run(job) catch {
            gpa.destroy(res);
            continue;
        };
        events.putOneUncancelable(io, .{ .result = res }) catch {
            res.deinit();
            gpa.destroy(res);
            return;
        };
    }
}

fn tickerThread(io: Io, q: *EventQueue) void {
    while (true) {
        io.sleep(.fromMilliseconds(1000), .awake) catch return;
        q.putOneUncancelable(io, .tick) catch return;
    }
}

fn pane(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, mount: *sdk.Mount, opts: Opts) !u8 {
    var frame = try sdk.Frame.init(gpa, mount.geometry.cols, mount.geometry.rows);
    defer frame.deinit();
    const nerd = mount.hello.capabilities.nerd_font and !mount.hello.capabilities.ascii;

    var only: ?cfg.Family = null;
    var mine = false;
    var awaiting = false;
    if (opts.only) |o| {
        if (std.mem.eql(u8, o, "prs") or std.mem.eql(u8, o, "pull_requests")) {
            only = .prs;
        } else if (std.mem.eql(u8, o, "prs-mine")) {
            only = .prs;
            mine = true;
        } else if (std.mem.eql(u8, o, "prs-awaiting")) {
            // What the `reviews_pending` chip's click opens: the PR
            // family with the awaiting filter already on.
            only = .prs;
            awaiting = true;
        } else if (std.mem.eql(u8, o, "pipelines")) {
            only = .pipelines;
        } else if (std.mem.eql(u8, o, "branches")) {
            only = .branches;
        }
    }
    // The tab says what the manifest installed, not a lower-case
    // shorthand: the label the user saw in INTEGRATIONS, with any
    // qualifier after it. `spec.label` / `spec_pipelines.label` are the
    // manifests themselves, so the two cannot drift.
    const title: []const u8 = if (only) |fam| switch (fam) {
        .prs => if (mine) spec.label ++ " · mine" else if (awaiting) spec.label ++ " · awaiting me" else spec.label,
        .pipelines => spec_pipelines.label,
        .branches => "Bitbucket Branches",
    } else spec.label;
    try mount.setTitle(title);

    var why: []const u8 = "";
    var session = openSession(gpa, io, env, &why) catch |err| {
        return setupLoop(gpa, mount, &frame, if (err == error.NoToken) no_token_text else why, err == error.NoConfig);
    };
    defer session.deinit(gpa);
    session.client.limiter = &session.limiter;
    // Whatever `--prefetch` last left behind answers the startup fetch
    // — each URL once, so the first refresh after it is live.
    var cache = try cache_mod.Cache.init(gpa, io, session.loaded.path, .prime);
    defer cache.deinit();
    session.client.cache = &cache;
    session.client.now_secs = nowSecs(io);

    var app = try app_mod.App.init(gpa, io, session.loaded.config, session.loaded.path, .{ .only = only, .mine = mine, .awaiting = awaiting, .workspace_dir = env.get("MNML_WORKSPACE") orelse mount.hello.workspace });
    defer app.deinit();
    if (app.tabs.len == 0) {
        const msg = try std.fmt.allocPrint(gpa, "--only {s}: no tabs of that family in {s} (check the `tabs` entries and their `kind`)", .{ opts.only orelse "?", session.loaded.path });
        defer gpa.free(msg);
        return setupLoop(gpa, mount, &frame, msg, false);
    }
    app.theme = theme_mod.Theme.fromHello(mount.hello.palette);
    app.cols = frame.cols;
    app.rows = frame.rows;
    app.now_secs = nowSecs(io);

    var progress: fetch.Progress = .{};
    app.progress = &progress;
    var worker = fetch.Worker.init(gpa, io, &session.client, &progress, session.loaded.config.account_id, session.loaded.config.workspace);
    defer worker.deinit();

    var event_buf: [256]Event = undefined;
    var events = EventQueue.init(&event_buf);
    var job_buf: [64]*fetch.Job = undefined;
    var jobs = JobQueue.init(&job_buf);

    var ipc_opt = try sdk.Ipc.fromEnv(gpa, io, env);
    defer if (ipc_opt) |*x| x.deinit();

    const reader = try std.Thread.spawn(.{}, readerThread, .{ gpa, io, mount, &events });
    reader.detach();
    const worker_thread = try std.Thread.spawn(.{}, workerThread, .{ gpa, io, &worker, &jobs, &events });
    worker_thread.detach();
    const ticker = try std.Thread.spawn(.{}, tickerThread, .{ io, &events });
    ticker.detach();

    try app.startup();
    try dispatchJobs(gpa, io, &app, &jobs);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try screen.paint(arena.allocator(), &frame, &app, nerd);
    try mount.send(&frame);

    var running = true;
    while (running) {
        const ev = events.getOneUncancelable(io) catch break;
        switch (ev) {
            .host => |h| switch (h) {
                .key => |k| {
                    defer gpa.free(k);
                    running = try app.keyPress(k);
                },
                .paste => |p| {
                    defer gpa.free(p);
                    try app.paste(p);
                },
                .click => |c| running = try app.click(c.col, c.row, switch (c.button) {
                    .left => .left,
                    .middle => .middle,
                    .right => .right,
                }),
                // A drag along the detail panel's scrollbar: the same
                // jump a press there makes, once per move.
                .drag => |d| try app.drag(d.col, d.row),
                .hover => |hv| app.hover(hv.col, hv.row),
                .session_state => |ss| {
                    defer gpa.free(ss.key);
                    defer gpa.free(ss.session_id);
                    defer gpa.free(ss.detail);
                    try app.onSessionState(ss.key, ss.state, ss.session_id, ss.detail);
                },
                .scroll => |s| try app.wheel(s.col, s.row, s.dy),
                .resize => |g| {
                    try frame.resize(g.cols, g.rows);
                    app.cols = g.cols;
                    app.rows = g.rows;
                },
                .goodbye => running = false,
                .focus => |f| app.focused = f,
                .other => {},
            },
            .result => |r| {
                app.now_secs = nowSecs(io);
                try app.commit(r);
                gpa.destroy(r);
            },
            .tick => try app.tick(nowSecs(io)),
            .host_gone => running = false,
        }
        try dispatchJobs(gpa, io, &app, &jobs);
        running = drain(gpa, io, env, mount, &ipc_opt, &app) and running;
        _ = arena.reset(.retain_capacity);
        try screen.paint(arena.allocator(), &frame, &app, nerd);
        try mount.send(&frame);
    }
    events.close(io);
    jobs.close(io);
    mount.bye();
    // The reader and the worker are detached and may be blocked on the
    // socket or the network; the process exit ends them.
    return 0;
}

fn dispatchJobs(gpa: Allocator, io: Io, app: *app_mod.App, jobs: *JobQueue) Allocator.Error!void {
    const taken = app.takeJobs();
    defer gpa.free(taken);
    for (taken) |job| {
        const boxed = try gpa.create(fetch.Job);
        boxed.* = job;
        jobs.putOneUncancelable(io, boxed) catch {
            boxed.deinit();
            gpa.destroy(boxed);
        };
    }
}

/// Run what the last event queued: toasts over the mount, the browser
/// and the clipboard through the machine, the chip over the file
/// channel. False when the app asked to quit.
fn drain(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, mount: *sdk.Mount, ipc_opt: *?sdk.Ipc, app: *app_mod.App) bool {
    var alive = true;
    // The sessions this pane just started and wants told about. They
    // go out before the effects that started them are freed.
    for (app.watch_out.items) |w| {
        mount.watchSession(w.key, .{ .cwd = w.cwd, .prompt_line = w.prompt_line }) catch {};
    }
    app.watch_out.clearRetainingCapacity();
    const taken = app.takeEffects();
    defer app.freeEffects(taken);
    for (taken) |e| switch (e) {
        .toast => |x| mount.toast(switch (x.level) {
            .info => .info,
            .warn => .warn,
            .err => .@"error",
        }, x.text) catch {},
        .open_url => |url| {
            if (os.openUrl(gpa, io, url)) |whynot| mount.toast(.warn, whynot) catch {};
        },
        .copy => |text| {
            if (os.copy(gpa, io, env, text)) |whynot| mount.toast(.warn, whynot) catch {};
        },
        .segment => if (ipc_opt.*) |*ipc| {
            if (app.values) |v| {
                var arena_state = std.heap.ArenaAllocator.init(gpa);
                defer arena_state.deinit();
                // All three chips, the way `--values` publishes them.
                // Only the first used to move from inside the pane, so
                // the other two sat at whatever the last poll left.
                publishSegments(ipc, arena_state.allocator(), v) catch {};
            }
        },
        // The one destructive action either pane offers goes through a
        // Claude Code session, so it is a `term` line like any other
        // dispatch — and the pane then watches what it does.
        .dispatch => |d| {
            if (ipc_opt.*) |*ipc| {
                dispatchSession(gpa, ipc, d.prompt) catch {
                    mount.toast(.warn, "could not write the dispatch") catch {};
                };
            } else mount.toast(.warn, "no mnml channel to dispatch a session on") catch {};
        },
        .focus_session => |f| if (ipc_opt.*) |*ipc| {
            ipc.focusSession(.{ .id = f.id, .cwd = f.cwd, .prompt_line = f.prompt_line }) catch {};
        },
        .notify => |n| if (ipc_opt.*) |*ipc| {
            ipc.notify(n.title, n.text, if (n.bad) .@"error" else .info, n.bad) catch {};
        },
        .quit => alive = false,
    };
    return alive;
}

/// One `term` line: `claude` seeded with the prompt over a heredoc,
/// the same shape the tracker's dispatch queue writes.
fn dispatchSession(gpa: Allocator, ipc: *const sdk.Ipc, prompt: []const u8) !void {
    const shell = try std.fmt.allocPrint(gpa, "claude <<'MNML_EOF'\n{s}\nMNML_EOF", .{prompt});
    defer gpa.free(shell);
    const argv = [_][]const u8{ "sh", "-c", shell };
    try ipc.line(.{ .cmd = "term", .args = &argv });
}

/// A pane with no config or no token paints the setup screen and
/// waits for `q`.
fn setupLoop(gpa: Allocator, mount: *sdk.Mount, frame: *sdk.Frame, why: []const u8, scaffolded: bool) !u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const th = theme_mod.Theme.fromHello(mount.hello.palette);
    paintSetup(frame, th, why, scaffolded);
    try mount.send(frame);
    while (true) {
        _ = arena.reset(.retain_capacity);
        const msg = (try mount.next(arena.allocator())) orelse break;
        switch (msg) {
            .goodbye => break,
            .resize => |r| {
                try frame.resize(r.geometry.cols, r.geometry.rows);
                paintSetup(frame, th, why, scaffolded);
                try mount.send(frame);
            },
            .input => |in| switch (in.event) {
                .key => |k| if (std.mem.eql(u8, k.spec, "q") or std.mem.eql(u8, k.spec, "esc")) break,
                else => {},
            },
            else => {},
        }
    }
    mount.bye();
    return 0;
}

fn paintSetup(f: *sdk.Frame, th: theme_mod.Theme, why: []const u8, scaffolded: bool) void {
    f.clear(.{ .fg = th.fg, .bg = th.bg });
    _ = f.text(1, 0, f.cols -| 1, "BITBUCKET — setup", th.label());
    _ = f.text(1, 2, f.cols -| 1, if (scaffolded) "wrote the config scaffold — edit config.zon, then reopen the pane:" else "the pane cannot start:", th.text());
    _ = f.text(3, 3, f.cols -| 3, why, th.warn());
    _ = f.text(1, 5, f.cols -| 1, "1. edit config.zon: set `email`, `workspace` and `repos`", th.text());
    _ = f.text(1, 6, f.cols -| 1, "2. export BITBUCKET_API_TOKEN (or write it to <config dir>/token)", th.text());
    _ = f.text(1, 7, f.cols -| 1, "3. mnml-bitbucket --check", th.text());
    _ = f.text(1, f.rows -| 1, f.cols -| 1, "q closes", th.mutedText());
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test {
    _ = @import("src/dates.zig");
    _ = @import("src/json.zig");
    _ = @import("src/os.zig");
    _ = @import("src/ratelimit.zig");
    _ = @import("src/config.zig");
    _ = @import("src/auth.zig");
    _ = @import("src/model.zig");
    _ = @import("src/api.zig");
    _ = @import("src/tabs.zig");
    _ = @import("src/keymap.zig");
    _ = @import("src/hit.zig");
    _ = @import("src/theme.zig");
    _ = @import("src/fetch.zig");
    _ = @import("src/app.zig");
    _ = @import("src/view.zig");
    _ = @import("src/screen.zig");
}

test "both manifests name the reference's ids, chips and commands, and validate" {
    try t.expectEqualStrings("bitbucket_prs", spec.id);
    try t.expectEqualStrings("bitbucket_pipelines", spec_pipelines.id);
    try t.expectEqualStrings("mnml-bitbucket", spec.binary);
    try t.expectEqualStrings("bitbucket_prs.open", spec.commands[0].id);
    try t.expectEqualStrings("bitbucket_prs.open_mine", spec.commands[1].id);
    try t.expectEqualStrings("bitbucket_prs.open_awaiting", spec.commands[2].id);
    try t.expectEqualStrings("bitbucket_pipelines.open", spec_pipelines.commands[0].id);
    try t.expectEqualStrings("BP", spec.chip.?.fallback);
    try t.expectEqualStrings("BL", spec_pipelines.chip.?.fallback);
    // Three chips, three questions: how many of mine are open, how
    // many threads on them are waiting on a human, and how many are
    // waiting on ME. The ids the binary publishes on are the
    // manifest's slots prefixed with the manifest id — a mismatch is a
    // chip that never moves, and only running it would show that.
    try t.expectEqual(@as(usize, 3), spec.statusline.len);
    try t.expectEqualStrings("prs_mine", spec.statusline[0].id);
    try t.expectEqualStrings("reviews_mine", spec.statusline[1].id);
    try t.expectEqualStrings("reviews_pending", spec.statusline[2].id);
    for (spec.statusline) |seg| try t.expect(seg.tooltip != null);
    try t.expectEqualStrings(segment_id, spec.id ++ "." ++ "prs_mine");
    try t.expectEqualStrings(review_segment_id, spec.id ++ "." ++ "reviews_mine");
    try t.expectEqualStrings(awaiting_segment_id, spec.id ++ "." ++ "reviews_pending");
    try t.expectEqualStrings(segment_click, spec.statusline[0].click_command.?);
    // The third chip's click must name a command the manifest has —
    // a chip that opens nothing is a chip nobody can tell is broken.
    try t.expectEqualStrings(awaiting_segment_click, spec.statusline[2].click_command.?);
    var found_click = false;
    for (spec.commands) |c| if (std.mem.eql(u8, c.id, awaiting_segment_click)) {
        found_click = true;
    };
    try t.expect(found_click);
    try t.expectEqual(@as(usize, 3), spec.auth.len);
    var why: []const u8 = "";
    try sdk.manifest.validate(spec, &why);
    try sdk.manifest.validate(spec_pipelines, &why);
    for ([_]sdk.Manifest{ spec, spec_pipelines }) |m| {
        const text = try sdk.manifest.render(t.allocator, m);
        defer t.allocator.free(text);
        var arena_state = std.heap.ArenaAllocator.init(t.allocator);
        defer arena_state.deinit();
        const z = try arena_state.allocator().dupeZ(u8, text);
        const back = try std.zon.parse.fromSliceAlloc(sdk.Manifest, arena_state.allocator(), z, null, .{ .free_on_error = false });
        try t.expectEqualStrings(m.id, back.id);
    }
}

test "the chip's Tier-2 lines are the exact JSON mnml reads: the segment and the badge" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var ipc = try sdk.Ipc.init(t.allocator, t.io, dir);
    defer ipc.deinit();
    try publishSegment(&ipc, .{ .open_mine = 4, .unapproved_mine = 2, .approved_mine = 2 });
    try publishSegment(&ipc, .{ .error_text = "HTTP 401: auth" });
    const got = try tmp.dir.readFileAlloc(t.io, "command", t.allocator, .unlimited);
    defer t.allocator.free(got);
    try t.expectEqualStrings(
        "{\"cmd\":\"statusline-set-segment\",\"id\":\"bitbucket_prs.prs_mine\",\"side\":\"right\",\"text\":\"\u{f00a8} 4(2)\",\"color\":\"green\",\"click_command\":\"bitbucket_prs.open_mine\",\"priority\":60,\"min_width\":4,\"max_width\":30}\n" ++
            "{\"cmd\":\"set-activity-badge\",\"section\":\"integrations\",\"count\":4}\n" ++
            "{\"cmd\":\"statusline-set-segment\",\"id\":\"bitbucket_prs.prs_mine\",\"side\":\"right\",\"text\":\"\u{f00a8} !\",\"color\":\"red\",\"click_command\":\"bitbucket_prs.open_mine\",\"priority\":60,\"min_width\":4,\"max_width\":30}\n" ++
            "{\"cmd\":\"set-activity-badge\",\"section\":\"integrations\",\"count\":0}\n",
        got,
    );
}

test "the three chips carry their counts, what they mean and WHICH; the review chip is absent when it was not counted" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var ipc = try sdk.Ipc.init(t.allocator, t.io, dir);
    defer ipc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Counted: all three chips, each with the sentence behind its
    // number and the top three names behind the sentence.
    try publishSegments(&ipc, arena, .{
        .open_mine = 4,
        .unapproved_mine = 2,
        .approved_mine = 2,
        .reviews_pending = 2,
        .unresolved_comments = 3,
        .comment_hits = 3,
        .comment_requests = 1,
        .open_titles = &.{ "Fix the login redirect", "Redesign the empty state" },
        .comment_titles = &.{"Fix the login redirect"},
        .awaiting_titles = &.{ "Bump the client timeout to 30s", "Tidy the footer links" },
    });
    var got = try tmp.dir.readFileAlloc(t.io, "command", arena, .unlimited);
    try t.expect(std.mem.indexOf(u8, got, "\"id\":\"bitbucket_prs.prs_mine\"") != null);
    try t.expect(std.mem.indexOf(u8, got, "4 open pull requests you authored — 2 still unapproved, 2 approved") != null);
    try t.expect(std.mem.indexOf(u8, got, "\"id\":\"bitbucket_prs.reviews_mine\"") != null);
    try t.expect(std.mem.indexOf(u8, got, review_segment_glyph ++ " 3") != null);
    try t.expect(std.mem.indexOf(u8, got, "3 review threads across your open pull requests still waiting on someone") != null);
    // What it cost is part of the sentence: the reader is the one
    // paying the rate limit.
    try t.expect(std.mem.indexOf(u8, got, "3 of 4 counted off the cache") != null);
    // The third chip, and the names behind each of the three. A count
    // on its own sends the reader into the pane to find out which.
    try t.expect(std.mem.indexOf(u8, got, "\"id\":\"bitbucket_prs.reviews_pending\"") != null);
    try t.expect(std.mem.indexOf(u8, got, awaiting_segment_glyph ++ " 2") != null);
    try t.expect(std.mem.indexOf(u8, got, "2 open pull requests waiting on YOUR review") != null);
    try t.expect(std.mem.indexOf(u8, got, "\u{201c}Bump the client timeout to 30s\u{201d}, \u{201c}Tidy the footer links\u{201d}") != null);
    try t.expect(std.mem.indexOf(u8, got, "2 approved \u{2014} \u{201c}Fix the login redirect\u{201d}, \u{201c}Redesign the empty state\u{201d}") != null);
    try t.expect(std.mem.indexOf(u8, got, "counted off the cache \u{2014} \u{201c}Fix the login redirect\u{201d}") != null);

    // Not counted: the second chip is not published at all. A zero
    // there would read as "nothing outstanding".
    try tmp.dir.writeFile(t.io, .{ .sub_path = "command", .data = "" });
    try publishSegments(&ipc, arena, .{ .open_mine = 1, .unapproved_mine = 0, .approved_mine = 1 });
    got = try tmp.dir.readFileAlloc(t.io, "command", arena, .unlimited);
    try t.expect(std.mem.indexOf(u8, got, "bitbucket_prs.reviews_mine") == null);
    // One reads as one, and a figure with no names behind it simply
    // says the number rather than trailing an empty dash.
    try t.expect(std.mem.indexOf(u8, got, "1 open pull request you authored") != null);
    try t.expect(std.mem.indexOf(u8, got, "1 approved\"") != null);
    // The awaiting chip is always published, zero included: it is a
    // "nothing is waiting on you" that the reader can trust.
    try t.expect(std.mem.indexOf(u8, got, "bitbucket_prs.reviews_pending") != null);
    try t.expect(std.mem.indexOf(u8, got, "0 open pull requests waiting on YOUR review") != null);

    // A failure says so on the chip it belongs to.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "command", .data = "" });
    try publishSegments(&ipc, arena, .{ .error_text = "HTTP 401: auth" });
    got = try tmp.dir.readFileAlloc(t.io, "command", arena, .unlimited);
    try t.expect(std.mem.indexOf(u8, got, "Bitbucket: HTTP 401: auth") != null);
}

test "--only spells the reference's families; the last one wins; an unknown flag is refused" {
    const o = try parseArgs(&.{ "mnml-bitbucket", "--only", "prs", "--only", "prs-mine" });
    try t.expectEqualStrings("prs-mine", o.only.?);
    try t.expectEqualStrings("prs-awaiting", (try parseArgs(&.{ "mnml-bitbucket", "--only", "prs-awaiting" })).only.?);
    const f = try parseArgs(&.{ "mnml-bitbucket", "--find-pipeline-for-pr", "--owner", "acme", "--repo", "api", "--branch", "main", "--json" });
    try t.expect(f.find_pipeline and f.json);
    try t.expectEqualStrings("main", f.branch);
    try t.expectError(error.UnknownArgument, parseArgs(&.{ "mnml-bitbucket", "--nope" }));
}
