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

/// The manifest chip colour of the family a pane was opened on — the
/// pane's brand, which the gutter stripe and the tab indicator paint
/// in. The pane used to take `fromHello`, so its "app colour" was the
/// host theme's accent and every integration mounted in mnml wore the
/// same stripe; the tracker pane has always taken its own.
pub fn chipColorOf(family: ?cfg.Family) []const u8 {
    const m: sdk.Manifest = switch (family orelse .prs) {
        .pipelines => spec_pipelines,
        .prs, .branches => spec,
    };
    return if (m.chip) |c| c.color else "";
}

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
/// `RT`, review threads: the two-cell twin for a terminal with no
/// Nerd Font, so the figure beside it keeps its place.
pub const review_segment_ascii = "RT";
pub const review_segment_color = "yellow";

/// The third figure: open pull requests waiting on YOUR review. Its own
/// chip again, because it is the one of the three that is your move.
pub const awaiting_segment_id = "bitbucket_prs.reviews_pending";
pub const awaiting_segment_glyph = "\u{f0e5}"; // nf-fa-comment_o
/// `RV`, reviews waiting on you — the twin of the hollow comment.
pub const awaiting_segment_ascii = "RV";
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
    /// `--focus <repo>#<id>`: the pull request to land the cursor on
    /// once the first listing is in — what a row of the statusline
    /// figure's hover asks for. Empty is "wherever the cursor lands".
    focus: []const u8 = "",
    /// `--dump --steps FILE [--size WxH]`: the headless driver — the
    /// same App and the same paint as the pane, driven by a step
    /// script, with every `snap` printed as text. `--dump-style` adds
    /// each snap's row backgrounds and foregrounds, which the text
    /// cannot carry.
    dump: bool = false,
    dump_style: bool = false,
    steps: ?[]const u8 = null,
    size: ?[]const u8 = null,
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
        } else if (std.mem.eql(u8, a, "--dump")) {
            o.dump = true;
        } else if (std.mem.eql(u8, a, "--dump-style")) {
            o.dump = true;
            o.dump_style = true;
        } else if (std.mem.eql(u8, a, "--steps") and i + 1 < args.len) {
            i += 1;
            o.steps = args[i];
        } else if (std.mem.eql(u8, a, "--size") and i + 1 < args.len) {
            i += 1;
            o.size = args[i];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            o.help = true;
        } else if (std.mem.eql(u8, a, "--only") and i + 1 < args.len) {
            i += 1;
            o.only = args[i];
        } else if (std.mem.eql(u8, a, "--focus") and i + 1 < args.len and args[i + 1].len > 0) {
            i += 1;
            o.focus = args[i];
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
    if (opts.dump) return dumpCmd(gpa, io, env, arena, stdout, stderr, opts);

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
    \\  --dump --steps FILE [--size WxH] [--only F]
    \\                           play a step script at the pane with no mnml and
    \\                           print every `snap` as text
    \\  --dump-style             the same, plus each snap's row backgrounds and
    \\                           foregrounds, run-length coded
    \\                           (`bg  6: 0-119 #31353d`, `fg  6: 0-7 #61afef+b`)
    \\  --prefetch                warm the pane's cache; 0 complete, 2 partial, 1 could not run
    \\  --only prs|prs-mine|prs-awaiting|pipelines|branches   one family of tabs
    \\  --focus REPO#ID          land the cursor on that pull request once the
    \\                           listing is in, and open its detail
    \\
;

// ─── install ─────────────────────────────────────────────────────────────

fn install(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The pull-request links' workspace and repos: this config's, when
    // it has them — mnml cannot read config.zon, so the manifest
    // carries them.
    const prs = if (installConfig(arena, io, env)) |c| try linkSpec(arena, spec, c.workspace, try linkedRepos(arena, c)) else spec;
    for ([_]sdk.Manifest{ prs, spec_pipelines }) |m| {
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

/// config.zon as it is, without the scaffold a first `load` writes;
/// null when there is none yet or it does not parse.
fn installConfig(arena: Allocator, io: Io, env: *const std.process.Environ.Map) ?cfg.Config {
    const p = cfg.configPath(arena, env) catch return null;
    const text = Io.Dir.cwd().readFileAllocOptions(io, p, arena, .unlimited, .of(u8), 0) catch return null;
    return cfg.parseText(arena, text) catch null;
}

/// The repos a pull-request link may name: the config's `repos`, and
/// its `explicit_repos` under `scope = .explicit`, less the hidden.
/// Empty: any repo.
pub fn linkedRepos(arena: Allocator, c: cfg.Config) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const lists = [_][]const []const u8{ c.repos, if (c.scope == .explicit) c.explicit_repos else &.{} };
    for (lists) |list| for (list) |r| {
        if (r.len == 0 or c.isHidden(r) or cfg.contains(out.items, r)) continue;
        try out.append(arena, r);
    };
    return out.items;
}

/// `m`'s pull-request links for `workspace`: `<repo>#<n>` with the
/// workspace written in, `<repo>` narrowed to `repos` when it names
/// any, and `<workspace>/<repo>#<n>` beside it. An empty workspace
/// leaves `m` as declared, for mnml to bind from $BITBUCKET_WORKSPACE.
pub fn linkSpec(arena: Allocator, m: sdk.Manifest, workspace: []const u8, repos: []const []const u8) Allocator.Error!sdk.Manifest {
    const ws = std.mem.trim(u8, workspace, " /");
    if (ws.len == 0) return m;
    const slug = if (repos.len == 0) "[A-Za-z0-9_.-]+" else blk: {
        var alt: std.ArrayListUnmanaged(u8) = .empty;
        for (repos, 0..) |r, i| {
            if (i > 0) try alt.append(arena, '|');
            try appendEscaped(arena, &alt, r);
        }
        break :blk alt.items;
    };
    var ws_re: std.ArrayListUnmanaged(u8) = .empty;
    try appendEscaped(arena, &ws_re, ws);
    const links = try arena.alloc(sdk.manifest.Link, 2);
    links[0] = .{
        .pattern = try std.fmt.allocPrint(arena, "(?<![/\\w.-])({s})/({s})#(\\d+)", .{ ws_re.items, slug }),
        .url = "https://bitbucket.org/{1}/{2}/pull-requests/{3}",
    };
    links[1] = .{
        .pattern = try std.fmt.allocPrint(arena, "(?<![/\\w.-])({s})#(\\d+)", .{slug}),
        .url = try sdk.manifest.bindLinkVar(arena, "https://bitbucket.org/{workspace}/{1}/pull-requests/{2}", "workspace", ws),
    };
    var copy = m;
    copy.links = links;
    return copy;
}

/// `s` as a regex literal: every byte but a letter, digit or `_` escaped.
fn appendEscaped(arena: Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) Allocator.Error!void {
    for (s) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) try out.append(arena, '\\');
        try out.append(arena, ch);
    }
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
    /// Where every request this run makes is written down. Held by the
    /// session so it outlives the client that points at it.
    log: sdk.RequestLog,
    client: api.Client,
    base_url: []u8,

    fn deinit(s: *Session, gpa: Allocator) void {
        s.client.deinit();
        s.log.deinit();
        s.limiter.deinit();
        s.tokens.deinit();
        s.loaded.deinit();
        gpa.free(s.base_url);
    }
};

const SessionError = error{ NoConfig, NoToken, BaseUrl } || Allocator.Error;

/// Load everything a command needs; `why` explains a refusal.
fn openSession(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, why: *[]const u8) SessionError!Session {
    var loaded = cfg.load(gpa, io, env, why) catch return error.NoConfig;
    errdefer loaded.deinit();
    // First, before a token is even looked for: a broken override is
    // the one failure that must stop everything that follows.
    const base_url = try resolveBaseUrl(gpa, io, env, loaded.config, why);
    errdefer gpa.free(base_url);
    const config_dir = std.fs.path.dirname(loaded.path) orelse ".";
    var tokens = try auth.resolve(gpa, io, env, config_dir);
    errdefer tokens.deinit();
    if (!tokens.hasRead()) {
        why.* = no_token_text;
        return error.NoToken;
    }
    const state_path = if (loaded.config.rate.state_path.len > 0) try gpa.dupe(u8, loaded.config.rate.state_path) else try ratelimit.statePath(gpa, io, env);
    defer gpa.free(state_path);
    var limiter = try ratelimit.Limiter.init(gpa, io, state_path, .{ .rate = loaded.config.rate.rate_per_sec, .capacity = loaded.config.rate.capacity });
    errdefer limiter.deinit();
    // So every draw on the shared bucket says who took it. Without
    // this the bucket says only how much is left, which is the half of
    // the answer that does not help.
    try limiter.identify(ratelimit.service, "mnml-bitbucket", sdk.warm.selfPid());
    // And the broker, when mnml hosts one: a limiter built on the
    // pane's own path (`.rate.state_path`) never asked it before.
    try limiter.attachBroker(env, ratelimit.service);
    var log = try sdk.RequestLog.open(gpa, io, env, ratelimit.service, "mnml-bitbucket");
    errdefer log.deinit();
    var client = try api.Client.init(gpa, io, base_url, loaded.config.email, tokens.read, if (tokens.write_source == .env) tokens.write else "", loaded.config.rate);
    errdefer client.deinit();
    return .{ .loaded = loaded, .tokens = tokens, .limiter = limiter, .log = log, .client = client, .base_url = base_url };
}

/// `$BITBUCKET_BASE_URL` — literally, or `@<path>` naming a file that
/// holds it (the fake server writes its port there) — then the
/// config's, then the real API.
/// Bodies already held, filed under the server's own `ETag`
/// (`mnml_sdk.store`). Shared between every process on the machine
/// because it lives under the data root, which is the point: a second
/// pane's first ask is conditional too.
fn openEtagStore(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) Allocator.Error!sdk.Store {
    const root = try sdk.request_log.dataRoot(gpa, env);
    defer gpa.free(root);
    return sdk.Store.open(gpa, io, root, ratelimit.service, "etags");
}

/// `$BITBUCKET_BASE_URL` (`sdk.base_url`: literally, or `@<path>`
/// naming the file the fake server writes its port to), then the
/// config's, then the real API. An `@<path>` whose file never arrives
/// is `error.BaseUrl` with the reason in `why` — the fake did not start,
/// and the answer to that is no server, never api.bitbucket.org.
fn resolveBaseUrl(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, c: cfg.Config, why: *[]const u8) (error{BaseUrl} || Allocator.Error)![]u8 {
    switch (try sdk.base_url.fromEnv(gpa, io, env, base_url_env, .{ .wait_ms = url_file_wait_ms })) {
        .url => |u| return u,
        .unreadable => |msg| {
            // `why` outlives this call on every path that reads it (the
            // setup screen, `--check`'s one line), so it is copied out
            // to a buffer the process owns.
            defer gpa.free(msg);
            const n = @min(msg.len, base_url_why.len);
            @memcpy(base_url_why[0..n], msg[0..n]);
            why.* = base_url_why[0..n];
            return error.BaseUrl;
        },
        .unset => {},
    }
    if (c.base_url.len > 0) return gpa.dupe(u8, c.base_url);
    return gpa.dupe(u8, api.default_base_url);
}

const base_url_env = "BITBUCKET_BASE_URL";
var base_url_why: [1024]u8 = undefined;
/// How long a missing `@<path>` is waited for: the fake writes it once
/// it listens. A test that proves the refusal does not sit out 5 s.
const url_file_wait_ms: u32 = if (@import("builtin").is_test) 50 else 5000;

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
    s.client.log = &s.log;
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
    s.client.log = &s.log;
    // Under a quarter of the shared bucket, a poll is the thing that
    // gives way: nothing is watching this run, and what is left
    // belongs to whoever is. The line says so rather than leaving a
    // chip that stopped moving unexplained.
    if (sdk.warm.underBudget(s.limiter.status())) {
        try err.print("mnml-bitbucket --values: {s}\n", .{sdk.warm.skipped_budget});
        try out.print("{{\"skipped\":\"{s}\"}}\n", .{sdk.warm.skipped_budget});
        return 0;
    }
    var gate: sdk.warm.Gate = .forConfig(.{ .rate = s.loaded.config.rate.rate_per_sec, .capacity = s.loaded.config.rate.capacity });
    s.client.gate = &gate;
    var etags = try openEtagStore(gpa, io, env);
    defer {
        etags.save();
        etags.deinit();
    }
    s.client.etags = &etags;
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
    var bucket_name: [64]u8 = undefined;
    if (ipc) |*x| publishSegments(x, arena_state.allocator(), v, bucketOf(gpa, io, &s.limiter, &bucket_name), Mark.fromEnv(env)) catch {};
    if (v.error_text.len > 0) {
        try err.print("mnml-bitbucket --values: {s}\n", .{v.error_text});
        return 1;
    }
    try out.print("{{\"open_mine\":{d},\"unapproved_mine\":{d},\"approved_mine\":{d},\"reviews_pending\":{d},\"unresolved_comments\":", .{ v.open_mine, v.unapproved_mine, v.approved_mine, v.reviews_pending });
    if (v.unresolved_comments) |n| try out.print("{d}", .{n}) else try out.writeAll("null");
    try out.writeAll("}\n");
    return 0;
}

/// What the PRs figure wears: the chip's mark — the host's, through
/// `$MNML_CHIP_GLYPH`, else the manifest's own — or its plain twin.
pub const Mark = struct {
    ascii: bool = false,
    glyph: []const u8 = app_mod.App.chip_glyph,

    pub fn fromEnv(env: *const std.process.Environ.Map) Mark {
        return .{ .ascii = sdk.pane.asciiFromEnv(env), .glyph = sdk.pane.chipGlyphFromEnv(env, app_mod.App.chip_glyph) };
    }

    pub fn of(app: *const app_mod.App) Mark {
        return .{ .ascii = app.ascii, .glyph = app.chip_mark };
    }

    pub fn chip(m: Mark) []const u8 {
        return if (m.ascii) app_mod.App.chip_ascii else m.glyph;
    }
};

/// The chip's text for a values result: the chip's mark and `4(2)`, or `!` on a failure.
///
/// Through `sdk.pane.figure` because the shape is the family's, not
/// this pane's: the figure is the pull requests of mine that are open,
/// and the bracket is the SUBSET of them nobody has approved yet. A
/// pane with no such subset publishes the figure alone.
pub fn segmentText(buf: []u8, v: fetch.ValuesResult, mark: Mark) []const u8 {
    const g = mark.chip();
    if (v.error_text.len > 0) return std.fmt.bufPrint(buf, "{s} !", .{g}) catch g;
    return sdk.pane.figure.text(buf, .{ .glyph = g, .n = v.open_mine, .subset = v.unapproved_mine });
}

/// The review chip's text: `󰅺 3`, the threads still waiting on someone.
pub fn reviewText(buf: []u8, unresolved: usize, ascii: bool) []const u8 {
    return sdk.pane.figure.text(buf, .{ .glyph = if (ascii) review_segment_ascii else review_segment_glyph, .n = unresolved });
}

/// The awaiting chip's text: ` 2`, the pull requests waiting on you.
pub fn awaitingText(buf: []u8, n: usize, ascii: bool) []const u8 {
    return sdk.pane.figure.text(buf, .{ .glyph = if (ascii) awaiting_segment_ascii else awaiting_segment_glyph, .n = n });
}

/// ` — “Fix the login redirect”, “Bump the client timeout”`, or nothing
/// when there are no titles. A count alone sends the reader into the
/// pane to find out WHICH; the names answer it under the pointer.
pub fn titleTail(arena: Allocator, items: []const fetch.ValuesItem) Allocator.Error![]const u8 {
    if (items.len == 0) return "";
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll(" \u{2014} ") catch return error.OutOfMemory;
    for (items[0..@min(items.len, fetch.tooltip_titles)], 0..) |it, i| {
        if (i > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.print("\u{201c}{s}\u{201d}", .{it.text}) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// The rows the statusline hover lists for a figure: the pull requests
/// themselves, each a click away from the pane that holds it. Built
/// from what the values run already has — no second request pays for
/// the hover.
pub fn hoverItems(arena: Allocator, items: []const fetch.ValuesItem, click: []const u8) Allocator.Error![]const sdk.ipc.Item {
    if (items.len == 0) return &.{};
    const out = try arena.alloc(sdk.ipc.Item, items.len);
    // // changed (focus-row): `args` is the row's deep link. The host
    // appends them to the command's argv when it mounts the pane, and
    // hands them down the mount as a `focus_item` when the pane is
    // already open — either way the cursor ends on THIS pull request.
    for (items, 0..) |it, i| out[i] = .{ .text = it.text, .sub = it.sub, .command = click, .args = try focusArgs(arena, it.key) };
    return out;
}

/// `--focus <key>` as a two-element argv, or nothing for a row that
/// names no pull request.
pub fn focusArgs(arena: Allocator, key: []const u8) Allocator.Error![]const []const u8 {
    if (key.len == 0) return &.{};
    const out = try arena.alloc([]const u8, 2);
    out[0] = "--focus";
    out[1] = key;
    return out;
}

/// What the PR chip means, on hover. A number with no sentence behind
/// it makes the reader guess, and these two are easy to mix up.
pub fn segmentTooltip(arena: Allocator, v: fetch.ValuesResult) Allocator.Error![]const u8 {
    if (v.error_text.len > 0) return std.fmt.allocPrint(arena, "Bitbucket: {s}", .{v.error_text});
    return std.fmt.allocPrint(
        arena,
        "Bitbucket · {d} open pull request{s} you authored — {d} still unapproved, {d} approved{s}",
        .{ v.open_mine, if (v.open_mine == 1) "" else "s", v.unapproved_mine, v.approved_mine, try titleTail(arena, v.open_items) },
    );
}

/// What the review chip means, and what it cost: a reader who is
/// rate-limit-shy wants to know how much of the bucket a poll spends.
pub fn reviewTooltip(arena: Allocator, v: fetch.ValuesResult, unresolved: usize) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "Bitbucket · {d} review thread{s} across your open pull requests still waiting on someone (neither resolved nor replied to) — {d} of {d} counted off the cache{s}",
        .{ unresolved, if (unresolved == 1) "" else "s", v.comment_hits, v.comment_hits + v.comment_requests, try titleTail(arena, v.comment_items) },
    );
}

/// What the awaiting chip means: the pull requests you are a reviewer
/// on and have not voted.
pub fn awaitingTooltip(arena: Allocator, v: fetch.ValuesResult) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "Bitbucket · {d} open pull request{s} waiting on YOUR review — you are a reviewer and have not approved{s}",
        .{ v.reviews_pending, if (v.reviews_pending == 1) "" else "s", try titleTail(arena, v.awaiting_items) },
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
pub fn publishSegments(ipc: *const sdk.Ipc, arena: Allocator, v: fetch.ValuesResult, bucket: ?Bucket, mark: Mark) !void {
    var buf: [64]u8 = undefined;
    try ipc.statuslineSetSegment(.{
        .id = segment_id,
        .text = segmentText(&buf, v, mark),
        .color = if (v.error_text.len > 0) "red" else segment_color,
        .click_command = segment_click,
        .priority = 60,
        .tooltip = try withBucket(arena, try segmentTooltip(arena, v), bucket),
        .items = try hoverItems(arena, v.open_items, segment_click),
    });
    if (v.unresolved_comments) |n| {
        var rbuf: [64]u8 = undefined;
        try ipc.statuslineSetSegment(.{
            .id = review_segment_id,
            .text = reviewText(&rbuf, n, mark.ascii),
            .color = if (n > 0) review_segment_color else "green",
            .click_command = segment_click,
            .priority = 59,
            .tooltip = try withBucket(arena, try reviewTooltip(arena, v, n), bucket),
            .items = try hoverItems(arena, v.comment_items, segment_click),
        });
    }
    var abuf: [64]u8 = undefined;
    try ipc.statuslineSetSegment(.{
        .id = awaiting_segment_id,
        .text = awaitingText(&abuf, v.reviews_pending, mark.ascii),
        .color = if (v.reviews_pending > 0) awaiting_segment_color else "green",
        .click_command = awaiting_segment_click,
        .priority = 58,
        .tooltip = try withBucket(arena, try awaitingTooltip(arena, v), bucket),
        .items = try hoverItems(arena, v.awaiting_items, awaiting_segment_click),
    });
    try ipc.setActivityBadge("integrations", @intCast(@min(v.open_mine, std.math.maxInt(u32))));
}

/// The hover text with the shared bucket's own line under it: tokens,
/// rate, throttles, how long since the last 429. It is the answer to
/// "why is this chip stale", and it is one hover away.
fn withBucket(arena: Allocator, body: []const u8, bucket: ?Bucket) Allocator.Error![]const u8 {
    const b = bucket orelse return body;
    var buf: [192]u8 = undefined;
    const line = b.status.describe(&buf);
    const d = b.draws orelse return std.fmt.allocPrint(arena, "{s}\n{s}", .{ body, line });
    var dbuf: [96]u8 = undefined;
    return std.fmt.allocPrint(arena, "{s}\n{s}\nspent by {s}", .{ body, line, d.describe(&dbuf, draws_window_secs) });
}

/// What the hover says about the shared bucket: its state, and who has
/// been drawing on it lately.
pub const Bucket = struct {
    status: ratelimit.Status,
    draws: ?ratelimit.Draws = null,
};

/// The window the "spent by" line covers: long enough that a quiet
/// minute does not read as nobody spending, short enough to be about
/// now.
pub const draws_window_secs: u32 = 600;

/// The bucket as the hover wants it — its state, and the top consumer
/// of the last ten minutes read out of the machine-wide draws file.
/// `name_buf` holds the program name the result points at.
fn bucketOf(gpa: Allocator, io: Io, l: *ratelimit.Limiter, name_buf: []u8) ?Bucket {
    const st = l.status() orelse return null;
    const path = (l.drawsPath(gpa) catch null) orelse return .{ .status = st };
    defer gpa.free(path);
    const now: f64 = @as(f64, @floatFromInt(Io.Timestamp.now(io, .real).toNanoseconds())) / 1_000_000_000.0;
    return .{ .status = st, .draws = ratelimit.recentDraws(gpa, io, path, draws_window_secs, now, name_buf) };
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
    s.client.log = &s.log;
    var rc = try review_cache.Cache.open(gpa, io, s.loaded.path);
    defer rc.deinit();
    var res = try computeValues(gpa, io, &s, &rc);
    defer res.deinit();
    const v = res.payload.values;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var ipc = try ipcFor(gpa, io, env, workspace);
    defer if (ipc) |*x| x.deinit();
    var bucket_name: [64]u8 = undefined;
    if (ipc) |*x| publishSegments(x, arena_state.allocator(), v, bucketOf(gpa, io, &s.limiter, &bucket_name), Mark.fromEnv(env)) catch {};
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
    s.client.log = &s.log;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    try out.writeAll("{\"host\":\"bitbucket\",\"prs\":[");
    var n: usize = 0;
    for (s.loaded.config.tabs) |tab| {
        if (tab.kind != .pull_requests or tab.repo.len == 0) continue;
        const ws = s.loaded.config.tabWorkspace(tab);
        var reply = try s.client.listPrs(gpa, ws, tab.repo, &.{@tagName(tab.state)}, tab.q, 50);
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
    s.client.log = &s.log;
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
    s.client.log = &s.log;
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

/// The palette `--dump` paints with. A dump has no host and so no
/// `hello.palette`; painting with the 16-colour fallback makes a style
/// dump read `i0` where the pane in mnml has a real colour, which is no
/// use for checking that a row's ground is the one the theme asked for.
/// These are mnml's own default (onedark) roles.
const dump_palette: sdk.wire.Palette = .{
    .fg = .{ .rgb = .{ 0xab, 0xb2, 0xbf } },
    .bg = .{ .rgb = .{ 0x1e, 0x22, 0x2a } },
    .muted = .{ .rgb = .{ 0x5c, 0x63, 0x70 } },
    .accent = .{ .rgb = .{ 0x61, 0xaf, 0xef } },
    .border = .{ .rgb = .{ 0x31, 0x35, 0x3d } },
    .panel_bg = .{ .rgb = .{ 0x22, 0x26, 0x2e } },
    .cursor_line = .{ .rgb = .{ 0x31, 0x35, 0x3d } },
    .chip_bg = .{ .rgb = .{ 0x2d, 0x31, 0x39 } },
    .chip_active_fg = .{ .rgb = .{ 0x1e, 0x22, 0x2a } },
    .chip_active_bg = .{ .rgb = .{ 0x61, 0xaf, 0xef } },
    .red = .{ .rgb = .{ 0xe0, 0x6c, 0x75 } },
    .green = .{ .rgb = .{ 0x98, 0xc3, 0x79 } },
    .yellow = .{ .rgb = .{ 0xe5, 0xc0, 0x7b } },
    .orange = .{ .rgb = .{ 0xd1, 0x9a, 0x66 } },
    .blue = .{ .rgb = .{ 0x61, 0xaf, 0xef } },
    .cyan = .{ .rgb = .{ 0x56, 0xb6, 0xc2 } },
    .purple = .{ .rgb = .{ 0xc6, 0x78, 0xdd } },
    .comment = .{ .rgb = .{ 0x5c, 0x63, 0x70 } },
};

/// `--dump --steps FILE [--size WxH] [--only F]`: the same App and the
/// same paint as the pane, driven by the step grammar the Jira pane's
/// dump uses (`key`, `type`, `click`, `rclick`, `clickon`, `rclickon`,
/// `scroll`, `snap`, `expect`, `quit`; the waits are no-ops since every
/// fetch runs inline here). Each `snap NAME` prints `=== NAME` and the
/// screen, one row per line; `--dump-style` adds the row backgrounds and
/// foregrounds,
/// which the text cannot carry.
fn dumpCmd(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, arena: Allocator, out: *Io.Writer, err: *Io.Writer, opts: Opts) !u8 {
    var why: []const u8 = "";
    var session = openSession(gpa, io, env, &why) catch |e| {
        try err.print("mnml-bitbucket --dump: {s}\n", .{if (e == error.NoToken) no_token_text else why});
        return 1;
    };
    defer session.deinit(gpa);
    session.client.limiter = &session.limiter;
    session.client.log = &session.log;
    session.client.now_secs = nowSecs(io);
    // A dump takes the same tag store a pane does, so what it measures
    // is what a pane would have spent: the second run of the same dump
    // is a run of conditional GETs.
    var etags = try openEtagStore(gpa, io, env);
    defer {
        etags.save();
        etags.deinit();
    }
    session.client.etags = &etags;

    var cols: u16 = 120;
    var rows: u16 = 40;
    if (opts.size) |sz| if (std.mem.indexOfScalar(u8, sz, 'x')) |x| {
        cols = std.fmt.parseInt(u16, sz[0..x], 10) catch cols;
        rows = std.fmt.parseInt(u16, sz[x + 1 ..], 10) catch rows;
    };
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
            only = .prs;
            awaiting = true;
        } else if (std.mem.eql(u8, o, "pipelines")) {
            only = .pipelines;
        } else if (std.mem.eql(u8, o, "branches")) {
            only = .branches;
        }
    }

    var app = try app_mod.App.init(gpa, io, session.loaded.config, session.loaded.path, .{ .only = only, .mine = mine, .awaiting = awaiting, .focus = opts.focus, .workspace_dir = env.get("MNML_WORKSPACE") orelse "" });
    defer app.deinit();
    if (app.tabs.len == 0) {
        try err.print("mnml-bitbucket --dump: no tabs of that family in {s}\n", .{session.loaded.path});
        return 1;
    }
    app.theme = theme_mod.Theme.fromHelloBranded(dump_palette, chipColorOf(only));
    app.now_secs = session.client.now_secs;
    var progress: fetch.Progress = .{};
    app.progress = &progress;
    var worker = fetch.Worker.init(gpa, io, &session.client, &progress, session.loaded.config.account_id, session.loaded.config.workspace);
    defer worker.deinit();

    var frame = try sdk.Frame.init(gpa, cols, rows);
    defer frame.deinit();
    var paint_arena = std.heap.ArenaAllocator.init(gpa);
    defer paint_arena.deinit();

    try app.startup();
    try dumpDrain(gpa, &app, &worker);
    try dumpPaint(&paint_arena, &frame, &app);

    const steps_src = if (opts.steps) |path| try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) else "snap screen\n";
    var lines = std.mem.splitScalar(u8, steps_src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const verb = line[0..sp];
        const rest = std.mem.trimStart(u8, line[sp..], " ");
        if (std.mem.eql(u8, verb, "key")) {
            _ = try app.keyPress(rest);
        } else if (std.mem.eql(u8, verb, "type")) {
            var it = std.unicode.Utf8View.initUnchecked(rest).iterator();
            while (it.nextCodepointSlice()) |cp| {
                if (cp.len == 1 and cp[0] == ' ') {
                    _ = try app.keyPress("space");
                } else if (cp.len == 1 and std.ascii.isUpper(cp[0])) {
                    var kb: [8]u8 = undefined;
                    _ = try app.keyPress(std.fmt.bufPrint(&kb, "shift+{c}", .{std.ascii.toLower(cp[0])}) catch cp);
                } else _ = try app.keyPress(cp);
            }
        } else if (std.mem.eql(u8, verb, "click") or std.mem.eql(u8, verb, "rclick")) {
            var it = std.mem.tokenizeScalar(u8, rest, ' ');
            const x = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            const y = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            _ = try app.click(x, y, if (std.mem.eql(u8, verb, "rclick")) .right else .left);
        } else if (std.mem.eql(u8, verb, "clickon") or std.mem.eql(u8, verb, "rclickon")) {
            if (try dumpFind(arena, &frame, rest)) |at| {
                _ = try app.click(at.x, at.y, if (std.mem.eql(u8, verb, "rclickon")) .right else .left);
            } else try err.print("mnml-bitbucket --dump: {s} '{s}': not on screen\n", .{ verb, rest });
        } else if (std.mem.eql(u8, verb, "scroll")) {
            var it = std.mem.tokenizeScalar(u8, rest, ' ');
            const x = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            const y = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            const dir = it.next() orelse "down";
            try app.wheel(x, y, if (std.mem.eql(u8, dir, "up")) 1 else -1);
        } else if (std.mem.eql(u8, verb, "snap")) {
            try dumpDrain(gpa, &app, &worker);
            try dumpPaint(&paint_arena, &frame, &app);
            try out.print("=== {s}\n", .{rest});
            try out.writeAll(try screen.screenText(arena, &frame));
            if (opts.dump_style) {
                try out.writeAll("\n--- bg\n");
                try out.writeAll(try sdk.frame.bgDump(arena, &frame));
                try out.writeAll("\n--- fg\n");
                try out.writeAll(try sdk.frame.fgDump(arena, &frame));
            }
        } else if (std.mem.eql(u8, verb, "expect")) {
            try dumpDrain(gpa, &app, &worker);
            try dumpPaint(&paint_arena, &frame, &app);
            if ((try dumpFind(arena, &frame, rest)) == null) {
                try err.print("mnml-bitbucket --dump: expect '{s}': not on screen\n", .{rest});
                return 1;
            }
        } else if (std.mem.eql(u8, verb, "quit")) {
            break;
        }
        try dumpDrain(gpa, &app, &worker);
        try dumpPaint(&paint_arena, &frame, &app);
    }
    return 0;
}

/// Run every queued job inline and commit its result — the pane's
/// worker thread, minus the thread.
fn dumpDrain(gpa: Allocator, app: *app_mod.App, worker: *fetch.Worker) !void {
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
}

fn dumpPaint(paint_arena: *std.heap.ArenaAllocator, frame: *sdk.Frame, app: *app_mod.App) !void {
    _ = paint_arena.reset(.retain_capacity);
    try screen.paint(paint_arena.allocator(), frame, app, true);
}

fn dumpFind(arena: Allocator, frame: *sdk.Frame, needle: []const u8) !?struct { x: u16, y: u16 } {
    var y: u16 = 0;
    while (y < frame.rows) : (y += 1) {
        const row = try screen.rowText(arena, frame, y);
        if (std.mem.indexOf(u8, row, needle)) |byte| {
            return .{ .x = @intCast(std.unicode.utf8CountCodepoints(row[0..byte]) catch byte), .y = y };
        }
    }
    return null;
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
    /// // changed (focus-row): a hover row pressed while this pane is
    /// already the open one — the pull request to put the cursor on.
    focus_item: []u8,
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
    /// One turn of the spinner: a repaint and nothing else, sent only
    /// while a fetch is out.
    frame,
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
            .focus_item => |f| .{ .focus_item = gpa.dupe(u8, f.key) catch continue },
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

/// The clock: a `tick` every second for the auto-refresh, and — while
/// `busy` says a fetch is out — a `frame` every step of the spinner
/// ring, so the header's glyph turns at the host's cadence and the
/// loop sleeps the rest of the time.
fn tickerThread(io: Io, q: *EventQueue, busy: *std.atomic.Value(bool)) void {
    var since_tick: i64 = 0;
    while (true) {
        const step = sdk.pane.chrome.spinner_step_ms;
        io.sleep(.fromMilliseconds(step), .awake) catch return;
        since_tick += step;
        if (since_tick >= 1000) {
            since_tick = 0;
            q.putOneUncancelable(io, .tick) catch return;
        } else if (busy.load(.acquire)) {
            q.putOneUncancelable(io, .frame) catch return;
        }
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
    session.client.log = &session.log;
    // Whatever `--prefetch` last left behind answers the startup fetch
    // — each URL once, so the first refresh after it is live.
    var cache = try cache_mod.Cache.init(gpa, io, session.loaded.path, .prime);
    defer cache.deinit();
    session.client.cache = &cache;
    session.client.now_secs = nowSecs(io);
    // The server's own tags for the bodies already held: every GET
    // that has one goes out conditional, and a 304 is a round trip
    // that costs a token and no bytes.
    var etags = try openEtagStore(gpa, io, env);
    defer {
        etags.save();
        etags.deinit();
    }
    session.client.etags = &etags;
    // One pacer for this service, so a burst of warm work is spread
    // one per `1/rate + margin` rather than draining the bucket in
    // front of a click.
    var gate: sdk.warm.Gate = .forConfig(.{
        .rate = session.loaded.config.rate.rate_per_sec,
        .capacity = session.loaded.config.rate.capacity,
    });
    session.client.gate = &gate;
    // Speculative work is worth doing once on a machine, not once per
    // pane: whoever holds the lock warms the inactive tabs, and
    // everyone else reads what they left in the cache.
    var warm_lock = try sdk.warm.Lock.forService(gpa, io, env, ratelimit.service, sdk.warm.selfPid(), "mnml-bitbucket");
    defer warm_lock.deinit();
    const may_warm = warm_lock.acquire(@floatFromInt(nowSecs(io)));

    var app = try app_mod.App.init(gpa, io, session.loaded.config, session.loaded.path, .{ .only = only, .mine = mine, .awaiting = awaiting, .focus = opts.focus, .workspace_dir = env.get("MNML_WORKSPACE") orelse mount.hello.workspace });
    defer app.deinit();
    app.may_warm = may_warm;
    // The worker leaves a long wait where the paint loop finds it.
    // `app` is a local that is never moved, so the pointer the worker
    // thread's client carries stays good for the whole run.
    session.client.notice = &app.wait_notice;
    // The API budget the header chip shows and the client obeys: the
    // headers, a 429's pause, the hit ratio, the day's tally (shared
    // with every process on this data root), dry run.
    const budget_root = try sdk.request_log.dataRoot(gpa, env);
    defer gpa.free(budget_root);
    // The config's two paths — the shared bucket, the event feed —
    // relative to the config's own directory, `~/` to home.
    var paths_arena = std.heap.ArenaAllocator.init(gpa);
    defer paths_arena.deinit();
    const config_dir = std.fs.path.dirname(session.loaded.path) orelse "";
    const lc = session.loaded.config;
    app.budget.configure(io, .{
        .label = "Bitbucket",
        .service = ratelimit.service,
        .data_root = budget_root,
        .hourly_budget = @intFromFloat(@max(lc.rate.rate_per_sec, 0) * 3600),
        .dry_run = lc.dry_run,
        .backoff = session.client.backoff(),
        .shared_bucket = try sdk.feed.resolvePath(paths_arena.allocator(), env, config_dir, lc.budget.shared_bucket),
    });
    // When to ask again, and what an event file says changed.
    app.watch = .init(io, .pr, lc.refresh_interval_secs, lc.poll_max_secs, lc.feed, try sdk.feed.resolvePath(paths_arena.allocator(), env, config_dir, lc.feed.file));
    session.client.budget = &app.budget;
    if (app.tabs.len == 0) {
        const msg = try std.fmt.allocPrint(gpa, "--only {s}: no tabs of that family in {s} (check the `tabs` entries and their `kind`)", .{ opts.only orelse "?", session.loaded.path });
        defer gpa.free(msg);
        return setupLoop(gpa, mount, &frame, msg, false);
    }
    app.theme = theme_mod.Theme.fromHelloBranded(mount.hello.palette, chipColorOf(only));
    app.cols = frame.cols;
    app.rows = frame.rows;
    app.now_secs = nowSecs(io);
    app.tab_indicator = mount.hello.tab_indicator;
    app.ascii = !nerd;
    app.chip_mark = sdk.pane.chipGlyphFromEnv(env, app_mod.App.chip_glyph);

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
    // `busy` is a static: the ticker is detached and outlives this
    // frame's locals on the way out.
    const Busy = struct {
        var flag: std.atomic.Value(bool) = .init(false);
    };
    const ticker = try std.Thread.spawn(.{}, tickerThread, .{ io, &events, &Busy.flag });
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
                .hover => |hv| {
                    app.hover(hv.col, hv.row);
                    // The host's info view, told what is under the
                    // pointer (sent only when it changed).
                    // Room for the budget chip's hover, the longest.
                    var hb: [1024]u8 = undefined;
                    const help = app.helpAt(hv.col, hv.row, &hb);
                    mount.hover(help.title, help.body) catch {};
                },
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
                .focus => |f| {
                    app.focused = f;
                    // Focus is somebody looking: the poller comes back
                    // to its base.
                    if (f) app.touched();
                },
                .focus_item => |k| {
                    defer gpa.free(k);
                    try app.requestFocus(k);
                },
                .other => {},
            },
            .result => |r| {
                app.now_secs = nowSecs(io);
                try app.commit(r);
                gpa.destroy(r);
            },
            .tick => try app.tick(nowSecs(io)),
            .frame => {},
            .host_gone => running = false,
        }
        // Before the paint: if a request has been sitting on the
        // bucket, say so rather than leaving `loading…` on its own.
        app.noteWait();
        try dispatchJobs(gpa, io, &app, &jobs);
        running = drain(gpa, io, env, mount, &ipc_opt, &app, &session.limiter) and running;
        app.now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
        Busy.flag.store(app.anyLoading(), .release);
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
fn drain(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, mount: *sdk.Mount, ipc_opt: *?sdk.Ipc, app: *app_mod.App, limiter: *ratelimit.Limiter) bool {
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
        .toast => |x| {
            const level: sdk.wire.ToastLevel = switch (x.level) {
                .info => .info,
                .warn => .warn,
                .err => .@"error",
            };
            // An offer, when the message carries one: the host paints
            // it as the button in the box (`wire.ToastAction`).
            if (x.action) |act| {
                mount.toastWithAction(level, x.text, act) catch {};
            } else {
                mount.toast(level, x.text) catch {};
            }
        },
        .open_url => |url| {
            if (os.openUrl(gpa, io, env, url)) |whynot| mount.toast(.warn, whynot) catch {};
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
                // The bucket is read off its file — a lock, a read
                // and a rewrite — so it is looked at HERE, where a
                // chip is actually being published, and not once per
                // pass of a loop that runs at sixty hertz.
                var bucket_name: [64]u8 = undefined;
                publishSegments(ipc, arena_state.allocator(), v, bucketOf(gpa, io, limiter, &bucket_name), Mark.of(app)) catch {};
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
    // Atlassian's own pull-request and pipeline marks, baked into
    // MnmlSymbols at these two codepoints (`src/glyph/builder.zig`'s
    // `atl_pull_request` / `atl_pipeline`).
    try t.expectEqualStrings("\u{f1c15}", spec.chip.?.glyph);
    try t.expectEqualStrings("\u{f1c16}", spec_pipelines.chip.?.glyph);
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
    try t.expectEqual(@as(usize, 4), spec.auth.len);
    // The fourth is mnml's alone: the pull-request links' workspace.
    try t.expectEqualStrings("workspace", spec.auth[3].key);
    try t.expectEqualStrings("BITBUCKET_WORKSPACE", spec.auth[3].env_fallback.?);
    // `<repo>#<n>` links to the pull request in that workspace; the
    // Pipelines chip declares none (the same workspace).
    try t.expectEqual(@as(usize, 1), spec.links.len);
    try t.expectEqualStrings("(?<![/\\w.-])([A-Za-z0-9_.-]+)#(\\d+)", spec.links[0].pattern);
    try t.expectEqualStrings("https://bitbucket.org/{workspace}/{1}/pull-requests/{2}", spec.links[0].url);
    try t.expectEqual(@as(usize, 0), spec_pipelines.links.len);
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

test "--install writes the config's workspace into the PR links, narrows the repo to the config's list and adds <workspace>/<repo>#n; no workspace leaves the template for mnml" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // No workspace yet: as declared.
    const bare = try linkSpec(arena, spec, "", &.{});
    try t.expectEqualStrings("https://bitbucket.org/{workspace}/{1}/pull-requests/{2}", bare.links[0].url);
    // A workspace, any repo.
    const any = try linkSpec(arena, spec, "acme", &.{});
    try t.expectEqual(@as(usize, 2), any.links.len);
    try t.expectEqualStrings("(?<![/\\w.-])(acme)/([A-Za-z0-9_.-]+)#(\\d+)", any.links[0].pattern);
    try t.expectEqualStrings("https://bitbucket.org/{1}/{2}/pull-requests/{3}", any.links[0].url);
    try t.expectEqualStrings("(?<![/\\w.-])([A-Za-z0-9_.-]+)#(\\d+)", any.links[1].pattern);
    try t.expectEqualStrings("https://bitbucket.org/acme/{1}/pull-requests/{2}", any.links[1].url);
    try t.expect(sdk.manifest.unboundLinkVar(any.links[1].url) == null);
    // The config lists its repos: only those link; a dot is a literal.
    const c: cfg.Config = .{ .workspace = "acme", .repos = &.{ "widget", "web.site" }, .hidden_repos = &.{"old"} };
    const repos = try linkedRepos(arena, c);
    try t.expectEqual(@as(usize, 2), repos.len);
    const narrow = try linkSpec(arena, spec, c.workspace, repos);
    try t.expectEqualStrings("(?<![/\\w.-])(widget|web\\.site)#(\\d+)", narrow.links[1].pattern);
    try t.expectEqualStrings("(?<![/\\w.-])(acme)/(widget|web\\.site)#(\\d+)", narrow.links[0].pattern);
    // The declared spec is untouched.
    try t.expectEqual(@as(usize, 1), spec.links.len);
}

test "the pane's brand is its OWN family's chip colour, not the host's accent" {
    // The stripe down column 0 is the app saying which app this is, so
    // it has to come off the manifest the pane was opened on. The pane
    // used to take `fromHello`, which leaves `brand` as the theme's
    // accent — every integration mounted in mnml wore the same one.
    try t.expectEqualStrings("blue", chipColorOf(.prs));
    try t.expectEqualStrings("blue", chipColorOf(.branches));
    try t.expectEqualStrings("green", chipColorOf(.pipelines));
    try t.expectEqualStrings("blue", chipColorOf(null));
    const pal: sdk.wire.Palette = .{
        .accent = .{ .rgb = .{ 9, 9, 9 } },
        .blue = .{ .rgb = .{ 1, 2, 3 } },
        .green = .{ .rgb = .{ 4, 5, 6 } },
    };
    try t.expectEqual(sdk.wire.Color{ .rgb = .{ 1, 2, 3 } }, theme_mod.Theme.fromHelloBranded(pal, chipColorOf(.prs)).brand);
    // The two families are two colours, or the tab indicator and the
    // gutter say nothing about which one you are looking at.
    try t.expectEqual(sdk.wire.Color{ .rgb = .{ 4, 5, 6 } }, theme_mod.Theme.fromHelloBranded(pal, chipColorOf(.pipelines)).brand);
}

test "the chip's Tier-2 lines are the exact JSON mnml reads: the segment, its rows and the badge" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var ipc = try sdk.Ipc.init(t.allocator, t.io, dir);
    defer ipc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `publishSegments` is the ONE publish this pane has: `--values`,
    // `--refresh` and the pane's own `.segment` effect all go through
    // it, so the chip an open pane republishes for itself carries the
    // rows rather than dropping back to a bare figure. There is no
    // figure-only form left to reach for.
    try publishSegments(&ipc, arena, .{
        .open_mine = 1,
        .unapproved_mine = 1,
        .approved_mine = 0,
        .open_items = &.{.{ .text = "Fix the login redirect", .sub = "acme/api \u{b7} unapproved", .key = "api#1234" }},
    }, null, .{});
    const got = try tmp.dir.readFileAlloc(t.io, "command", arena, .unlimited);
    try t.expectEqualStrings(
        "{\"cmd\":\"statusline-set-segment\",\"id\":\"bitbucket_prs.prs_mine\",\"side\":\"right\",\"text\":\"\u{f1c15} 1(1)\",\"color\":\"green\",\"click_command\":\"bitbucket_prs.open_mine\",\"priority\":60,\"min_width\":4,\"max_width\":30," ++
            "\"tooltip\":\"Bitbucket \u{b7} 1 open pull request you authored \u{2014} 1 still unapproved, 0 approved \u{2014} \u{201c}Fix the login redirect\u{201d}\"," ++
            "\"items\":[{\"text\":\"Fix the login redirect\",\"sub\":\"acme/api \u{b7} unapproved\",\"command\":\"bitbucket_prs.open_mine\",\"args\":[\"--focus\",\"api#1234\"]}]}\n" ++
            "{\"cmd\":\"statusline-set-segment\",\"id\":\"bitbucket_prs.reviews_pending\",\"side\":\"right\",\"text\":\"\u{f0e5} 0\",\"color\":\"green\",\"click_command\":\"bitbucket_prs.open_awaiting\",\"priority\":58,\"min_width\":4,\"max_width\":30," ++
            "\"tooltip\":\"Bitbucket \u{b7} 0 open pull requests waiting on YOUR review \u{2014} you are a reviewer and have not approved\"}\n" ++
            "{\"cmd\":\"set-activity-badge\",\"section\":\"integrations\",\"count\":1}\n",
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
        .open_items = &.{ .{ .text = "Fix the login redirect", .sub = "acme/api · unapproved", .key = "api#1198" }, .{ .text = "Redesign the empty state", .sub = "acme/web · approved", .key = "web#820" } },
        .comment_items = &.{.{ .text = "Fix the login redirect", .sub = "acme/api · 2 waiting", .key = "api#1198" }},
        .awaiting_items = &.{ .{ .text = "Bump the client timeout to 30s", .sub = "acme/api", .key = "api#1234" }, .{ .text = "Tidy the footer links", .sub = "acme/web", .key = "web#77" } },
    }, .{ .status = .{ .tokens = 0.24, .capacity = 40, .rate = 0.11, .baseline_rate = 0.22, .throttles = 127, .cooldown_remaining_secs = 0, .last_429_age_secs = 4 * 3600 }, .draws = .{ .top = "bb.py", .top_n = 30, .total = 83 } }, .{});
    var got = try tmp.dir.readFileAlloc(t.io, "command", arena, .unlimited);
    try t.expect(std.mem.indexOf(u8, got, "\"id\":\"bitbucket_prs.prs_mine\"") != null);
    try t.expect(std.mem.indexOf(u8, got, "4 open pull requests you authored — 2 still unapproved, 2 approved") != null);
    try t.expect(std.mem.indexOf(u8, got, "\"id\":\"bitbucket_prs.reviews_mine\"") != null);
    try t.expect(std.mem.indexOf(u8, got, review_segment_glyph ++ " 3") != null);
    try t.expect(std.mem.indexOf(u8, got, "3 review threads across your open pull requests still waiting on someone") != null);
    // And the hover carries the shared bucket, which is the answer to
    // "why is this chip stale" — one hover away rather than nowhere.
    try t.expect(std.mem.indexOf(u8, got, "budget: 0.2 of 40 tokens") != null);
    try t.expect(std.mem.indexOf(u8, got, "127 throttles") != null);
    try t.expect(std.mem.indexOf(u8, got, "last 429 4h ago") != null);
    // And WHO drained it — a chip that is stale because a script is
    // holding the budget says so rather than blaming itself.
    try t.expect(std.mem.indexOf(u8, got, "spent by bb.py 30 of 83 draws in 10m") != null);
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
    // The SDK's assertion, not this pane's own opinion of it: one
    // figure the segment is named for, and a bracketed subset only
    // when the pane genuinely has one. This pane has one — the open
    // pull requests of mine nobody has approved are a SUBSET of the
    // open pull requests of mine — so it is the family's `12(11)`
    // shape and the other two chips are one figure each.
    var fbuf: [32]u8 = undefined;
    try sdk.pane.expect.statuslineFigure(segmentText(&fbuf, .{ .open_mine = 12, .unapproved_mine = 11 }, .{ .ascii = false }));
    try sdk.pane.expect.statuslineFigure(reviewText(&fbuf, 3, false));
    try sdk.pane.expect.statuslineFigure(awaitingText(&fbuf, 2, false));
    // And the twins keep the family's shape, so `--ascii` reads the
    // same figure rather than a run of tofu.
    try sdk.pane.expect.statuslineFigure(segmentText(&fbuf, .{ .open_mine = 12, .unapproved_mine = 11 }, .{ .ascii = true }));
    try sdk.pane.expect.statuslineFigure(reviewText(&fbuf, 3, true));
    try sdk.pane.expect.statuslineFigure(awaitingText(&fbuf, 2, true));

    // The sentence names the first few; `items` carries every one the
    // values run had, each with where it lives and what a click on the
    // row runs. Three chips, three lists — the awaiting chip lists the
    // ones waiting on YOU, not the ones you wrote.
    try t.expect(std.mem.indexOf(u8, got, "\"items\":[{\"text\":\"Fix the login redirect\",\"sub\":\"acme/api \u{b7} unapproved\",\"command\":\"bitbucket_prs.open_mine\"") != null);
    try t.expect(std.mem.indexOf(u8, got, "{\"text\":\"Redesign the empty state\",\"sub\":\"acme/web \u{b7} approved\",\"command\":\"bitbucket_prs.open_mine\"") != null);
    try t.expect(std.mem.indexOf(u8, got, "{\"text\":\"Fix the login redirect\",\"sub\":\"acme/api \u{b7} 2 waiting\",\"command\":\"bitbucket_prs.open_mine\"") != null);
    try t.expect(std.mem.indexOf(u8, got, "\"items\":[{\"text\":\"Bump the client timeout to 30s\",\"sub\":\"acme/api\",\"command\":\"bitbucket_prs.open_awaiting\"") != null);
    // And WHICH pull request each row is: the host appends these to
    // the command's argv, so the press lands the cursor on that one
    // rather than only opening the pane.
    try t.expect(std.mem.indexOf(u8, got, "\"command\":\"bitbucket_prs.open_mine\",\"args\":[\"--focus\",\"api#1198\"]") != null);
    try t.expect(std.mem.indexOf(u8, got, "\"command\":\"bitbucket_prs.open_mine\",\"args\":[\"--focus\",\"web#820\"]") != null);
    try t.expect(std.mem.indexOf(u8, got, "\"command\":\"bitbucket_prs.open_awaiting\",\"args\":[\"--focus\",\"api#1234\"]") != null);

    // Not counted: the second chip is not published at all. A zero
    // there would read as "nothing outstanding".
    try tmp.dir.writeFile(t.io, .{ .sub_path = "command", .data = "" });
    try publishSegments(&ipc, arena, .{ .open_mine = 1, .unapproved_mine = 0, .approved_mine = 1 }, null, .{});
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
    try publishSegments(&ipc, arena, .{ .error_text = "HTTP 401: auth" }, null, .{});
    got = try tmp.dir.readFileAlloc(t.io, "command", arena, .unlimited);
    try t.expect(std.mem.indexOf(u8, got, "Bitbucket: HTTP 401: auth") != null);
}

test "--ascii: all three chips publish their twin, and no Nerd Font glyph goes out" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var ipc = try sdk.Ipc.init(t.allocator, t.io, dir);
    defer ipc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try publishSegments(&ipc, arena, .{
        .open_mine = 4,
        .unapproved_mine = 2,
        .approved_mine = 2,
        .reviews_pending = 2,
        .unresolved_comments = 3,
    }, null, .{ .ascii = true });
    const got = try tmp.dir.readFileAlloc(t.io, "command", arena, .unlimited);
    try t.expect(std.mem.indexOf(u8, got, app_mod.App.chip_ascii ++ " 4(2)") != null);
    try t.expect(std.mem.indexOf(u8, got, review_segment_ascii ++ " 3") != null);
    try t.expect(std.mem.indexOf(u8, got, awaiting_segment_ascii ++ " 2") != null);
    // The point of the twin: a host that cannot paint the font is sent
    // no codepoint it would render as tofu.
    try t.expect(std.mem.indexOf(u8, got, app_mod.App.chip_glyph) == null);
    try t.expect(std.mem.indexOf(u8, got, review_segment_glyph) == null);
    try t.expect(std.mem.indexOf(u8, got, awaiting_segment_glyph) == null);
    // And the failure form wears it too, rather than falling back to
    // the comptime concatenation it used to be.
    var fbuf: [64]u8 = undefined;
    try t.expectEqualStrings(app_mod.App.chip_ascii ++ " !", segmentText(&fbuf, .{ .error_text = "nope" }, .{ .ascii = true }));
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

test "the three chips keep what they list: every segment and every hover row survives a refresh, a `--values` and a refetch, on a scribbling allocator" {
    // The fetch side — the client, the worker, and every job and
    // result arena — on an allocator that poisons what it frees. A
    // chip that kept a SLICE into a finished listing rather than the
    // arena under it reads as 0xAA here, where a plain allocator hands
    // the right answer back and the test passes for no reason.
    var scribble: sdk.testing.Scribble = .{ .child = t.allocator };
    const r = try app_mod.Rig.initOn(app_mod.acme, .{}, scribble.allocator());
    defer r.deinit();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var ipc = try sdk.Ipc.init(t.allocator, t.io, dir);
    defer ipc.deinit();

    var keep = std.heap.ArenaAllocator.init(t.allocator);
    defer keep.deinit();

    const Published = struct {
        /// Publish all three chips the way the pane's own `.segment`
        /// effect does, and hand back the bytes the host would read.
        fn line(app: *app_mod.App, out_ipc: *const sdk.Ipc, d: Io.Dir, out: Allocator) ![]const u8 {
            var scratch = std.heap.ArenaAllocator.init(t.allocator);
            defer scratch.deinit();
            try publishSegments(out_ipc, scratch.allocator(), app.values orelse return error.NoValues, null, .{});
            const text = try d.readFileAlloc(t.io, "command", out, .unlimited);
            try d.deleteFile(t.io, "command");
            return text;
        }
        /// Every row of every chip, and the tooltip behind each figure.
        fn check(v: fetch.ValuesResult, published: []const u8) !void {
            try t.expect(std.mem.indexOfScalar(u8, published, 0xAA) == null);
            for ([_][]const fetch.ValuesItem{ v.open_items, v.comment_items, v.awaiting_items }) |rows| {
                for (rows) |it| {
                    try t.expect(it.text.len > 0);
                    try t.expect(std.mem.indexOfScalar(u8, it.text, 0xAA) == null);
                    try t.expect(std.mem.indexOfScalar(u8, it.sub, 0xAA) == null);
                    try t.expect(std.mem.indexOfScalar(u8, it.key, 0xAA) == null);
                    // And the row actually reached the wire, rather than
                    // the chip agreeing with itself about nothing.
                    try t.expect(std.mem.indexOf(u8, published, it.text) != null);
                }
            }
            try t.expect(std.mem.indexOfScalar(u8, v.error_text, 0xAA) == null);
        }
    };

    // 1. The first listing, straight off `startup`.
    const first = try Published.line(&r.app, &ipc, tmp.dir, keep.allocator());
    const v1 = r.app.values.?;
    try t.expect(v1.open_items.len > 0);
    try t.expect(v1.awaiting_items.len > 0);
    try Published.check(v1, first);

    // 2. A fresh `--values`. The result that carried the previous
    //    figure is let go here; anything the chip still pointed into it
    //    is 0xAA from this line on.
    try r.app.requestValues();
    try r.drain();
    const second = try Published.line(&r.app, &ipc, tmp.dir, keep.allocator());
    try Published.check(r.app.values.?, second);

    // 3. A refetch of every tab. Each one DEINITS the arena its old
    //    rows lived on, which is the other listing the chip could have
    //    been pointing into.
    for (r.app.tabs, 0..) |_, i| try r.app.refreshTab(i);
    try r.drain();
    for (r.app.tabs) |ts| try t.expect(ts.fetched);
    const third = try Published.line(&r.app, &ipc, tmp.dir, keep.allocator());
    try Published.check(r.app.values.?, third);

    // 4. And what a hover row hands back is still a pull request the
    //    pane can be told to focus — the `--focus` argv on the wire.
    try t.expect(std.mem.indexOf(u8, third, "\"args\":[\"--focus\",\"api#") != null);
}

test "a $BITBUCKET_BASE_URL=@file that never arrives refuses to start — no fallback to api.bitbucket.org, no request" {
    // hunt/findings-2026-09-23/integ-bb-base-url-falls-back-to-production.md:
    // the fake did not start, so the override's file never appeared,
    // and the pane quietly asked the real Bitbucket with whatever token
    // the shell exported.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bb.zon", .data = ".{ .email = \"me@example.com\", .workspace = \"acme\", .repos = .{\"api\"}, .tabs = .{ .{ .name = \"Open\", .kind = .workspace_open_prs } } }" });
    const cfg_path = try std.fs.path.join(t.allocator, &.{ root, "bb.zon" });
    defer t.allocator.free(cfg_path);
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    const at = try std.fmt.allocPrint(t.allocator, "@{s}/never.url", .{root});
    defer t.allocator.free(at);

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("MNML_DATA_ROOT", data);
    try env.put("MNML_BITBUCKET_CONFIG", cfg_path);
    try env.put("BITBUCKET_API_TOKEN", "fixture-token");
    const bucket = try std.fs.path.join(t.allocator, &.{ root, "bucket.json" });
    defer t.allocator.free(bucket);
    try env.put("BITBUCKET_RATELIMIT_STATE", bucket);
    try env.put(base_url_env, at);

    var why: []const u8 = "";
    try t.expectError(error.BaseUrl, openSession(t.allocator, t.io, &env, &why));
    // The setup screen names the variable and the file.
    try t.expect(std.mem.indexOf(u8, why, "BITBUCKET_BASE_URL") != null);
    try t.expect(std.mem.indexOf(u8, why, "never.url") != null);
    // Nothing was asked: the request log was never even opened.
    const log_path = try std.fs.path.join(t.allocator, &.{ data, "requests", "bitbucket.jsonl" });
    defer t.allocator.free(log_path);
    try t.expectError(error.FileNotFound, Io.Dir.cwd().access(t.io, log_path, .{}));

    // The same override, once the file is there, is the fake.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "never.url", .data = "http://127.0.0.1:9\n" });
    var s = try openSession(t.allocator, t.io, &env, &why);
    defer s.deinit(t.allocator);
    try t.expectEqualStrings("http://127.0.0.1:9", s.base_url);
}

/// The pane on the offline fixture, for the SDK's design-language
/// suite: the PR tree over enough repos that its list outruns the body
/// at 80×24, so the scrollbar rule has something to hold.
const Probe = struct {
    pub const Target = @import("src/hit.zig").Target;
    rig: *app_mod.Rig,
    f: sdk.Frame,
    ascii: bool,

    const repos = [_][]const u8{ "api", "web", "r01", "r02", "r03", "r04", "r05", "r06", "r07", "r08", "r09", "r10", "r11", "r12", "r13", "r14", "r15", "r16", "r17", "r18" };
    const config: cfg.Config = .{ .email = "me@x.com", .workspace = "acme", .repos = &repos, .refresh_interval_secs = 0, .tabs = &cfg.default_tabs };

    pub fn init(gpa: Allocator, size: sdk.testing.Size) !Probe {
        return .{ .rig = try app_mod.Rig.init(config, .{}), .f = try sdk.Frame.init(gpa, size.cols, size.rows), .ascii = size.ascii };
    }

    pub fn deinit(p: *Probe) void {
        p.f.deinit();
        p.rig.deinit();
    }

    pub fn paint(p: *Probe, arena: Allocator) !sdk.testing.Painted(Target) {
        try screen.paint(arena, &p.f, &p.rig.app, !p.ascii);
        var segs: std.ArrayList([]const u8) = .empty;
        try segs.append(arena, segmentText(try arena.alloc(u8, 64), .{ .open_mine = 12, .unapproved_mine = 11 }, .{ .ascii = p.ascii }));
        try segs.append(arena, reviewText(try arena.alloc(u8, 64), 3, p.ascii));
        try segs.append(arena, awaitingText(try arena.alloc(u8, 64), 2, p.ascii));
        return .{
            .frame = &p.f,
            .hits = &p.rig.app.hits.inner,
            .theme = p.rig.app.theme,
            .title = .{ .text = "BITBUCKET PRS" },
            .ladder_y = 0,
            .gutter = .{ .h = p.f.rows - 1 },
            .list = .{ .bar_x = p.f.cols - 1, .y0 = 1, .h = p.f.rows - 2 },
            .statusline = segs.items,
        };
    }
};

test "the design language: the SDK's conformance suite at 120x40 and 80x24, with and without --ascii" {
    try sdk.testing.conformance(Probe);
}

test "the PRs figure wears the chip's glyph — the manifest's, or the host's" {
    var buf: [64]u8 = undefined;
    const chip = spec.chip.?.glyph;
    // The default mark is the manifest's own chip glyph.
    try t.expect(std.mem.startsWith(u8, segmentText(&buf, .{ .open_mine = 4, .unapproved_mine = 2 }, .{}), chip));
    // The resting text the manifest declares wears it too.
    for (spec.statusline) |seg| if (std.mem.eql(u8, seg.id, "prs_mine")) {
        try t.expect(std.mem.startsWith(u8, seg.text, chip));
    };
    // And whatever the host says its chip paints wins.
    try t.expect(std.mem.startsWith(u8, segmentText(&buf, .{ .open_mine = 4 }, .{ .glyph = "\u{f1c19}" }), "\u{f1c19}"));
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put(sdk.pane.chrome.chip_glyph_env, "\u{f1c19}");
    try t.expectEqualStrings("\u{f1c19}", Mark.fromEnv(&env).glyph);
    try t.expectEqualStrings(app_mod.App.chip_ascii, (Mark{ .ascii = true }).chip());
}
