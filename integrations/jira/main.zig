//! mnml-jira — the Jira tracker as an mnml pane, on `mnml-sdk`: three
//! chips (Jira Work, Jira Fix Versions, Jira Boards) over one binary,
//! each `--only <family>`; the status-grouped ticket tree with linked
//! PRs and their post-merge pipelines, the kanban board, the detail pane
//! and the detail modal, the pickers, bulk selection, the filter, the
//! JQL editor, watching, the dispatch queue, auto-refresh, and the
//! statusline count.
//!
//!   mnml-jira --install / --uninstall   the three manifests
//!   mnml-jira --version
//!   mnml-jira --check                   the resolved config + auth, no network
//!   mnml-jira --diag                    the same plus a live /myself probe
//!   mnml-jira --values [--only F]       {"assigned_open": N} on stdout
//!             [--workspace W]           … and, with a workspace, the statusline
//!                                       segment published over mnml's channel
//!   mnml-jira --prefetch --only F       the tabs' issues as JSON (a cache)
//!   mnml-jira --write-config            write config.zon and say where
//!   mnml-jira --only F [--config P]     connect to `$MNML_MOUNT_SOCKET` and paint
//!
//! The token is never printed: `--check` / `--diag` say where it came
//! from and how long it is.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sdk = @import("mnml_sdk");
const recent = @import("src/recent.zig");

pub const config = @import("src/config.zig");
pub const auth = @import("src/auth.zig");
pub const jira = @import("src/jira.zig");
pub const model = @import("src/model.zig");
pub const tree = @import("src/tree.zig");
pub const kanban = @import("src/kanban.zig");
pub const filters = @import("src/filters.zig");
pub const dispatch = @import("src/dispatch.zig");
pub const hit = @import("src/hit.zig");
pub const keymap = @import("src/keymap.zig");
pub const pickers = @import("src/pickers.zig");
pub const inbox = @import("src/inbox.zig");
pub const app_mod = @import("src/app.zig");
pub const textedit = @import("src/textedit.zig");
pub const varsedit = @import("src/varsedit.zig");
pub const screen = @import("src/screen.zig");
pub const bitbucket = @import("src/bitbucket.zig");
pub const json = @import("src/json.zig");
pub const text = @import("src/text.zig");
pub const os = @import("src/os.zig");
pub const ratelimit = @import("src/ratelimit.zig");

pub const spec_work: sdk.Manifest = sdk.manifest.withChipMark(@import("manifest.zon"));
pub const spec_fix_versions: sdk.Manifest = @import("manifest_fix_versions.zon");
pub const spec_boards: sdk.Manifest = @import("manifest_boards.zon");
pub const specs = [_]sdk.Manifest{ spec_work, spec_fix_versions, spec_boards };
/// The Dev tab's row.
pub const spec = spec_work;

/// The manifest chip colour of the family a launch is showing — the
/// pane's own colour, and what the left gutter stripe paints in. Work
/// blue, Fix Versions green, Boards magenta, as the three chips read on
/// the rail.
pub fn chipColorOf(family: ?config.Family) []const u8 {
    const m = switch (family orelse .work) {
        .work => spec_work,
        .fix_versions => spec_fix_versions,
        .boards => spec_boards,
    };
    return if (m.chip) |c| c.color else "";
}
pub const version = "0.2.1";

/// The ONE statusline segment the Work chip publishes — the manifest's
/// slot, replaced live with its counts: what is on your plate, and,
/// after a ` · ` and the clipboard, what waits in your QA Actionable Now
/// tab. The hover says each in words.
pub const segment_id = "jira_work.assigned";
/// The Work chip's own mark — `manifest.zon`'s `chip.glyph`, never a
/// codepoint of this file's. A run the host started wears the host's
/// instead (`Mark`), so the chip and the figure are one mark.
pub const segment_glyph = (spec_work.chip orelse @compileError("manifest.zon declares no chip")).glyph;

/// What the assigned figure wears: the chip's mark — the host's,
/// through `$MNML_CHIP_GLYPH`, else the manifest's own — or its plain
/// twin. The QA count keeps its own glyph: it is a second thing, not
/// the chip.
pub const Mark = struct {
    ascii: bool = false,
    glyph: []const u8 = segment_glyph,

    pub fn fromEnv(env: *const std.process.Environ.Map) Mark {
        return .{ .ascii = sdk.pane.asciiFromEnv(env), .glyph = sdk.pane.chipGlyphFromEnv(env, segment_glyph) };
    }

    pub fn chip(m: Mark) []const u8 {
        return if (m.ascii) segment_ascii else m.glyph;
    }
};
/// What the chip says on a terminal with no Nerd Font: the same shape,
/// a figure a reader can still act on. `sdk.pane.figure`'s own tests
/// name this twin for the tracker pane.
pub const segment_ascii = "J";
pub const segment_color = "#1B5DCF";
pub const segment_click = "jira_work.open";
pub const segment_priority: u8 = 60;

/// The second count on the chip: the tab the user configures as "QA
/// Actionable Now" — a `jql_editable` tab, or, for a config written
/// before that kind existed, one found by name. Without such a tab the
/// part is not shown at all rather than a zero that means "not
/// configured"; at zero it is left off like any part.
pub const qa_glyph = "\u{ed7a}"; // nf-fa-clipboard_check
pub const qa_ascii = "QA";

/// The segment an older manifest declared and this one does not; a
/// reinstall drops it (the host clears what a scan no longer declares).
pub const retired_segment_id = "jira_work.qa_actionable";

/// The prefetch cache mnml hands a pane.
pub const prefetch_env = "MNML_PREFETCH_CACHE_FILE";

pub const Args = struct {
    install: bool = false,
    uninstall: bool = false,
    show_version: bool = false,
    help: bool = false,
    check: bool = false,
    diag: bool = false,
    values: bool = false,
    prefetch: bool = false,
    write_config: bool = false,
    only: ?config.Family = null,
    bad_only: ?[]const u8 = null,
    /// `--focus <KEY>`: the ticket to land the cursor on once the first
    /// listing is in — what a row of the Work chip's hover asks for.
    /// Empty is "wherever the cursor lands".
    focus: []const u8 = "",
    config_path: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    /// `--dump --steps FILE [--size WxH]`: the headless driver behind
    /// tools/jira-diff.sh — the pane painted to stdout, no mnml.
    dump: bool = false,
    /// `--dump-style`: each `snap` also prints the row backgrounds and
    /// the row foregrounds, run-length coded. A screen dump is text and
    /// carries no colour,
    /// so this is what makes "the cursor row is a filled band"
    /// checkable from outside the process.
    dump_style: bool = false,
    steps: ?[]const u8 = null,
    size: ?[]const u8 = null,
    unknown: ?[]const u8 = null,
};

pub fn parseArgs(argv: []const []const u8) Args {
    var a: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const s = argv[i];
        if (std.mem.eql(u8, s, "--install")) a.install = true else if (std.mem.eql(u8, s, "--uninstall")) a.uninstall = true else if (std.mem.eql(u8, s, "--version") or std.mem.eql(u8, s, "-V")) a.show_version = true else if (std.mem.eql(u8, s, "--help") or std.mem.eql(u8, s, "-h")) a.help = true else if (std.mem.eql(u8, s, "--check")) a.check = true else if (std.mem.eql(u8, s, "--diag")) a.diag = true else if (std.mem.eql(u8, s, "--values")) a.values = true else if (std.mem.eql(u8, s, "--prefetch")) a.prefetch = true else if (std.mem.eql(u8, s, "--write-config") or std.mem.eql(u8, s, "--scaffold")) a.write_config = true else if (std.mem.eql(u8, s, "--only") and i + 1 < argv.len) {
            i += 1;
            a.only = config.Family.fromCli(argv[i]);
            if (a.only == null) a.bad_only = argv[i];
        } else if (std.mem.eql(u8, s, "--focus") and i + 1 < argv.len and argv[i + 1].len > 0) {
            i += 1;
            a.focus = argv[i];
        } else if (std.mem.eql(u8, s, "--config") and i + 1 < argv.len) {
            i += 1;
            a.config_path = argv[i];
        } else if (std.mem.eql(u8, s, "--workspace") and i + 1 < argv.len) {
            i += 1;
            a.workspace = argv[i];
        } else if (std.mem.eql(u8, s, "--dump")) {
            a.dump = true;
        } else if (std.mem.eql(u8, s, "--dump-style")) {
            a.dump = true;
            a.dump_style = true;
        } else if (std.mem.eql(u8, s, "--steps") and i + 1 < argv.len) {
            i += 1;
            a.steps = argv[i];
        } else if (std.mem.eql(u8, s, "--size") and i + 1 < argv.len) {
            i += 1;
            a.size = argv[i];
        } else a.unknown = s;
    }
    return a;
}

pub const usage =
    \\mnml-jira — Jira Work, Jira Fix Versions and Jira Boards as mnml panes.
    \\
    \\  --install / --uninstall   register the three chips with mnml
    \\  --version
    \\  --check                   resolved config + auth, no network
    \\  --diag                    the same plus a live /myself probe
    \\  --values [--only F]       {"assigned_open": N}; with --workspace W the
    \\                            statusline segment is published too
    \\  --prefetch --only F       the family's tabs and issues as JSON
    \\  --write-config            write config.zon and print its path
    \\  --only work|fix-versions|boards   the family a pane shows
    \\  --focus KEY               land the cursor on that ticket once the
    \\                            listing is in, and open its detail
    \\  --config PATH             the config file (else $MNML_JIRA_CONFIG, the
    \\                            workspace's, the data root's)
    \\  --dump --steps FILE [--size WxH] [--only F]
    \\                            play a step script at the pane with no mnml and
    \\                            print every `snap` as text (tools/jira-diff.sh)
    \\  --dump-style              the same, plus each snap's row backgrounds and
    \\                            foregrounds, run-length coded
    \\                            (`bg  6: 0-119 #2c323c`, `fg  6: 0-7 #61afef+b`)
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const args = parseArgs(argv);

    var out_buf: [4096]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const stdout = &out_w.interface;
    var err_buf: [1024]u8 = undefined;
    var err_w: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const stderr = &err_w.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    if (args.unknown) |u| {
        try stderr.print("mnml-jira: unknown argument {s}\n{s}", .{ u, usage });
        return 2;
    }
    if (args.bad_only) |b| {
        try stderr.print("mnml-jira: --only {s}: want work | fix-versions | boards\n", .{b});
        return 2;
    }
    if (args.help) {
        try stdout.writeAll(usage);
        return 0;
    }
    if (args.show_version) {
        try stdout.print("mnml-jira {s} (bridge protocol {d})\n", .{ version, sdk.protocol });
        return 0;
    }
    if (args.install) {
        // The issue links' `{site_url}`: this config's site, when it has
        // one — mnml cannot read config.zon, so the manifest carries it.
        const site = installSite(arena, io, env, args);
        for (specs) |s_in| {
            const s = if (site) |url| try sdk.manifest.bindLinks(arena, s_in, "site_url", url) else s_in;
            const path = sdk.manifest.write(gpa, io, env, s) catch |err| {
                try stderr.print("mnml-jira: could not write the {s} manifest: {s}\n", .{ s.id, @errorName(err) });
                return 1;
            };
            defer gpa.free(path);
            try stdout.print("mnml-jira: wrote {s}\n", .{path});
        }
        return 0;
    }
    if (args.uninstall) {
        var went: usize = 0;
        for (specs) |s| {
            if (sdk.manifest.remove(gpa, io, env, s.id) catch false) went += 1;
        }
        try stdout.print("mnml-jira: removed {d} manifest(s) (the config stays; delete it by hand)\n", .{went});
        return 0;
    }
    if (args.write_config) {
        const p = try configPath(arena, io, env, args);
        if (std.fs.path.dirname(p)) |d| Io.Dir.cwd().createDirPath(io, d) catch {};
        Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = config.example }) catch {
            try stderr.print("mnml-jira: could not write {s}\n", .{p});
            return 1;
        };
        try stdout.print("{s}\n", .{p});
        return 0;
    }

    const data_root = sdk.manifest.dataRoot(arena, env) catch null;
    const cfg_path = try configPath(arena, io, env, args);
    if (args.check or args.diag or args.values or args.prefetch or args.dump) {
        const loaded = try config.loadWithEnv(arena, io, env, cfg_path);
        // A test double's override that points nowhere: no server is
        // asked — not the fake, not the config's site.
        if (loaded.base_url_error) |why| {
            try stderr.print("mnml-jira: {s}\n", .{why});
            return 1;
        }
        const token = try auth.resolve(arena, io, env, .{ .config_path = loaded.config.token_file, .env_name = loaded.config.token_env, .data_root = data_root });
        if (args.check) return check(arena, stdout, loaded, token);
        if (args.diag) return diag(gpa, io, env, arena, stdout, loaded, token);
        if (args.values) return values(gpa, io, env, arena, stdout, stderr, loaded, token, args);
        if (args.dump) return dump(gpa, io, env, arena, stdout, stderr, loaded, token, args);
        return prefetch(gpa, io, env, arena, stdout, stderr, loaded, token, args);
    }

    const mount = sdk.Mount.connectEnv(gpa, io, env) catch |err| switch (err) {
        error.NoSocket => {
            try stderr.writeAll("mnml-jira is an mnml integration: open it from mnml (jira_work.open), or run `mnml-jira --install` / `--check`.\n");
            return 2;
        },
        else => return err,
    };
    return pane(gpa, io, env, arena, mount, args, data_root);
}

/// The site `--install` writes into the issue links: the config's
/// `.jira_url` (`$JIRA_BASE_URL` wins, as everywhere), or null when there
/// is none yet — mnml then binds it from `$JIRA_URL`, or leaves the
/// links off until the integration is set up and installed again.
pub fn installSite(arena: Allocator, io: Io, env: *const std.process.Environ.Map, args: Args) ?[]const u8 {
    const p = configPath(arena, io, env, args) catch return null;
    const loaded = config.loadWithEnv(arena, io, env, p) catch return null;
    if (loaded.base_url_error != null or loaded.parse_error != null) return null;
    const url = loaded.config.jira_url;
    if (!(std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://"))) return null;
    return url;
}

/// Where the config is: `--config`, `$MNML_JIRA_CONFIG`, the workspace's
/// file, the data root's.
pub fn configPath(arena: Allocator, io: Io, env: *const std.process.Environ.Map, args: Args) Allocator.Error![]const u8 {
    const data_root = sdk.manifest.dataRoot(arena, env) catch null;
    return config.resolvePath(arena, io, .{
        .explicit = args.config_path,
        .workspace = args.workspace orelse env.get("MNML_WORKSPACE"),
        .data_root = data_root,
    }, env.get(config.env_path));
}

// ─── the pane ────────────────────────────────────────────────────────────

const Setup = union(enum) {
    ready: struct { cfg: config.Config, token: auth.Token, path: []const u8 },
    /// A setup screen: its title and its lines.
    problem: struct { title: []const u8, lines: []const []const u8 },
};

/// Load the config and the token; either everything a pane needs or the
/// screen that says what is missing. Everything returned is on `arena`.
fn setup(arena: Allocator, io: Io, env: *const std.process.Environ.Map, cfg_path: []const u8, data_root: ?[]const u8, family: ?config.Family) Allocator.Error!Setup {
    const loaded = try config.loadWithEnv(arena, io, env, cfg_path);
    if (loaded.missing) return .{ .problem = .{ .title = "No Jira config yet.", .lines = try missingConfig(arena, cfg_path) } };
    if (loaded.parse_error) |why| return .{ .problem = .{ .title = "The config did not parse.", .lines = try parseError(arena, cfg_path, why) } };
    if (loaded.base_url_error) |why| return .{ .problem = .{ .title = "The base URL override points nowhere.", .lines = try baseUrlProblem(arena, why) } };
    var why: []const u8 = "";
    config.validate(loaded.config, &why) catch return .{ .problem = .{ .title = "The config is not usable yet.", .lines = try configProblem(arena, cfg_path, why) } };
    if (family) |f| {
        const tabs = try config.tabsOfFamily(arena, loaded.config.tabs, f);
        if (tabs.len == 0) return .{ .problem = .{ .title = "No tabs for this scope.", .lines = try noTabs(arena, cfg_path, f) } };
    }
    const token = try auth.resolve(arena, io, env, .{ .config_path = loaded.config.token_file, .env_name = loaded.config.token_env, .data_root = data_root });
    switch (token) {
        .ok => |t| return .{ .ready = .{ .cfg = loaded.config, .token = t, .path = loaded.path } },
        .missing => |m| return .{ .problem = .{ .title = "No Jira API token.", .lines = try auth.explain(arena, m) } },
    }
}

const setup_hint = "r try again · q quit";

/// The setup screen for a `$JIRA_BASE_URL` / `$BITBUCKET_BASE_URL` of
/// `@<path>` whose file never arrived.
fn baseUrlProblem(arena: Allocator, why: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, why);
    try out.append(arena, "");
    try out.append(arena, "The override is how a test points the pane at a fake server; the");
    try out.append(arena, "file is what the fake writes once it listens. Start the fake, or");
    try out.append(arena, "unset the variable to use the config's jira_url — then r.");
    return out.toOwnedSlice(arena);
}

fn pane(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, arena: Allocator, mount: *sdk.Mount, args: Args, data_root: ?[]const u8) !u8 {
    defer mount.destroy();
    var frame = try sdk.Frame.init(gpa, mount.geometry.cols, mount.geometry.rows);
    defer frame.deinit();
    const family = args.only;
    const ui: screen.Ui = .{
        .ascii = mount.hello.capabilities.ascii,
        .nerd = mount.hello.capabilities.nerd_font,
        .th = sdk.pane.Theme.fromHelloBranded(mount.hello.palette, chipColorOf(family)),
        .tab_indicator = mount.hello.tab_indicator,
    };
    try mount.setTitle(if (family) |f| f.label() else "Jira");

    var box = try inbox.Inbox.init(gpa, 64);
    defer box.deinit(io);
    var group: Io.Group = .init;
    try group.concurrent(io, inbox.Inbox.reader, .{ io, &box, mount });
    // The reader task is parked in a read on the mount, and it has to
    // be off that socket before `mount.destroy` closes it — a close
    // under a read in flight fails `EBADF`, which a Debug build calls a
    // programmer bug and panics on, so the child dies at teardown and
    // the host can only report `[connection closed]`. Registered HERE,
    // not with the app below, because the setup screens return out of
    // this function long before the app exists and every one of those
    // paths needs it too. Both halves are idempotent, so the teardown
    // below — which has to shut down BEFORE its own cancel, since
    // `app.deinit` follows it — does no harm by getting there first.
    defer {
        mount.shutdown();
        group.cancel(io);
    }

    // The setup screens first: a config or a token missing paints what
    // to do and waits for r (try again) or q. The config's strings live
    // on `arena` for the rest of the run.
    const rd = while (true) {
        // Resolved every time: a config written while the screen is up
        // is found by the next r, wherever it landed.
        const cfg_path = try configPath(arena, io, env, args);
        switch (try setup(arena, io, env, cfg_path, data_root, family)) {
            .ready => |r| break r,
            .problem => |pb| {
                screen.paintNotice(&frame, ui.th, pb.title, pb.lines, setup_hint);
                mount.send(&frame) catch return 0;
                var again = false;
                while (!again) {
                    _ = box.wait(io, 1000);
                    while (box.take(io)) |item| {
                        defer item.destroy(gpa);
                        const msg = item.msg orelse return 0;
                        switch (msg) {
                            .goodbye => return 0,
                            .resize => |r| {
                                try frame.resize(r.geometry.cols, r.geometry.rows);
                                screen.paintNotice(&frame, ui.th, pb.title, pb.lines, setup_hint);
                                mount.send(&frame) catch return 0;
                            },
                            .input => |in| switch (in.event) {
                                .key => |k| {
                                    if (std.mem.eql(u8, k.spec, "q") or std.mem.eql(u8, k.spec, "esc") or std.mem.eql(u8, k.spec, "ctrl+c")) {
                                        mount.bye();
                                        return 0;
                                    }
                                    if (std.mem.eql(u8, k.spec, "r")) again = true;
                                },
                                else => {},
                            },
                            else => {},
                        }
                    }
                    if (box.ended) return 0;
                }
            },
        }
    };
    const authorization = try auth.basicHeader(arena, rd.cfg.email, rd.token.value);
    var limiter = try openLimiter(gpa, io, env, rd.cfg.rate);
    defer limiter.deinit();
    var forge_limiter = try openForgeLimiter(gpa, io, env);
    defer forge_limiter.deinit();
    var logs = try openLogs(gpa, io, env);
    defer {
        logs.jira.deinit();
        logs.forge.deinit();
    }
    var client = jira.Client.init(gpa, io, rd.cfg.jira_url, authorization, rd.cfg.api);
    client.limiter = &limiter;
    client.log = &logs.jira;
    // One pacer per service, so a burst of background work is spread
    // one per `1/rate + margin` and never drains the bucket in front
    // of a click. Locals that are never moved: the copy of the client
    // a worker carries holds the pointer for the whole run.
    var jira_gate: sdk.warm.Gate = .forConfig(ratelimit.configFrom(rd.cfg.rate));
    var forge_gate: sdk.warm.Gate = .forConfig(sdk.ratelimit.configFor("bitbucket"));
    client.gate = &jira_gate;
    const forge_token = if (rd.cfg.bitbucket_token_env.len > 0) env.get(rd.cfg.bitbucket_token_env) else env.get("BITBUCKET_ACCESS_TOKEN");
    const forge: bitbucket.Client = .{
        .gpa = gpa,
        .io = io,
        .base_url = rd.cfg.bitbucket_api_url,
        .token = forge_token orelse "",
        .limiter = &forge_limiter,
        .log = &logs.forge,
        .gate = &forge_gate,
    };
    var app = try app_mod.App.init(gpa, io, rd.cfg, family, &client, forge);
    app.qa_tab = qaTabIndex(&app);
    // Both clients leave a long wait where the paint loop finds it.
    // `app` is a local that is never moved, so the pointer a worker's
    // copy of the client carries stays good for the whole run.
    client.notice = &app.wait_notice;
    app.forge.notice = &app.wait_notice;
    // The API budget the header chip shows and the client obeys: the
    // headers, a 429's pause, the hit ratio, the day's tally (shared
    // with every process on this data root), dry run.
    const budget_root = try sdk.request_log.dataRoot(gpa, env);
    defer gpa.free(budget_root);
    // The config's two paths — the shared bucket, the event feed —
    // relative to the config's own directory, `~/` to home.
    const config_dir = std.fs.path.dirname(rd.path) orelse "";
    app.budget.configure(io, .{
        .label = "Jira",
        .service = ratelimit.service,
        .data_root = budget_root,
        .hourly_budget = @intFromFloat(@max(rd.cfg.rate.per_sec, 0) * 3600),
        .dry_run = rd.cfg.dry_run,
        .backoff = jira.backoffFor(rd.cfg.rate),
        .shared_bucket = try sdk.feed.resolvePath(arena, env, config_dir, rd.cfg.budget.shared_bucket),
    });
    // When to ask again, and what an event file says changed.
    app.recent_root = try recent.rootFor(arena, env);
    app.recent_current_release = env.get(recent.current_release_env) orelse "";
    app.watch = .init(io, .issue, rd.cfg.refresh_interval_secs, rd.cfg.poll_max_secs, rd.cfg.feed, try sdk.feed.resolvePath(arena, env, config_dir, rd.cfg.feed.file));
    client.budget = &app.budget;
    // What the last run learned about each ticket's linked PRs, keyed
    // by the ticket's own `updated` stamp: a tab that has not moved
    // paints them on open for nothing.
    var pr_store = try openPrStore(gpa, io, env);
    defer pr_store.deinit();
    app.setPrStore(&pr_store);
    // And when each tab last came back whole, so `r` can ask only
    // about what has moved since.
    var sync_store = try openSyncStore(gpa, io, env);
    defer sync_store.deinit();
    app.setSyncStore(&sync_store);
    // The host sets this for every integration it spawns; a dispatched
    // `term` line goes to that channel and nowhere else.
    app.setIpcDir(env.get("MNML_IPC_DIR") orelse "");
    app.setOpenUrlRoute(env.get(sdk.platform.open_url_env));
    // `--focus ENG-2`: remembered now, landed at the first listing
    // that can hold it.
    if (args.focus.len > 0) app.setFocusKey(args.focus);
    // Where a saved vars edit is spliced back into.
    app.setConfigPath(rd.path);
    // Refetches go to a task on this group, so a search and its per-row
    // calls never hold the loop.
    app.setGroup(&group);
    defer {
        // The order matters: a worker parked on a put into a live queue
        // never sees the cancel, and the cancel then never returns. The
        // queue closes first, the group stops, and only then is
        // anything the workers were writing into freed.
        app.closeRefresh();
        // The inbox task is parked in a read on the mount, which a
        // cancel cannot reach into. End the stream first so the read
        // comes back on its own; `mount.destroy`'s close would
        // otherwise take the descriptor out from under it.
        mount.shutdown();
        group.cancel(io);
        app.deinit();
    }
    app.resize(frame.cols, frame.rows);
    var ipc = try sdk.Ipc.fromEnv(gpa, io, env);
    defer if (ipc) |*i| i.deinit();
    // The channel a `[ view ]` press asks for a session on.
    if (ipc) |*i| app.setIpc(i);

    // A prefetch cache paints before any fetch.
    if (env.get(prefetch_env)) |cache| if (cache.len > 0) {
        if (Io.Dir.cwd().readFileAlloc(io, cache, arena, .limited(64 * 1024 * 1024))) |src| {
            const n = try app.hydrate(src);
            if (n > 0) app.setStatus("from the prefetch cache · r refreshes", .{});
        } else |_| {}
    };

    var paint_arena = std.heap.ArenaAllocator.init(gpa);
    defer paint_arena.deinit();
    try repaint(&paint_arena, &frame, &app, ui);
    mount.send(&frame) catch return 0;
    // The first fetch is started after the first paint and lands on a
    // later tick; until it does the pane paints its empty rows and
    // answers keys, rather than freezing on a socket.
    try app.ensureLoaded();
    app.last_refresh_ms = app.nowMs();
    app.watch.started(app.last_refresh_ms);
    try repaint(&paint_arena, &frame, &app, ui);
    mount.send(&frame) catch return 0;
    publishSide(&app, mount, if (ipc) |*i| i else null, gpa, io, &limiter, .{ .ascii = ui.ascii or !ui.nerd, .glyph = sdk.pane.chipGlyphFromEnv(env, segment_glyph) });

    while (true) {
        var ended = false;
        while (box.take(io)) |item| {
            defer item.destroy(gpa);
            const msg = item.msg orelse {
                ended = true;
                break;
            };
            switch (msg) {
                .hello => {},
                .focus => |f| {
                    app.focused = f;
                    // Focus is somebody looking: the poller comes back
                    // to its base.
                    if (f) app.touched();
                },
                // A row of the hover pressed while this pane is
                // already the open one: the cursor moves, rather than
                // a second pane opening beside it.
                .focus_item => |f| try app.requestFocus(f.key),
                // The host's word on a session this pane dispatched.
                .session_state => |ss| try app.onSessionState(ss.key, ss.state, ss.session_id, ss.detail),
                .goodbye => ended = true,
                .resize => |r| {
                    try frame.resize(r.geometry.cols, r.geometry.rows);
                    app.resize(r.geometry.cols, r.geometry.rows);
                },
                .input => |in| switch (in.event) {
                    .key => |k| _ = try app.onKey(k.spec),
                    .click => |c| try app.click(c.col, c.row, c.button == .right),
                    .scroll => |s| try app.wheel(s.col, s.row, s.dy),
                    .paste => |p| try app.paste(p.text),
                    // A drag along the detail panel's scrollbar: the
                    // same jump a press there makes, once per move. A
                    // plain move is what makes a dim `[ Merge ]` say
                    // why it is dim.
                    .hover => |h| if (h.dragging) try app.drag(h.col, h.row) else {
                        try app.hover(h.col, h.row);
                        // The host's info view, told what is under the
                        // pointer (sent only when it changed).
                        // Room for the budget chip's hover, the longest.
                        var hb: [1024]u8 = undefined;
                        const help = app.helpAt(h.col, h.row, &hb);
                        var ra = std.heap.ArenaAllocator.init(gpa);
                        defer ra.deinit();
                        var with_row = help;
                        with_row.row = try app.rowRefAt(ra.allocator(), h.col, h.row);
                        mount.hoverHelp(with_row) catch {};
                    },
                },
            }
            if (ended) break;
        }
        if (ended or box.ended) break;
        // Before anything else this pass: if a request has been sitting
        // on the bucket, say so rather than leaving `loading…` to
        // stand there on its own.
        app.noteWait();
        if (app.quit) {
            mount.bye();
            break;
        }
        try app.drainRefresh();
        // The linked PRs arrive behind the paint, one at a time, in
        // the order the rows are on screen.
        try app.drainPrs();
        try app.pumpPrs();
        // A detail or a picker's transitions, fetched off the loop.
        try app.drainLooks();
        // One spinner counter for the whole pane, so every button that
        // is mid-dispatch turns together.
        if (app.actions.anyRunning()) app.spin +%= 1;
        try app.tick(app.nowMs());
        try repaint(&paint_arena, &frame, &app, ui);
        mount.send(&frame) catch break;
        publishSide(&app, mount, if (ipc) |*i| i else null, gpa, io, &limiter, .{ .ascii = ui.ascii or !ui.nerd, .glyph = sdk.pane.chipGlyphFromEnv(env, segment_glyph) });
        // While a refetch is in flight the loop wakes sooner, so its
        // rows land as soon as they arrive rather than up to half a
        // second later.
        // A spinner that only moves twice a second reads as stuck, so
        // a pane with a session running wakes at the spinner's pace.
        // A linked-PR fetch counts too: its rows replace a `loading…`
        // row under the cursor, and half a second of that row is half a
        // second of a list that is about to move. So does a detail or a
        // picker's list on the wire.
        _ = box.wait(io, if (app.refresh.busy() or app.prs.busy() or app.looks.busy()) 60 else if (app.actions.anyRunning()) 120 else 500);
    }
    return 0;
}

fn repaint(paint_arena: *std.heap.ArenaAllocator, frame: *sdk.Frame, app: *app_mod.App, ui: screen.Ui) Allocator.Error!void {
    _ = paint_arena.reset(.retain_capacity);
    try screen.paint(paint_arena.allocator(), frame, app, ui);
}

/// The toast, the statusline segment, and the sessions this pane just
/// started and wants told about.
fn publishSide(app: *app_mod.App, mount: *sdk.Mount, ipc: ?*const sdk.Ipc, gpa: Allocator, io: Io, limiter: *ratelimit.Limiter, mark: Mark) void {
    for (app.watch_out.items) |w| {
        mount.watchSession(w.key, .{ .cwd = w.cwd, .prompt_line = w.prompt_line }) catch {};
    }
    app.watch_out.clearRetainingCapacity();
    if (app.toast_pending) {
        app.toast_pending = false;
        // An offer, when the message carries one: the host paints it
        // as the button in the box (`wire.ToastAction`).
        if (app.toast_action) |act| {
            mount.toastWithAction(.info, app.toast.items, act) catch {};
        } else {
            mount.toast(.info, app.toast.items) catch {};
        }
        app.toast_action = null;
    }
    if (app.segment_dirty) {
        app.segment_dirty = false;
        // The bucket is read off its file — a lock, a read and a
        // rewrite — so it is looked at HERE, where the chip is
        // actually being published, and not once per pass of a loop
        // that runs many times a second.
        var bucket_name: [64]u8 = undefined;
        if (ipc) |i| if (app.assigned_open != null) {
            // The rows are built here, on an arena of their own, out of
            // the tabs the figures were counted off — no second search.
            var rows_arena = std.heap.ArenaAllocator.init(gpa);
            defer rows_arena.deinit();
            const ra = rows_arena.allocator();
            if (paneValues(ra, app) catch null) |v| {
                publishSegments(i, ra, v, bucketOf(gpa, io, limiter, &bucket_name), mark) catch {};
            }
            // Else the QA tab has not loaded yet: wait for it rather
            // than publish a chip that has lost its second count until
            // the next poll. Its fetch marks the chip dirty again.
        };
    }
}

/// One status and how many of the counted issues are in it.
pub const StatusCount = struct { status: []const u8, n: usize };

/// How many of the things behind a figure `--values` hands over for
/// the statusline hover to list. The host caps again at
/// `statusline.hover_items`; this is what the wire carries.
pub const hover_items: usize = 8;

/// One of the things behind a figure: a ticket. `sub` is the status it
/// is in — the hover paints it muted at the right of the row.
pub const ValuesItem = struct {
    text: []const u8,
    sub: []const u8 = "",
    /// // changed (focus-row): which ticket this row is (`ENG-2`) —
    /// what a press on the row hands the pane as `--focus`, so it
    /// lands on this one rather than leaving the reader to find it.
    /// Empty for a row that names none.
    key: []const u8 = "",
};

/// The tickets themselves, for the hover to list — key, summary, and
/// the status they sit in. Off the issues the count was taken from, so
/// the rows cost no second search.
pub fn issueItems(arena: Allocator, issues: []const model.Issue) Allocator.Error![]const ValuesItem {
    const n = @min(issues.len, hover_items);
    if (n == 0) return &.{};
    const out = try arena.alloc(ValuesItem, n);
    for (issues[0..n], 0..) |iss, i| out[i] = .{
        .text = try std.fmt.allocPrint(arena, "{s}  {s}", .{ iss.key, iss.summary }),
        .sub = if (iss.status.len > 0) iss.status else "(no status)",
        .key = iss.key,
    };
    return out;
}

/// The rows a segment publishes, each a click away from the pane.
pub fn hoverRows(arena: Allocator, items: []const ValuesItem, click: []const u8) Allocator.Error![]const sdk.ipc.Item {
    if (items.len == 0) return &.{};
    const out = try arena.alloc(sdk.ipc.Item, items.len);
    // // changed (focus-row): `args` is the row's deep link. The host
    // appends them to the command's argv when it mounts the pane, and
    // hands them down the mount as a `focus_item` when the pane is
    // already open — either way the cursor ends on THIS ticket.
    for (items, 0..) |it, i| out[i] = .{ .text = it.text, .sub = it.sub, .command = click, .args = try focusArgs(arena, it.key) };
    return out;
}

/// `--focus <KEY>` as a two-element argv, or nothing for a row that
/// names no ticket.
pub fn focusArgs(arena: Allocator, key: []const u8) Allocator.Error![]const []const u8 {
    if (key.len == 0) return &.{};
    const out = try arena.alloc([]const u8, 2);
    out[0] = "--focus";
    out[1] = key;
    return out;
}

/// What one `--values` run found. Two figures about two different
/// things, each with the breakdown that makes it mean something.
pub const Values = struct {
    assigned_open: usize = 0,
    assigned_by_status: []const StatusCount = &.{},
    /// Null when no tab is configured as QA Actionable Now — the chip
    /// is then not published at all, rather than showing a zero that
    /// would read as "nothing to do" when it means "not set up".
    qa_actionable: ?usize = null,
    qa_by_status: []const StatusCount = &.{},
    qa_tab_name: []const u8 = "",
    /// The tickets behind each figure — the rows the statusline hover
    /// lists.
    assigned_items: []const ValuesItem = &.{},
    qa_items: []const ValuesItem = &.{},
};

/// The assigned-open figure off ONE listing: the count, the status
/// breakdown the tooltip reads, and the rows the hover lists. Both the
/// `--values` run and the pane's own publish go through here, so a chip
/// republished from inside the pane carries exactly what a poll would
/// have put on it for the same issues.
pub fn assignedValues(arena: Allocator, issues: []const model.Issue) Allocator.Error!Values {
    return .{
        .assigned_open = issues.len,
        .assigned_by_status = try countByStatus(arena, issues),
        .assigned_items = try issueItems(arena, issues),
    };
}

/// The statuses of a set of issues, most-common first — the hover
/// breakdown behind a bare number.
pub fn countByStatus(arena: Allocator, issues: []const model.Issue) Allocator.Error![]const StatusCount {
    var out: std.ArrayList(StatusCount) = .empty;
    for (issues) |iss| {
        const name = if (iss.status.len > 0) iss.status else "(no status)";
        for (out.items) |*row| {
            if (std.mem.eql(u8, row.status, name)) {
                row.n += 1;
                break;
            }
        } else try out.append(arena, .{ .status = name, .n = 1 });
    }
    const Ctx = struct {
        fn lt(_: void, a: StatusCount, b: StatusCount) bool {
            if (a.n != b.n) return a.n > b.n;
            return std.mem.lessThan(u8, a.status, b.status);
        }
    };
    std.mem.sort(StatusCount, out.items, {}, Ctx.lt);
    return out.toOwnedSlice(arena);
}

/// `7 open items assigned to me — 3 In Progress · 2 In Review · 2 To Do`.
pub fn breakdownText(arena: Allocator, lead: []const u8, counts: []const StatusCount) Allocator.Error![]const u8 {
    var w: Io.Writer.Allocating = .init(arena);
    w.writer.writeAll(lead) catch return error.OutOfMemory;
    for (counts, 0..) |row, i| {
        w.writer.print("{s}{d} {s}", .{ if (i == 0) " — " else " · ", row.n, row.status }) catch return error.OutOfMemory;
    }
    return w.toOwnedSlice() catch error.OutOfMemory;
}

/// The tab the second figure counts: the first `jql_editable` tab —
/// the kind that exists for exactly this — else one whose name says so,
/// matched loosely so "QA Actionable Now", "qa_actionable" and "QA
/// actionable" all count. The name match is what keeps a config written
/// before the kind existed working.
pub fn qaTab(tabs: []const config.Tab) ?config.Tab {
    for (tabs) |t| if (t.isEditableJql()) return t;
    for (tabs) |t| if (nameIsQaActionable(t.name)) return t;
    return null;
}

fn nameIsQaActionable(name: []const u8) bool {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (name) |c| {
        if (n == buf.len) break;
        buf[n] = if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else ' ';
        n += 1;
    }
    return std.mem.indexOf(u8, buf[0..n], "qa actionable") != null;
}

/// The chip's text: the mark and the assigned figure, then ` · ` and
/// the clipboard with the QA count when a QA tab is set up and holds
/// any. One figure and no bracketed subset: a tracker has no subset of
/// "assigned to me" it can name.
pub fn segmentText(buf: []u8, v: Values, mark: Mark) []const u8 {
    const parts = [_]sdk.pane.FigurePart{.{ .glyph = if (mark.ascii) qa_ascii else qa_glyph, .n = v.qa_actionable orelse 0 }};
    return sdk.pane.figure.text(buf, .{ .glyph = mark.chip(), .n = v.assigned_open, .parts = &parts });
}

/// What the chip means, on hover: each number in words, one line
/// apiece — the assigned figure with its breakdown by status, then the
/// QA tab's.
pub fn segmentTooltip(arena: Allocator, v: Values) Allocator.Error![]const u8 {
    const lead = try std.fmt.allocPrint(arena, "{d} work item{s} assigned to you", .{ v.assigned_open, if (v.assigned_open == 1) "" else "s" });
    const first = try breakdownText(arena, lead, v.assigned_by_status);
    const n = v.qa_actionable orelse return first;
    const qlead = try std.fmt.allocPrint(arena, "{d} in your {s} tab", .{ n, if (v.qa_tab_name.len > 0) v.qa_tab_name else "QA Actionable Now" });
    return std.fmt.allocPrint(arena, "{s}\n{s}", .{ first, try breakdownText(arena, qlead, v.qa_by_status) });
}

/// The rows the hover lists: the assigned tickets, then the QA tab's
/// that are not already among them, each a click from the pane.
pub fn segmentRows(arena: Allocator, v: Values) Allocator.Error![]const sdk.ipc.Item {
    var out: std.ArrayList(sdk.ipc.Item) = .empty;
    try out.appendSlice(arena, try hoverRows(arena, v.assigned_items, segment_click));
    const tab = if (v.qa_tab_name.len > 0) v.qa_tab_name else "QA Actionable Now";
    for (try hoverRows(arena, v.qa_items, segment_click), v.qa_items) |row, it| {
        const dup = it.key.len > 0 and for (v.assigned_items) |as| {
            if (std.mem.eql(u8, as.key, it.key)) break true;
        } else false;
        if (dup) continue;
        var r = row;
        r.sub = if (row.sub.len > 0) try std.fmt.allocPrint(arena, "{s} \u{b7} {s}", .{ row.sub, tab }) else tab;
        try out.append(arena, r);
    }
    return out.toOwnedSlice(arena);
}

/// The Work chip's ONE statusline segment: the counts, the words on
/// hover, a click opens the pane — the manifest's slot, live. The owner
/// read the old second chip (the clipboard) as the same app said twice.
pub fn publishSegments(ipc: *const sdk.Ipc, arena: Allocator, v: Values, bucket: ?Bucket, mark: Mark) !void {
    var buf: [64]u8 = undefined;
    try ipc.statuslineSetSegment(.{
        .id = segment_id,
        .text = segmentText(&buf, v, mark),
        .color = segment_color,
        .click_command = segment_click,
        .priority = segment_priority,
        .tooltip = try withBucket(arena, try segmentTooltip(arena, v), bucket),
        .items = try segmentRows(arena, v),
    });
}

/// The form the pane's own refresh publishes as it goes — off the
/// listing it already holds, so it costs no request.
///
/// It goes through `publishSegments` with `assignedValues`, which is
/// the point: a chip the pane republishes for itself carries the SAME
/// breakdown and the SAME rows a `--values` run would publish for those
/// issues. It used to publish the figure alone, so the hover's list
/// vanished the moment the pane opened and did not come back until the
/// next poll five minutes later.
pub fn publishSegment(ipc: *const sdk.Ipc, arena: Allocator, issues: []const model.Issue, bucket: ?Bucket, mark: Mark) !void {
    return publishSegments(ipc, arena, try assignedValues(arena, issues), bucket, mark);
}

/// What the pane's own publish says: the assigned figure off its
/// assigned tab, and — when the config has a QA Actionable Now tab — its
/// count off that tab. Null while that tab is set up but this pane has
/// not loaded it: the chip a poll left keeps its QA count rather than
/// losing it to a publish that does not know it.
pub fn paneValues(arena: Allocator, app: *const app_mod.App) Allocator.Error!?Values {
    var v = try assignedValues(arena, app.assignedIssues());
    const qt = qaTab(app.cfg.tabs) orelse return v;
    const i = app.qa_tab orelse return null;
    if (i >= app.tabs.len or !app.tabs[i].fetched) return null;
    const issues = app.tabs[i].issues;
    v.qa_actionable = issues.len;
    v.qa_by_status = try countByStatus(arena, issues);
    v.qa_items = try issueItems(arena, issues);
    v.qa_tab_name = qt.name;
    return v;
}

/// Which of the pane's tabs is the QA Actionable Now tab the chip
/// counts, if this pane has it.
pub fn qaTabIndex(app: *const app_mod.App) ?usize {
    const qt = qaTab(app.cfg.tabs) orelse return null;
    for (app.tabs, 0..) |ts, i| if (std.mem.eql(u8, ts.cfg.name, qt.name)) return i;
    return null;
}

/// The hover text with the shared bucket's own two lines under it,
/// after a blank line (the host's trailer, under its own "click runs"
/// line rather than inside the breakdown): what it holds, at what rate, with how many throttles and how long
/// since the last 429 — and who has been spending it. It is the answer
/// to "why is this chip stale", and it is one hover away.
fn withBucket(arena: Allocator, body: []const u8, bucket: ?Bucket) Allocator.Error![]const u8 {
    const b = bucket orelse return body;
    var buf: [192]u8 = undefined;
    const line = b.status.describe(&buf);
    const d = b.draws orelse return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ body, line });
    var dbuf: [96]u8 = undefined;
    return std.fmt.allocPrint(arena, "{s}\n\n{s}\nspent by {s}", .{ body, line, d.describe(&dbuf, draws_window_secs) });
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

// ─── the setup screens' words ────────────────────────────────────────────

fn missingConfig(arena: Allocator, path: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, try std.fmt.allocPrint(arena, "Write one at {s}", .{path}));
    try out.append(arena, "or run:  mnml-jira --write-config");
    try out.append(arena, "");
    try out.append(arena, "It needs .jira_url, .email and at least one .tabs entry;");
    try out.append(arena, "the keys are the reference's TOML keys, by name.");
    try out.append(arena, "integrations/jira/README.md documents every one.");
    return out.toOwnedSlice(arena);
}

fn parseError(arena: Allocator, path: []const u8, why: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, path);
    try out.append(arena, "");
    var it = std.mem.splitScalar(u8, why, '\n');
    while (it.next()) |line| try out.append(arena, line);
    return out.toOwnedSlice(arena);
}

fn configProblem(arena: Allocator, path: []const u8, why: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, why);
    try out.append(arena, "");
    try out.append(arena, path);
    return out.toOwnedSlice(arena);
}

fn noTabs(arena: Allocator, path: []const u8, f: config.Family) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, try std.fmt.allocPrint(arena, "None of the config's tabs has a kind that belongs to `--only {s}`.", .{f.cli()}));
    try out.append(arena, path);
    try out.append(arena, "");
    try out.append(arena, switch (f) {
        .work => "Work tabs: work_open · work_reported · work_assigned · work_recently_done · work_recent · work_unified · jql_editable (with .jql + .vars) · filter.",
        .fix_versions => "Fix Versions tabs: fix_version_tree (with .project and .mode).",
        .boards => "Boards tabs: board_active_sprint · board_backlog (with .project, .board_id).",
    });
    return out.toOwnedSlice(arena);
}

// ─── --check / --diag / --values / --prefetch ────────────────────────────

fn kindName(k: ?config.TabKind) []const u8 {
    return if (k) |kk| switch (kk) {
        .work_assigned => "WorkAssigned",
        .work_reported => "WorkReported",
        .work_open => "WorkOpen",
        .jql_editable => "JqlEditable",
        .work_recently_done => "WorkRecentlyDone",
        .work_recent => "WorkRecent",
        .work_unified => "WorkUnified",
        .filter => "Filter",
        .fix_version_tree => "FixVersionTree",
        .board_active_sprint => "BoardActiveSprint",
        .board_backlog => "BoardBacklog",
    } else "Legacy";
}

fn tabLine(arena: Allocator, t: config.Tab) Allocator.Error![]const u8 {
    if (t.mode) |m| return std.fmt.allocPrint(arena, "{s} project={s}", .{ if (m == .current_release) "CurrentRelease" else "NextRelease", t.project });
    return std.fmt.allocPrint(arena, "jql = {s}", .{t.jql});
}

/// `--check`: the reference's report — the config, the tabs, and where
/// the token is (present / missing), never the token.
/// The bucket this process draws on: one file per service, shared with
/// every other mnml-jira on the machine, the statusline poller and the
/// Rust tracker. The caller owns it and hands the client a pointer.
fn openLimiter(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, rate: config.Rate) Allocator.Error!ratelimit.Limiter {
    const p = try ratelimit.statePath(gpa, io, env);
    defer gpa.free(p);
    var l = try ratelimit.Limiter.init(gpa, io, p, ratelimit.configFrom(rate));
    // So every draw on the shared bucket says who took it. Without
    // this the bucket says only how much is left, which is the half of
    // the answer that does not help.
    try l.identify(ratelimit.service, "mnml-jira", selfPid());
    // And the broker, when mnml hosts one: without this the pane's own
    // requests never queued there — only its Bitbucket calls did.
    try l.attachBroker(env, ratelimit.service);
    return l;
}

/// This process, for a draw line.
fn selfPid() i32 {
    return sdk.warm.selfPid();
}

/// The FORGE's bucket — `bitbucket`, not `jira`. The pipeline and
/// readiness calls a Work tab makes are Bitbucket requests and come out
/// of Bitbucket's allowance; they used to go out with no bucket at all,
/// so a Jira pane quietly spent it and the forge pane in the next
/// window paid with a 429.
fn openForgeLimiter(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) Allocator.Error!sdk.ratelimit.Limiter {
    var l = try sdk.ratelimit.Limiter.forService(gpa, io, env, "bitbucket");
    try l.identify("bitbucket", "mnml-jira", selfPid());
    return l;
}

/// Where a ticket's linked PRs are remembered between runs
/// (`mnml_sdk.store`). Under the host's data root, beside everything
/// else this integration keeps.
fn openPrStore(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) Allocator.Error!sdk.Store {
    const root = try sdk.request_log.dataRoot(gpa, env);
    defer gpa.free(root);
    return sdk.Store.open(gpa, io, root, ratelimit.service, "dev-status");
}

/// When each tab's listing last came back WHOLE — the mark a delta
/// window is measured from, kept between runs so the first refetch
/// after a restart is a window and not the whole thing again.
fn openSyncStore(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) Allocator.Error!sdk.Store {
    const root = try sdk.request_log.dataRoot(gpa, env);
    defer gpa.free(root);
    return sdk.Store.open(gpa, io, root, ratelimit.service, "sync");
}

/// The two request logs a Jira pane writes: its own service's, and the
/// forge's, because a call to Bitbucket belongs in Bitbucket's file
/// however it was started.
fn openLogs(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) Allocator.Error!struct { jira: sdk.RequestLog, forge: sdk.RequestLog } {
    return .{
        .jira = try sdk.RequestLog.open(gpa, io, env, ratelimit.service, "mnml-jira"),
        .forge = try sdk.RequestLog.open(gpa, io, env, "bitbucket", "mnml-jira"),
    };
}

fn check(arena: Allocator, w: *Io.Writer, loaded: config.Loaded, token: auth.Result) !u8 {
    const c = loaded.config;
    try w.print("config: {s}{s}\n", .{ loaded.path, if (loaded.missing) "  (not there yet — --write-config makes one)" else "" });
    if (loaded.parse_error) |e| try w.print("  PARSE ERROR: {s}\n", .{e});
    try w.print("  jira_url: {s}\n", .{if (c.jira_url.len > 0) c.jira_url else "(unset)"});
    try w.print("  email:    {s}\n", .{if (c.email.len > 0) c.email else "(unset)"});
    try w.print("  refresh:  {d}s\n", .{c.refresh_interval_secs});
    try w.print("  tabs:     {d}\n", .{c.tabs.len});
    for (c.tabs, 0..) |t, n| try w.print("    {d}: {s} → {s}\n", .{ n + 1, t.name, try tabLine(arena, t) });
    switch (token) {
        .ok => |t| try w.print("token:    {s} (present, {d} chars, {s})\n", .{ if (t.path.len > 0) t.path else "$" ++ auth.default_env, t.value.len, t.source.label() }),
        .missing => |m| try w.print("token:    {s} (missing: {s}; also looked at ${s})\n", .{ m.path, @tagName(m.reason), m.env_name }),
    }
    var why: []const u8 = "";
    config.validate(c, &why) catch {
        try w.print("problem:  {s}\n", .{why});
        return 1;
    };
    return 0;
}

/// `--diag`: the reference's tree, with the live /myself probe.
fn diag(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, arena: Allocator, w: *Io.Writer, loaded: config.Loaded, token: auth.Result) !u8 {
    const c = loaded.config;
    try w.writeAll("mnml-jira · diagnostics\n\nAuth\n");
    switch (token) {
        .ok => |t| {
            try w.print("  ├─ token source: {s}\n", .{if (t.path.len > 0) t.path else "$" ++ auth.default_env});
            try w.print("  ├─ token length: {d} chars\n", .{t.value.len});
        },
        .missing => |m| try w.print("  ├─ token: MISSING ({s}; looked at ${s} and {s})\n", .{ @tagName(m.reason), m.env_name, m.path }),
    }
    try w.print("  ├─ email: {s}\n", .{if (c.email.len > 0) c.email else "(unset)"});
    try w.print("  ├─ jira_url: {s}\n", .{if (c.jira_url.len > 0) c.jira_url else "(unset)"});
    if (token == .ok and c.jira_url.len > 0) {
        const authorization = try auth.basicHeader(arena, c.email, token.ok.value);
        var limiter = try openLimiter(gpa, io, env, c.rate);
        defer limiter.deinit();
        var log = try sdk.RequestLog.open(gpa, io, env, ratelimit.service, "mnml-jira");
        defer log.deinit();
        var client = jira.Client.init(gpa, io, c.jira_url, authorization, c.api);
        client.limiter = &limiter;
        client.log = &log;
        switch (jira.myself(&client, arena) catch jira.Answer(model.User){ .failed = .{ .status = 0, .message = "the site did not answer" } }) {
            .ok => |u| try w.print("  └─ /myself: ✓ account_id={s}\n", .{u.account_id}),
            .failed => |f| try w.print("  └─ /myself: ✗ {s}\n", .{f.message}),
        }
    } else try w.writeAll("  └─ /myself: skipped (no token or no jira_url)\n");
    try w.writeAll("\nConfig\n");
    try w.print("  ├─ path: {s}{s}\n", .{ loaded.path, if (loaded.missing) " (missing)" else "" });
    if (loaded.parse_error) |e| try w.print("  ├─ PARSE ERROR: {s}\n", .{e});
    try w.print("  ├─ jira_url: {s}\n", .{if (c.jira_url.len > 0) c.jira_url else "(unset)"});
    if (c.projects.len == 0) try w.writeAll("  ├─ projects allowlist: (none — spans every visible project)\n") else try w.print("  ├─ projects allowlist: {s}\n", .{try std.mem.join(arena, ", ", c.projects)});
    try w.print("  └─ tabs: {d}\n", .{c.tabs.len});
    for (c.tabs, 0..) |t, n| try w.print("      {d}. {s} (kind={s})\n", .{ n + 1, t.name, kindName(t.kind) });
    try w.writeAll("\nRuntime\n");
    try w.print("  ├─ integration: {s}\n", .{version});
    try w.print("  └─ os/arch: {s} / {s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    return 0;
}

/// `--values`: what a statusline poller reads — two figures, each with
/// the per-status breakdown that makes a bare number mean something.
/// With `--workspace W` (which the host's poller always passes) the two
/// segments are published over that workspace's channel too, so the
/// chips move with no pane open.
///
/// The second figure is the tab the user has set up as QA Actionable
/// Now — a `jql_editable` tab, else one found by name; with no such tab
/// the key is `null` and the chip is not published, which is not the
/// same as a zero.
fn values(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, arena: Allocator, out: *Io.Writer, err: *Io.Writer, loaded: config.Loaded, token: auth.Result, args: Args) !u8 {
    const c = loaded.config;
    const t: auth.Token = switch (token) {
        .ok => |v| v,
        .missing => |m| {
            try err.print("mnml-jira --values: no token ({s})\n", .{@tagName(m.reason)});
            try out.writeAll("{\"assigned_open\":null}\n");
            return 1;
        },
    };
    if (c.jira_url.len == 0) {
        try err.writeAll("mnml-jira --values: no jira_url in the config\n");
        try out.writeAll("{\"assigned_open\":null}\n");
        return 1;
    }
    var limiter = try openLimiter(gpa, io, env, c.rate);
    defer limiter.deinit();
    var log = try sdk.RequestLog.open(gpa, io, env, ratelimit.service, "mnml-jira");
    defer log.deinit();
    var client = jira.Client.init(gpa, io, c.jira_url, try auth.basicHeader(arena, c.email, t.value), c.api);
    client.limiter = &limiter;
    client.log = &log;

    // Under a quarter of the shared bucket, a poll is the thing that
    // gives way: nothing is watching this run, and what is left
    // belongs to whoever is. The line says so rather than leaving a
    // chip that stopped moving unexplained.
    if (sdk.warm.underBudget(limiter.status())) {
        try err.print("mnml-jira --values: {s}\n", .{sdk.warm.skipped_budget});
        try out.print("{{\"assigned_open\":null,\"skipped\":\"{s}\"}}\n", .{sdk.warm.skipped_budget});
        return 0;
    }
    var gate: sdk.warm.Gate = .forConfig(ratelimit.configFrom(c.rate));
    client.gate = &gate;

    var v: Values = .{};
    // Every listing this run polls also lands in the shared
    // recent-items cache (`src/recent.zig`), so a key elsewhere gets
    // its title. Never a request of its own.
    const recent_root = try recent.rootFor(arena, env);
    const base = config.TabKind.work_assigned.defaultJql().?;
    const jql = try jira.withProjects(arena, base, c.projects);
    switch (jira.search(&client, arena, jql, &.{}, .poll) catch jira.Answer([]const std.json.Value){ .failed = .{ .status = 0, .message = "the site did not answer" } }) {
        .ok => |items| {
            const issues = try jira.parseIssues(arena, items, c.team_field_id);
            _ = recent.publish(gpa, io, recent_root, "assigned_open", true, c.refresh_interval_secs, issues);
            const a = try assignedValues(arena, issues);
            v.assigned_open = a.assigned_open;
            v.assigned_by_status = a.assigned_by_status;
            v.assigned_items = a.assigned_items;
        },
        .failed => |f| {
            recent.failed(gpa, io, recent_root);
            try err.print("mnml-jira --values: {s}\n", .{f.message});
            try out.writeAll("{\"assigned_open\":null}\n");
            return 1;
        },
    }

    // The second figure, when the user has a tab for it. A failure here
    // is not a failure of the run: the first chip is still worth
    // publishing, so this says so on stderr and leaves the key null.
    if (qaTab(c.tabs)) |tab| {
        v.qa_tab_name = tab.name;
        if (try tab.staticJql(arena)) |qa_jql| {
            const scoped = try jira.withProjects(arena, qa_jql, c.projects);
            switch (jira.search(&client, arena, scoped, &.{}, .poll) catch jira.Answer([]const std.json.Value){ .failed = .{ .status = 0, .message = "the site did not answer" } }) {
                .ok => |items| {
                    const issues = try jira.parseIssues(arena, items, c.team_field_id);
                    _ = recent.publish(gpa, io, recent_root, "qa_actionable", true, c.refresh_interval_secs, issues);
                    v.qa_actionable = items.len;
                    v.qa_by_status = try countByStatus(arena, issues);
                    v.qa_items = try issueItems(arena, issues);
                },
                .failed => |f| try err.print("mnml-jira --values: {s}: {s}\n", .{ tab.name, f.message }),
            }
        } else try err.print("mnml-jira --values: the tab `{s}` has no jql to run\n", .{tab.name});
    }

    try out.print("{{\"assigned_open\":{d}", .{v.assigned_open});
    if (v.qa_actionable) |n| try out.print(",\"qa_actionable\":{d}", .{n}) else try out.writeAll(",\"qa_actionable\":null");
    try out.writeAll("}\n");

    if (try ipcFor(gpa, io, env, args.workspace)) |*ipc_ptr| {
        var name_buf: [64]u8 = undefined;
        var ipc = ipc_ptr.*;
        defer ipc.deinit();
        publishSegments(&ipc, arena, v, bucketOf(gpa, io, &limiter, &name_buf), Mark.fromEnv(env)) catch |e| try err.print("mnml-jira --values: could not publish the segments: {s}\n", .{@errorName(e)});
    }
    return 0;
}

/// The channel to publish on: `$MNML_IPC_DIR` when the host set it —
/// the only mnml that will act on the line — else the workspace's own
/// `<ws>/.mnml/ipc-zig`. Never the Rust host's `ipc` name, which is a
/// directory a Zig instance does not read.
fn ipcFor(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, workspace: ?[]const u8) Allocator.Error!?sdk.Ipc {
    if (try sdk.Ipc.fromEnv(gpa, io, env)) |ipc| return ipc;
    const ws = workspace orelse return null;
    if (ws.len == 0) return null;
    const dir = try std.fs.path.join(gpa, &.{ ws, ".mnml", dispatch.ipc_subdir });
    defer gpa.free(dir);
    if (Io.Dir.cwd().access(io, dir, .{})) |_| {} else |_| return null;
    return try sdk.Ipc.init(gpa, io, dir);
}

/// `--prefetch --only F`: the family's tabs and their issues as JSON, the
/// shape the pane hydrates from (`{"generated_at":…,"tabs":[{"name","issues"}]}`).
fn prefetch(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, arena: Allocator, out: *Io.Writer, err: *Io.Writer, loaded: config.Loaded, token: auth.Result, args: Args) !u8 {
    const c = loaded.config;
    const t: auth.Token = switch (token) {
        .ok => |v| v,
        .missing => |m| {
            try err.print("mnml-jira --prefetch: no token ({s})\n", .{@tagName(m.reason)});
            return 1;
        },
    };
    var limiter = try openLimiter(gpa, io, env, c.rate);
    defer limiter.deinit();
    var log = try sdk.RequestLog.open(gpa, io, env, ratelimit.service, "mnml-jira");
    defer log.deinit();
    var client = jira.Client.init(gpa, io, c.jira_url, try auth.basicHeader(arena, c.email, t.value), c.api);
    client.limiter = &limiter;
    client.log = &log;
    const tabs = try config.tabsOfFamily(arena, c.tabs, args.only);
    var w: std.json.Stringify = .{ .writer = out, .options = .{} };
    try w.beginObject();
    try w.objectField("generated_at");
    try w.write(@divTrunc(Io.Timestamp.now(io, .real).toMilliseconds(), 1000));
    try w.objectField("tabs");
    try w.beginArray();
    const extra: []const []const u8 = if (c.team_field_id.len > 0) &.{c.team_field_id} else &.{};
    for (tabs) |tab| {
        try w.beginObject();
        try w.objectField("name");
        try w.write(tab.name);
        try w.objectField("issues");
        try w.beginArray();
        const jql = (try tab.staticJql(arena)) orelse "";
        if (tab.board_id != 0) {
            switch (jira.boardIssues(&client, arena, tab.board_id, null, extra, .prefetch) catch jira.Answer([]const std.json.Value){ .failed = .{ .status = 0, .message = "the site did not answer" } }) {
                .ok => |items| for (items) |v| try w.write(v),
                .failed => |f| try err.print("mnml-jira --prefetch: {s}: {s}\n", .{ tab.name, f.message }),
            }
        } else if (jql.len > 0) {
            const q = if (tab.team.len > 0) try jira.withTeam(arena, jql, tab.team, c.team_field_name, c.team_field_id) else jql;
            switch (jira.search(&client, arena, q, extra, .prefetch) catch jira.Answer([]const std.json.Value){ .failed = .{ .status = 0, .message = "the site did not answer" } }) {
                .ok => |items| for (items) |v| try w.write(v),
                .failed => |f| try err.print("mnml-jira --prefetch: {s}: {s}\n", .{ tab.name, f.message }),
            }
        }
        try w.endArray();
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
    try out.writeAll("\n");
    return 0;
}

// ─── --dump: the headless driver ─────────────────────────────────────────

/// `--dump --steps FILE [--size WxH] [--only F]`: the same App and the
/// same paint as the pane, driven by the capture tool's step grammar
/// (`key`, `type`, `click`, `rclick`, `clickon`, `rclickon`,
/// `clickafter`, `scroll`, `snap`, `expect`; the waits are no-ops since
/// every fetch is synchronous). Each `snap NAME` prints `=== NAME` and
/// the screen, one row per line — what tools/jira-diff.sh compares with
/// the reference's dumps.
fn dump(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, arena: Allocator, out: *Io.Writer, err: *Io.Writer, loaded: config.Loaded, token: auth.Result, args: Args) !u8 {
    const c = loaded.config;
    const t: auth.Token = switch (token) {
        .ok => |v| v,
        .missing => |m| {
            try err.print("mnml-jira --dump: no token ({s})\n", .{@tagName(m.reason)});
            return 1;
        },
    };
    var why: []const u8 = "";
    config.validate(c, &why) catch {
        try err.print("mnml-jira --dump: {s}\n", .{why});
        return 1;
    };
    var cols: u16 = 120;
    var rows: u16 = 40;
    if (args.size) |sz| if (std.mem.indexOfScalar(u8, sz, 'x')) |x| {
        cols = std.fmt.parseInt(u16, sz[0..x], 10) catch cols;
        rows = std.fmt.parseInt(u16, sz[x + 1 ..], 10) catch rows;
    };
    const steps_src = if (args.steps) |p| try Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(1 << 20)) else "snap screen\n";
    var limiter = try openLimiter(gpa, io, env, c.rate);
    defer limiter.deinit();
    var forge_limiter = try openForgeLimiter(gpa, io, env);
    defer forge_limiter.deinit();
    var logs = try openLogs(gpa, io, env);
    defer {
        logs.jira.deinit();
        logs.forge.deinit();
    }
    var client = jira.Client.init(gpa, io, c.jira_url, try auth.basicHeader(arena, c.email, t.value), c.api);
    client.limiter = &limiter;
    client.log = &logs.jira;
    const forge_token = if (c.bitbucket_token_env.len > 0) env.get(c.bitbucket_token_env) else env.get("BITBUCKET_ACCESS_TOKEN");
    var app = try app_mod.App.init(gpa, io, c, args.only, &client, .{
        .gpa = gpa,
        .io = io,
        .base_url = c.bitbucket_api_url,
        .token = forge_token orelse "",
        .limiter = &forge_limiter,
        .log = &logs.forge,
    });
    client.notice = &app.wait_notice;
    app.forge.notice = &app.wait_notice;
    var pr_store = try openPrStore(gpa, io, env);
    defer pr_store.deinit();
    app.setPrStore(&pr_store);
    // A dump takes the same two caches the pane does, so what it
    // measures is what a pane would have spent.
    var sync_store = try openSyncStore(gpa, io, env);
    defer sync_store.deinit();
    app.setSyncStore(&sync_store);
    app.setIpcDir(env.get("MNML_IPC_DIR") orelse "");
    app.setOpenUrlRoute(env.get(sdk.platform.open_url_env));
    if (args.focus.len > 0) app.setFocusKey(args.focus);
    defer app.deinit();
    app.resize(cols, rows);
    var frame = try sdk.Frame.init(gpa, cols, rows);
    defer frame.deinit();
    var paint_arena = std.heap.ArenaAllocator.init(gpa);
    defer paint_arena.deinit();
    const ui: screen.Ui = .{ .th = sdk.pane.Theme.fromHelloBranded(dump_palette, chipColorOf(args.only)) };
    try app.ensureLoaded();
    // A dump has no loop to spread the linked-PR calls over, so they
    // all happen here — the rows a dump asserts on are the rows a pane
    // reaches a moment later.
    try app.drainPrQueue();
    try repaint(&paint_arena, &frame, &app, ui);
    var lines = std.mem.splitScalar(u8, steps_src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const verb = line[0..sp];
        const rest = std.mem.trimStart(u8, line[sp..], " ");
        if (std.mem.eql(u8, verb, "key")) {
            _ = try app.onKey(rest);
        } else if (std.mem.eql(u8, verb, "type")) {
            var it = std.unicode.Utf8View.initUnchecked(rest).iterator();
            while (it.nextCodepointSlice()) |cp| {
                if (cp.len == 1 and cp[0] == ' ') {
                    _ = try app.onKey("space");
                } else if (cp.len == 1 and std.ascii.isUpper(cp[0])) {
                    var kb: [8]u8 = undefined;
                    _ = try app.onKey(std.fmt.bufPrint(&kb, "shift+{c}", .{std.ascii.toLower(cp[0])}) catch cp);
                } else _ = try app.onKey(cp);
            }
        } else if (std.mem.eql(u8, verb, "click") or std.mem.eql(u8, verb, "rclick")) {
            var it = std.mem.tokenizeScalar(u8, rest, ' ');
            const x = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            const y = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            try app.click(x, y, std.mem.eql(u8, verb, "rclick"));
        } else if (std.mem.eql(u8, verb, "clickon") or std.mem.eql(u8, verb, "rclickon") or std.mem.eql(u8, verb, "clickafter")) {
            var needle = rest;
            var after: u16 = 0;
            if (std.mem.eql(u8, verb, "clickafter")) {
                const last = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse rest.len;
                after = std.fmt.parseInt(u16, rest[@min(last + 1, rest.len)..], 10) catch 0;
                needle = std.mem.trimEnd(u8, rest[0..last], " ");
            }
            if (try findOnScreen(arena, &frame, needle)) |at| {
                const x = if (after > 0) at.x + @as(u16, @intCast(std.unicode.utf8CountCodepoints(needle) catch needle.len)) + after else at.x;
                try app.click(x, at.y, std.mem.eql(u8, verb, "rclickon"));
            } else try err.print("mnml-jira --dump: {s} '{s}': not on screen\n", .{ verb, needle });
        } else if (std.mem.eql(u8, verb, "scroll")) {
            var it = std.mem.tokenizeScalar(u8, rest, ' ');
            const x = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            const y = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            const dir = it.next() orelse "down";
            try app.wheel(x, y, if (std.mem.eql(u8, dir, "up")) 1 else -1);
        } else if (std.mem.eql(u8, verb, "snap")) {
            try repaint(&paint_arena, &frame, &app, ui);
            try out.print("=== {s}\n", .{rest});
            try out.writeAll(try screen.screenText(arena, &frame));
            if (args.dump_style) {
                try out.writeAll("\n--- bg\n");
                try out.writeAll(try sdk.frame.bgDump(arena, &frame));
                try out.writeAll("\n--- fg\n");
                try out.writeAll(try sdk.frame.fgDump(arena, &frame));
            }
        } else if (std.mem.eql(u8, verb, "expect")) {
            try repaint(&paint_arena, &frame, &app, ui);
            if ((try findOnScreen(arena, &frame, rest)) == null) {
                try err.print("mnml-jira --dump: expect '{s}': not on screen\n", .{rest});
                return 1;
            }
        } else if (std.mem.eql(u8, verb, "quit")) {
            break;
        }
        // wait / settle / waitfor / waitsoft / find: nothing to wait for.
        try repaint(&paint_arena, &frame, &app, ui);
        if (app.quit) break;
    }
    return 0;
}

/// The palette `--dump` paints with. A dump has no host and so no
/// `hello.palette`, and painting with the 16-colour fallback makes a
/// style dump read `i0` where the pane in mnml has a real colour —
/// which is no use for checking that a row's ground is the one the
/// theme asked for. These are mnml's own default (onedark) roles, the
/// shape every host palette has.
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

const At = struct { x: u16, y: u16 };

fn findOnScreen(arena: Allocator, frame: *const sdk.Frame, needle: []const u8) Allocator.Error!?At {
    var y: u16 = 0;
    while (y < frame.rows) : (y += 1) {
        const row = try screen.rowText(arena, frame, y);
        if (std.mem.indexOf(u8, row, needle)) |byte| {
            return .{ .x = @intCast(std.unicode.utf8CountCodepoints(row[0..byte]) catch byte), .y = y };
        }
    }
    return null;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test {
    // Every module's tests run under `zig build test`, not only the ones
    // main.zig happens to call.
    testing.refAllDecls(@This());
}

test "the three manifests: one binary, three families, the Work chip carries the statusline segment" {
    try testing.expectEqualStrings("jira_work", spec_work.id);
    try testing.expectEqualStrings("jira_fix_versions", spec_fix_versions.id);
    try testing.expectEqualStrings("jira_boards", spec_boards.id);
    for (specs) |s| {
        try testing.expectEqualStrings("mnml-jira", s.binary);
        try testing.expectEqualStrings("--only", s.commands[0].args[0]);
        try testing.expect(config.Family.fromCli(s.commands[0].args[1]) != null);
        try testing.expect(s.chip != null);
        try testing.expect(!s.chip.?.in_palette_bar);
        try testing.expectEqual(@as(usize, 3), s.auth.len);
        try sdk.manifest.validateId(s.id);
    }
    // Each chip wears Atlassian's own mark for its surface, baked into
    // MnmlSymbols at these codepoints (`src/glyph/builder.zig`'s
    // `atl_work_items` / `atl_board` / `atl_release`). The Work chip's
    // statusline count keeps the Jira logo.
    try testing.expectEqualStrings("\u{f1c19}", spec_work.chip.?.glyph);
    try testing.expectEqualStrings("\u{f1c17}", spec_boards.chip.?.glyph);
    try testing.expectEqualStrings("\u{f1c18}", spec_fix_versions.chip.?.glyph);
    // ONE chip: the owner read the old second chip (the clipboard) as
    // the same app said twice. It carries its resting hover text and
    // the short label the Segments menu reads.
    try testing.expectEqual(@as(usize, 1), spec_work.statusline.len);
    try testing.expectEqualStrings("jira_work.open", spec_work.statusline[0].click_command.?);
    try testing.expectEqualStrings("#1B5DCF", spec_work.statusline[0].color.?);
    try testing.expectEqualStrings("assigned", spec_work.statusline[0].id);
    try testing.expectEqualStrings("assigned, QA actionable", spec_work.statusline[0].label.?);
    try testing.expect(spec_work.statusline[0].tooltip != null);
    // The id the binary publishes on is the manifest's own slot,
    // prefixed with the manifest id — a mismatch is a chip that never
    // moves, which is only visible by running it.
    try testing.expectEqualStrings(segment_id, "jira_work." ++ "assigned");
    try testing.expect(!std.mem.eql(u8, retired_segment_id, segment_id));
    try testing.expectEqual(@as(usize, 0), spec_boards.statusline.len);
    // The issue key links, on the Work chip alone, any project's key.
    try testing.expectEqual(@as(usize, 1), spec_work.links.len);
    try testing.expectEqualStrings("[A-Z][A-Z0-9]+-\\d+", spec_work.links[0].pattern);
    try testing.expectEqualStrings("{site_url}/browse/{0}", spec_work.links[0].url);
    try testing.expectEqual(@as(usize, 0), spec_boards.links.len);
    try testing.expectEqual(@as(usize, 0), spec_fix_versions.links.len);
}

test "--install writes the configured site into the issue links; without a site the template stays for mnml to bind" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("MNML_DATA_ROOT", root);
    const args = parseArgs(&.{ "mnml-jira", "--install" });
    // No config yet: nothing to bind.
    try testing.expect(installSite(arena, testing.io, &env, args) == null);
    try tmp.dir.createDirPath(testing.io, "integrations/jira");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "integrations/jira/config.zon", .data = ".{ .jira_url = \"https://acme.example.com/\", .email = \"me@example.com\" }" });
    const site = installSite(arena, testing.io, &env, args).?;
    try testing.expectEqualStrings("https://acme.example.com", site);
    const bound = try sdk.manifest.bindLinks(arena, spec_work, "site_url", site);
    try testing.expectEqualStrings("https://acme.example.com/browse/{0}", bound.links[0].url);
}

test "the arguments parse as the reference's, and a bad --only is named" {
    const a = parseArgs(&.{ "mnml-jira", "--only", "fix-versions", "--config", "/x.zon", "--workspace", "/ws" });
    try testing.expectEqual(config.Family.fix_versions, a.only.?);
    try testing.expectEqualStrings("/x.zon", a.config_path.?);
    try testing.expectEqualStrings("/ws", a.workspace.?);
    const b = parseArgs(&.{ "mnml-jira", "--only", "nope" });
    try testing.expect(b.only == null);
    try testing.expectEqualStrings("nope", b.bad_only.?);
    const c = parseArgs(&.{ "mnml-jira", "--values", "--prefetch", "--check", "--diag", "--install" });
    try testing.expect(c.values and c.prefetch and c.check and c.diag and c.install);
    try testing.expectEqualStrings("--wat", parseArgs(&.{ "mnml-jira", "--wat" }).unknown.?);
}

/// Three tickets, the shape a listing hands the chip.
const chip_issues = [_]model.Issue{
    .{ .key = "ENG-1", .summary = "Checkout rewrite", .status = "In Progress" },
    .{ .key = "ENG-5", .summary = "Basket total wrong with a voucher", .status = "To Do" },
    .{ .key = "ENG-9", .summary = "Stale session after a password change", .status = "In Progress" },
};

test "the statusline segment is the manifest's slot, live: the exact IPC line" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    var ipc = try sdk.Ipc.init(testing.allocator, testing.io, dir);
    defer ipc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try publishSegment(&ipc, arena, &chip_issues, null, .{});
    const line = try tmp.dir.readFileAlloc(testing.io, "command", arena, .unlimited);
    // The text starts with the chip's glyph — `segment_glyph` is the
    // manifest's, so a chip change never leaves this line behind.
    try testing.expectEqualStrings(
        "{\"cmd\":\"statusline-set-segment\",\"id\":\"jira_work.assigned\",\"side\":\"right\",\"text\":\"" ++ segment_glyph ++ " 3\",\"color\":\"#1B5DCF\",\"click_command\":\"jira_work.open\",\"priority\":60,\"min_width\":4,\"max_width\":30," ++
            "\"tooltip\":\"3 work items assigned to you — 2 In Progress · 1 To Do\"," ++
            // Each row carries `focus-row`'s deep link, so a press from
            // the hover of a chip the PANE published lands on that
            // ticket just as it does from the poll's.
            "\"items\":[" ++
            "{\"text\":\"ENG-1  Checkout rewrite\",\"sub\":\"In Progress\",\"command\":\"jira_work.open\",\"args\":[\"--focus\",\"ENG-1\"]}," ++
            "{\"text\":\"ENG-5  Basket total wrong with a voucher\",\"sub\":\"To Do\",\"command\":\"jira_work.open\",\"args\":[\"--focus\",\"ENG-5\"]}," ++
            "{\"text\":\"ENG-9  Stale session after a password change\",\"sub\":\"In Progress\",\"command\":\"jira_work.open\",\"args\":[\"--focus\",\"ENG-9\"]}]}\n",
        line,
    );
    // The manifest's static slot and the live one name the same thing.
    try testing.expectEqualStrings(spec_work.statusline[0].color.?, segment_color);
    try testing.expectEqualStrings(spec_work.statusline[0].click_command.?, segment_click);
    try testing.expect(std.mem.endsWith(u8, segment_id, spec_work.statusline[0].id));
}

test "the pane's own publish keeps the QA count: it waits for the QA tab rather than drop the part" {
    // One chip carries both counts now, so a publish from a pane that
    // has not loaded its QA tab would wipe the QA part the last poll
    // put there until the next poll, five minutes later.
    const tabs = [_]config.Tab{
        .{ .name = "Assigned", .kind = .work_assigned },
        .{ .name = "QA Actionable Now", .kind = .work_open },
    };
    const h = try app_mod.Harness.start(.{ .tabs = &tabs }, .work);
    defer h.stop();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    h.app.qa_tab = qaTabIndex(&h.app);
    try testing.expectEqual(@as(?usize, 1), h.app.qa_tab);
    h.app.tabs[1].fetched = false;
    try testing.expect((try paneValues(arena, &h.app)) == null);
    h.app.tabs[1].fetched = true;
    const v = (try paneValues(arena, &h.app)).?;
    try testing.expectEqual(@as(?usize, h.app.tabs[1].issues.len), v.qa_actionable);
    try testing.expectEqualStrings("QA Actionable Now", v.qa_tab_name);
    // No QA tab in the config: the assigned figure alone, at once.
    const plain = try app_mod.Harness.start(.{ .tabs = &app_mod.work_tabs }, .work);
    defer plain.stop();
    try testing.expect(qaTabIndex(&plain.app) == null);
    try testing.expect((try paneValues(arena, &plain.app)).?.qa_actionable == null);
}

test "the pane's own publish is the `--values` publish for the same listing, rows and all" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // What the pane sends for the listing it holds…
    var pane_tmp = testing.tmpDir(.{});
    defer pane_tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    var pane_ipc = try sdk.Ipc.init(testing.allocator, testing.io, pbuf[0..try pane_tmp.dir.realPath(testing.io, &pbuf)]);
    defer pane_ipc.deinit();
    try publishSegment(&pane_ipc, arena, &chip_issues, null, .{});
    const pane_line = try pane_tmp.dir.readFileAlloc(testing.io, "command", arena, .unlimited);

    // …and what a `--values` run sends for the same issues. Byte for
    // byte the same line: the chip does not lose its rows the moment
    // somebody opens the pane behind it.
    var poll_tmp = testing.tmpDir(.{});
    defer poll_tmp.cleanup();
    var qbuf: [std.fs.max_path_bytes]u8 = undefined;
    var poll_ipc = try sdk.Ipc.init(testing.allocator, testing.io, qbuf[0..try poll_tmp.dir.realPath(testing.io, &qbuf)]);
    defer poll_ipc.deinit();
    try publishSegments(&poll_ipc, arena, try assignedValues(arena, &chip_issues), null, .{});
    const poll_line = try poll_tmp.dir.readFileAlloc(testing.io, "command", arena, .unlimited);

    try testing.expectEqualStrings(poll_line, pane_line);
    // And it is a line WITH rows on it — an empty `items` would make
    // the two agree for the wrong reason.
    try testing.expect(std.mem.indexOf(u8, pane_line, "\"items\":[{\"text\":\"ENG-1  Checkout rewrite\"") != null);
}

test "the pane's own limiter is pointed at the broker the environment names, and at none under MNML_BROKER=0" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("JIRA_RATELIMIT_STATE", "/tmp/jira-wire-test-bucket.json");
    try env.put("JIRA_BROKER_SOCKET", "/tmp/jira-wire-test-broker.sock");
    var l = try openLimiter(testing.allocator, testing.io, &env, .{});
    defer l.deinit();
    try testing.expectEqualStrings("/tmp/jira-wire-test-broker.sock", l.broker_socket);
    try testing.expectEqualStrings("/tmp/jira-wire-test-bucket.json", l.path);

    try env.put("MNML_BROKER", "0");
    var off = try openLimiter(testing.allocator, testing.io, &env, .{});
    defer off.deinit();
    try testing.expectEqualStrings("", off.broker_socket);
}

test "--check prints the config and where the token is, never the token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const loaded = try config.parse(ar,
        \\.{ .jira_url = "https://acme.atlassian.net", .email = "me@acme.com", .tabs = .{ .{ .name = "Assigned", .kind = .work_assigned }, .{ .name = "Current Release", .kind = .fix_version_tree, .project = "ENG", .mode = .current_release } } }
    , "/tmp/config.zon");
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const code = try check(ar, &w, loaded, .{ .ok = .{ .value = "sekret-token-value", .source = .default_file, .path = "/home/x/token" } });
    try testing.expectEqual(@as(u8, 0), code);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "config: /tmp/config.zon") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  jira_url: https://acme.atlassian.net") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  refresh:  60s") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    1: Assigned → jql = ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    2: Current Release → CurrentRelease project=ENG") != null);
    try testing.expect(std.mem.indexOf(u8, out, "token:    /home/x/token (present, 18 chars") != null);
    try testing.expect(std.mem.indexOf(u8, out, "sekret") == null);
}

test "the prefetch cache hydrates the tabs it names before any fetch" {
    const h = try app_mod.Harness.start(.{ .tabs = &app_mod.work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    const src =
        \\{"generated_at":1,"tabs":[{"name":"Assigned","issues":[{"id":"1","key":"ENG-9","fields":{"summary":"From the cache","status":{"name":"To Do","statusCategory":{"key":"new"}},"issuetype":{"name":"Task"}}}]},{"name":"Nope","issues":[]}]}
    ;
    try testing.expectEqual(@as(usize, 1), try a.hydrate(src));
    try testing.expect(a.tab().fetched);
    try testing.expectEqual(@as(usize, 1), a.tab().issues.len);
    try testing.expectEqualStrings("ENG-9", a.tab().issues[0].key);
    try testing.expectEqualStrings("From the cache", a.tab().issues[0].summary);
    try testing.expectEqual(@as(?usize, 1), a.assigned_open);
    // ensureLoaded is satisfied; r fetches the real three.
    try a.ensureLoaded();
    try testing.expectEqual(@as(usize, 1), a.tab().issues.len);
    _ = try a.onKey("r");
    try testing.expectEqual(@as(usize, 3), a.tab().issues.len);
}

test "the breakdown is by status, most common first, and the tooltip reads as a sentence" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const issues = [_]model.Issue{
        .{ .key = "ENG-1", .status = "In Progress" },
        .{ .key = "ENG-2", .status = "To Do" },
        .{ .key = "ENG-3", .status = "In Progress" },
        .{ .key = "ENG-4", .status = "In Review" },
        .{ .key = "ENG-5", .status = "In Progress" },
        .{ .key = "ENG-6", .status = "" },
    };
    // A missing status is counted, not dropped: six issues in, six out.
    const counts = try countByStatus(arena, &issues);
    try testing.expectEqual(@as(usize, 4), counts.len);
    try testing.expectEqualStrings("In Progress", counts[0].status);
    try testing.expectEqual(@as(usize, 3), counts[0].n);
    // A tie breaks by name, so the order is the same every run.
    try testing.expectEqualStrings("(no status)", counts[1].status);
    try testing.expectEqualStrings("In Review", counts[2].status);
    try testing.expectEqualStrings("To Do", counts[3].status);
    var total: usize = 0;
    for (counts) |c| total += c.n;
    try testing.expectEqual(issues.len, total);

    const tip = try breakdownText(arena, "Jira · 6 open items assigned to me", counts);
    try testing.expectEqualStrings("Jira · 6 open items assigned to me — 3 In Progress · 1 (no status) · 1 In Review · 1 To Do", tip);
    // Nothing counted: the lead stands alone rather than trailing a dash.
    try testing.expectEqualStrings("Jira · 0 open items assigned to me", try breakdownText(arena, "Jira · 0 open items assigned to me", &.{}));
}

test "the QA figure prefers the jql_editable tab, then a name, and comes from no other tab" {
    // The kind wins wherever there is one, whatever the tab is called.
    const kinded = [_]config.Tab{
        .{ .name = "Assigned to me", .kind = .work_open },
        .{ .name = "Whatever I called it", .kind = .jql_editable, .jql = "project = {p}", .vars = &.{.{ .name = "p", .value = "ENG" }} },
        .{ .name = "QA Actionable Now", .jql = "status = \"Ready for QA\"" },
    };
    try testing.expectEqualStrings("Whatever I called it", qaTab(&kinded).?.name);
}

test "the QA figure comes from a tab found by name, loosely, and from no other tab" {
    try testing.expect(qaTab(&.{}) == null);
    try testing.expect(qaTab(&.{.{ .name = "Assigned to me" }}) == null);
    try testing.expect(qaTab(&.{.{ .name = "QA" }}) == null);
    const tabs = [_]config.Tab{
        .{ .name = "Assigned to me", .kind = .work_assigned },
        .{ .name = "QA Actionable Now", .jql = "status = \"Ready for QA\"" },
        .{ .name = "Recently done", .kind = .work_recently_done },
    };
    const found = qaTab(&tabs).?;
    try testing.expectEqualStrings("QA Actionable Now", found.name);
    // A config written before `jql_editable` existed still works: the
    // name is matched the way a user would write it.
    try testing.expect(qaTab(&.{.{ .name = "qa_actionable" }}) != null);
    try testing.expect(qaTab(&.{.{ .name = "qa-actionable-now" }}) != null);
    try testing.expect(qaTab(&.{.{ .name = "My QA Actionable queue" }}) != null);
}

test "both chips carry their count and their breakdown; the QA one is absent when no tab is configured" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];

    var ipc = try sdk.Ipc.init(testing.allocator, testing.io, dir);
    defer ipc.deinit();
    try publishSegments(&ipc, arena, .{
        .assigned_open = 7,
        .assigned_by_status = &.{ .{ .status = "In Progress", .n = 4 }, .{ .status = "To Do", .n = 3 } },
        .assigned_items = &.{ .{ .text = "ENG-1  Checkout rewrite", .sub = "In Progress", .key = "ENG-1" }, .{ .text = "ENG-5  Basket total wrong with a voucher", .sub = "To Do", .key = "ENG-5" } },
    }, null, .{});
    var got = try tmp.dir.readFileAlloc(testing.io, "command", arena, .unlimited);
    try testing.expect(std.mem.indexOf(u8, got, "\"id\":\"jira_work.assigned\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, segment_glyph ++ " 7") != null);
    try testing.expect(std.mem.indexOf(u8, got, "7 work items assigned to you — 4 In Progress · 3 To Do") != null);
    // No tab, no part: a zero here would read as "nothing to do" when
    // it means "not set up". And the retired second chip is never sent.
    try testing.expect(std.mem.indexOf(u8, got, qa_glyph) == null);
    try testing.expect(std.mem.indexOf(u8, got, retired_segment_id) == null);
    // The figure says how many; `items` says which, in the order the
    // search returned them, each carrying what a click on the row runs.
    try testing.expect(std.mem.indexOf(u8, got, "\"items\":[{\"text\":\"ENG-1  Checkout rewrite\",\"sub\":\"In Progress\",\"command\":\"jira_work.open\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "{\"text\":\"ENG-5  Basket total wrong with a voucher\",\"sub\":\"To Do\",\"command\":\"jira_work.open\"") != null);
    // And WHICH ticket each row is: the host appends these to the
    // command's argv, so the press lands the cursor on that one
    // rather than only opening the pane.
    try testing.expect(std.mem.indexOf(u8, got, "\"command\":\"jira_work.open\",\"args\":[\"--focus\",\"ENG-1\"]") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"command\":\"jira_work.open\",\"args\":[\"--focus\",\"ENG-5\"]") != null);

    try publishSegments(&ipc, arena, .{
        .assigned_open = 1,
        .qa_actionable = 3,
        .qa_by_status = &.{.{ .status = "Ready for QA", .n = 3 }},
        .qa_tab_name = "QA Actionable Now",
        .qa_items = &.{.{ .text = "ENG-9  Voucher stacking", .sub = "Ready for QA" }},
    }, .{ .status = .{ .tokens = 0.24, .capacity = 60, .rate = 0.33, .baseline_rate = 0.33, .throttles = 3, .cooldown_remaining_secs = 0, .last_429_age_secs = 4 * 3600 }, .draws = .{ .top = "bb.py", .top_n = 30, .total = 71 } }, .{});
    got = try tmp.dir.readFileAlloc(testing.io, "command", arena, .unlimited);
    try testing.expect(std.mem.indexOf(u8, got, retired_segment_id) == null);
    try testing.expect(std.mem.indexOf(u8, got, "\\n3 in your QA Actionable Now tab — 3 Ready for QA") != null);
    // One item reads as one item, not "1 items".
    try testing.expect(std.mem.indexOf(u8, got, "1 work item assigned to you") != null);
    // And the hover carries the shared bucket, which is the answer to
    // "why is this chip stale" — one hover away rather than nowhere.
    try testing.expect(std.mem.indexOf(u8, got, "budget: 0.2 of 60 tokens") != null);
    // After a blank line: the host's trailer, under its own line.
    try testing.expect(std.mem.indexOf(u8, got, "Ready for QA\\n\\nbudget: 0.2 of 60 tokens") != null);
    try testing.expect(std.mem.indexOf(u8, got, "3 throttles") != null);
    try testing.expect(std.mem.indexOf(u8, got, "last 429 4h ago") != null);
    // And WHO drained it — a chip that is stale because a script is
    // holding the budget says so rather than blaming itself.
    try testing.expect(std.mem.indexOf(u8, got, "spent by bb.py 30 of 71 draws in 10m") != null);
    // The QA tab's rows follow the assigned ones, saying where they are.
    try testing.expect(std.mem.indexOf(u8, got, "\"text\":\"ENG-9  Voucher stacking\",\"sub\":\"Ready for QA \u{b7} QA Actionable Now\"") != null);
}

test "--ascii: the chip publishes its twins, and no Nerd Font glyph goes out" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    var ipc = try sdk.Ipc.init(testing.allocator, testing.io, dir);
    defer ipc.deinit();
    try publishSegments(&ipc, arena, .{
        .assigned_open = 7,
        .qa_actionable = 3,
        .qa_tab_name = "QA Actionable Now",
    }, null, .{ .ascii = true });
    const got = try tmp.dir.readFileAlloc(testing.io, "command", arena, .unlimited);
    try testing.expect(std.mem.indexOf(u8, got, segment_ascii ++ " 7 \u{b7} " ++ qa_ascii ++ " 3") != null);
    // The point of the twin: a host that cannot paint the font is sent
    // no codepoint it would render as tofu.
    try testing.expect(std.mem.indexOf(u8, got, segment_glyph) == null);
    try testing.expect(std.mem.indexOf(u8, got, qa_glyph) == null);
}

test "every segment this pane publishes obeys the family's figure rule" {
    // The SDK's assertion, not this pane's own opinion of it: one
    // figure, no invented subset (a tracker has no subset of "assigned
    // to me" it can name), and the QA count named by its glyph.
    var buf: [64]u8 = undefined;
    for ([_]Values{ .{ .assigned_open = 43 }, .{ .assigned_open = 0 }, .{ .assigned_open = 10, .qa_actionable = 14 }, .{ .assigned_open = 10, .qa_actionable = 0 } }) |v| {
        try sdk.pane.expect.statuslineFigure(segmentText(&buf, v, .{}));
        try sdk.pane.expect.statuslineFigure(segmentText(&buf, v, .{ .ascii = true }));
    }
}

test "one chip, two numbers: the text and the hover at (0,0), (10,0) and (10,14)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [64]u8 = undefined;
    const by_status = [_]StatusCount{ .{ .status = "In Progress", .n = 6 }, .{ .status = "To Do", .n = 4 } };

    // Nothing assigned, a QA tab with nothing in it.
    const quiet: Values = .{ .assigned_open = 0, .qa_actionable = 0, .qa_tab_name = "QA Actionable Now" };
    try testing.expectEqualStrings(segment_glyph ++ " 0", segmentText(&buf, quiet, .{}));
    try testing.expectEqualStrings("0 work items assigned to you\n0 in your QA Actionable Now tab", try segmentTooltip(arena, quiet));

    // Ten assigned, the QA tab empty: the part stays off the chip, the
    // hover still says it.
    const ten: Values = .{ .assigned_open = 10, .assigned_by_status = &by_status, .qa_actionable = 0, .qa_tab_name = "QA Actionable Now" };
    try testing.expectEqualStrings(segment_glyph ++ " 10", segmentText(&buf, ten, .{}));
    try testing.expectEqualStrings("10 work items assigned to you — 6 In Progress · 4 To Do\n0 in your QA Actionable Now tab", try segmentTooltip(arena, ten));

    // Ten assigned and fourteen in the QA tab.
    const both: Values = .{ .assigned_open = 10, .assigned_by_status = &by_status, .qa_actionable = 14, .qa_by_status = &.{.{ .status = "Ready for QA", .n = 14 }}, .qa_tab_name = "QA Actionable Now" };
    try testing.expectEqualStrings(segment_glyph ++ " 10 \u{b7} " ++ qa_glyph ++ " 14", segmentText(&buf, both, .{}));
    try testing.expectEqualStrings("10 work items assigned to you — 6 In Progress · 4 To Do\n14 in your QA Actionable Now tab — 14 Ready for QA", try segmentTooltip(arena, both));

    // No QA tab set up: no part and no second line.
    const none: Values = .{ .assigned_open = 10, .assigned_by_status = &by_status };
    try testing.expectEqualStrings(segment_glyph ++ " 10", segmentText(&buf, none, .{}));
    try testing.expectEqualStrings("10 work items assigned to you — 6 In Progress · 4 To Do", try segmentTooltip(arena, none));
}

test "one binary, three manifests, one poll: only the chip that has a segment declares a values source" {
    // `--values` answers one question — how many items are assigned to
    // you — whatever `--only` says. Three sources would have the host's
    // poller ask Jira the same thing three times every five minutes and
    // republish the same chip with each answer, on an API this user is
    // rate-limited on.
    try testing.expectEqual(@as(usize, 1), spec_work.values_sources.len);
    try testing.expectEqual(@as(usize, 0), spec_fix_versions.values_sources.len);
    try testing.expectEqual(@as(usize, 0), spec_boards.values_sources.len);
    // The one that polls is the one with chips to feed, and vice versa.
    for (specs) |s| try testing.expectEqual(s.statusline.len > 0, s.values_sources.len > 0);
}

test "the chip keeps what it lists: every segment and every hover row survives a refresh, a delta and a `--values`, on a scribbling allocator" {
    // Every job arena and every result arena — the pane's gpa is where
    // both are made — on an allocator that poisons what it frees. A
    // string the chip kept the SLICE of rather than the arena reads as
    // 0xAA here, where a plain allocator hands it back correct and the
    // test passes for no reason.
    var scribble: sdk.testing.Scribble = .{ .child = testing.allocator };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    const sync_path = try std.fs.path.join(testing.allocator, &.{ dir, "sync.json" });
    defer testing.allocator.free(sync_path);

    const h = try app_mod.Harness.startOn(.{ .tabs = &app_mod.work_tabs }, .work, scribble.allocator());
    defer h.stop();
    const a = &h.app;
    var sync = try sdk.Store.openAt(testing.allocator, testing.io, sync_path);
    defer sync.deinit();
    a.setSyncStore(&sync);

    var ipc_tmp = testing.tmpDir(.{});
    defer ipc_tmp.cleanup();
    var ibuf: [std.fs.max_path_bytes]u8 = undefined;
    var pane_ipc = try sdk.Ipc.init(testing.allocator, testing.io, ibuf[0..try ipc_tmp.dir.realPath(testing.io, &ibuf)]);
    defer pane_ipc.deinit();

    // Publish the chip the way the loop does, and read back the line
    // the host would have got. Every byte of it comes off the listing.
    const Published = struct {
        fn line(app: *app_mod.App, ipc: *const sdk.Ipc, d: Io.Dir, out: Allocator) ![]const u8 {
            var scratch = std.heap.ArenaAllocator.init(testing.allocator);
            defer scratch.deinit();
            try publishSegment(ipc, scratch.allocator(), app.assignedIssues(), null, .{});
            const text_ = try d.readFileAlloc(testing.io, "command", out, .unlimited);
            try d.deleteFile(testing.io, "command");
            return text_;
        }
    };

    var keep = std.heap.ArenaAllocator.init(testing.allocator);
    defer keep.deinit();

    // 1. The first whole listing.
    try a.ensureLoaded();
    const after_load = try Published.line(a, &pane_ipc, ipc_tmp.dir, keep.allocator());
    try testing.expect(a.assignedIssues().len > 0);
    try testing.expect(std.mem.indexOf(u8, after_load, "\"items\":[{\"text\":\"") != null);
    for (a.assignedIssues()) |iss| {
        try testing.expect(iss.key.len > 0);
        try testing.expect(std.mem.indexOfScalar(u8, iss.key, 0xAA) == null);
        try testing.expect(std.mem.indexOf(u8, after_load, iss.key) != null);
    }

    // 2. A DELTA. The rows it did not return still live on the arena
    //    the previous generation came on, which is kept rather than
    //    freed — a merge that dropped it poisons everything it did not
    //    re-fetch, and the chip's rows are the first read of it.
    h.store.issues.items[0].moved = true;
    h.store.issues.items[0].status = "Done";
    _ = try a.onKey("r");
    try testing.expectEqual(@as(usize, 1), a.tab().deltas.items.len);
    const after_delta = try Published.line(a, &pane_ipc, ipc_tmp.dir, keep.allocator());
    for (a.assignedIssues()) |iss| {
        try testing.expect(std.mem.indexOfScalar(u8, iss.key, 0xAA) == null);
        try testing.expect(std.mem.indexOfScalar(u8, iss.summary, 0xAA) == null);
        try testing.expect(std.mem.indexOf(u8, after_delta, iss.key) != null);
    }

    // 3. The whole listing again. This one DEINITS the old `t.data`,
    //    so anything the chip still pointed into it is now 0xAA.
    _ = try a.onKey("shift+r");
    try testing.expectEqual(@as(usize, 0), a.tab().deltas.items.len);
    const after_full = try Published.line(a, &pane_ipc, ipc_tmp.dir, keep.allocator());
    for (a.assignedIssues()) |iss| {
        try testing.expect(std.mem.indexOfScalar(u8, iss.key, 0xAA) == null);
        try testing.expect(std.mem.indexOf(u8, after_full, iss.key) != null);
    }

    // 4. And the `--values` shape off the same listing — the poll's
    //    rows and the pane's are the same bytes, both still readable.
    var vals = std.heap.ArenaAllocator.init(testing.allocator);
    defer vals.deinit();
    const v = try assignedValues(vals.allocator(), a.assignedIssues());
    try testing.expectEqual(a.assignedIssues().len, v.assigned_open);
    for (v.assigned_items) |it| {
        try testing.expect(it.text.len > 0);
        try testing.expect(std.mem.indexOfScalar(u8, it.text, 0xAA) == null);
        try testing.expect(std.mem.indexOfScalar(u8, it.sub, 0xAA) == null);
    }
}

test "the detail modal's fields are readable after it is open: its arena is taken from where it lives" {
    // `openModal` used to take `allocator()` off a STACK local and then
    // copy the struct into `a.modal`. A `std.json.Value` is not plain
    // data — every object and array inside it keeps that handle — so
    // the modal's own data held a pointer to a dead frame.
    var scribble: sdk.testing.Scribble = .{ .child = testing.allocator };
    const h = try app_mod.Harness.startOn(.{ .tabs = &app_mod.work_tabs }, .work, scribble.allocator());
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    const key = a.tab().issues[0].key;
    try a.openModal(key);
    const m = a.modal orelse return error.NoModal;
    try testing.expectEqualStrings(key, m.key);
    try testing.expectEqualStrings("", m.error_text);
    const data = m.data orelse return error.NoData;
    const summary = json.getStr(data, "fields.summary") orelse return error.NoSummary;
    try testing.expect(summary.len > 0);
    try testing.expect(std.mem.indexOfScalar(u8, summary, 0xAA) == null);

    // The decisive one. A `std.json.Array` is `std.array_list.Managed`,
    // so it CARRIES the allocator it was parsed on — and an
    // `ArenaAllocator`'s `allocator()` binds to the address it was taken
    // from. Taken off a stack local and then copied into `a.modal`, that
    // address is a frame that has returned; taken off the field, it is
    // the arena the modal will free. Nothing else in the modal can tell
    // the two apart, which is why this looked fine for as long as it did.
    const arr = switch (json.get(data, "fields.labels") orelse return error.NoLabels) {
        .array => |x| x,
        else => return error.NotAnArray,
    };
    try testing.expectEqual(@intFromPtr(&a.modal.?.arena), @intFromPtr(arr.allocator.ptr));

    a.closeModal();
    try testing.expect(a.modal == null);
}

test "a $JIRA_BASE_URL=@file that never arrives is the setup screen, and no request is made" {
    // hunt/findings-2026-09-23/integ-bb-base-url-falls-back-to-production.md
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config.zon",
        .data = ".{ .jira_url = \"https://acme.atlassian.net\", .email = \"me@acme.com\", .tabs = .{ .{ .name = \"Assigned\", .kind = .work_assigned } } }",
    });
    const cfg_path = try std.fs.path.join(arena, &.{ root, "config.zon" });
    const data = try std.fs.path.join(arena, &.{ root, "data" });
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("MNML_DATA_ROOT", data);
    try env.put(auth.default_env, "fixture-token");
    try env.put(config.base_url_env, try std.fmt.allocPrint(arena, "@{s}/never.url", .{root}));

    switch (try setup(arena, testing.io, &env, cfg_path, data, null)) {
        .ready => return error.TestUnexpectedResult,
        .problem => |p| {
            try testing.expectEqualStrings("The base URL override points nowhere.", p.title);
            try testing.expect(std.mem.indexOf(u8, p.lines[0], "never.url") != null);
        },
    }
    // Nothing reached the request log: no client was ever built.
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(testing.io, try std.fs.path.join(arena, &.{ data, "requests", "jira.jsonl" }), .{}));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(testing.io, try std.fs.path.join(arena, &.{ data, "requests", "bitbucket.jsonl" }), .{}));
}

/// The pane on the offline fixture, for the SDK's design-language suite.
const Probe = struct {
    pub const Target = hit.Target;
    // The tree's body sits under the header, the strip, the toolbar and
    // the column header; `list` covers the rows below the header so the
    // bar column is read where the bar can be.
    h: *app_mod.Harness,
    f: sdk.Frame,
    ascii: bool,

    pub fn init(gpa: Allocator, size: sdk.testing.Size) !Probe {
        const h = try app_mod.Harness.start(.{ .tabs = &app_mod.work_tabs }, .work);
        errdefer h.stop();
        // Forty more open tickets than the fixture's twelve, so the tree
        // outruns its body at 80×24 and the scrollbar rule has a bar.
        try h.store.addExtraIssues(40);
        try h.app.ensureLoaded();
        h.app.resize(size.cols, size.rows);
        return .{ .h = h, .f = try sdk.Frame.init(gpa, size.cols, size.rows), .ascii = size.ascii };
    }

    pub fn deinit(p: *Probe) void {
        p.f.deinit();
        p.h.stop();
    }

    pub fn paint(p: *Probe, arena: Allocator) !sdk.testing.Painted(Target) {
        const ui: screen.Ui = .{ .ascii = p.ascii, .nerd = !p.ascii };
        try screen.paint(arena, &p.f, &p.h.app, ui);
        var segs: std.ArrayList([]const u8) = .empty;
        try segs.append(arena, segmentText(try arena.alloc(u8, 64), .{ .assigned_open = 43, .qa_actionable = 3 }, .{ .ascii = p.ascii }));
        return .{
            .frame = &p.f,
            .hits = &p.h.app.hits,
            .theme = ui.th,
            .title = .{ .text = "JIRA WORK" },
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

test "the assigned figure wears the Work chip's glyph — the manifest's, or the host's" {
    const chip = spec_work.chip.?.glyph;
    try testing.expectEqualStrings(chip, (Mark{}).chip());
    // The resting text the manifest declares wears it too.
    for (spec_work.statusline) |seg| if (std.mem.eql(u8, seg.id, "assigned")) {
        try testing.expect(std.mem.startsWith(u8, seg.text, chip));
    };
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put(sdk.pane.chrome.chip_glyph_env, "\u{f1c15}");
    try testing.expectEqualStrings("\u{f1c15}", Mark.fromEnv(&env).chip());
    // Published, the figure leads with the mark the host named.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    var ipc = try sdk.Ipc.init(testing.allocator, testing.io, dir);
    defer ipc.deinit();
    try publishSegments(&ipc, arena_state.allocator(), .{ .assigned_open = 7 }, null, Mark.fromEnv(&env));
    const got = try tmp.dir.readFileAlloc(testing.io, "command", arena_state.allocator(), .unlimited);
    try testing.expect(std.mem.indexOf(u8, got, "\u{f1c15} 7") != null);
}

test "one mark: the Work chip's glyph, the assigned figure's resting text and its published figure are one glyph, spelled once" {
    const chip = spec_work.chip.?.glyph;
    // Spelled once: the manifest's segment writes the token, not the glyph.
    const raw: sdk.Manifest = @import("manifest.zon");
    for (raw.statusline) |seg| try testing.expect(std.mem.indexOf(u8, seg.text, chip) == null);
    var resting: ?[]const u8 = null;
    for (spec_work.statusline) |seg| if (std.mem.eql(u8, seg.id, "assigned")) {
        resting = seg.text;
    };
    const first_len = try std.unicode.utf8ByteSequenceLength(resting.?[0]);
    try testing.expectEqualStrings(chip, resting.?[0..first_len]);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    var ipc = try sdk.Ipc.init(testing.allocator, testing.io, dir);
    defer ipc.deinit();
    try publishSegments(&ipc, arena_state.allocator(), .{ .assigned_open = 4 }, null, .{});
    const got = try tmp.dir.readFileAlloc(testing.io, "command", arena_state.allocator(), .unlimited);
    const text_at = std.mem.indexOf(u8, got, "\"text\":\"").? + "\"text\":\"".len;
    try testing.expectEqualStrings(chip, got[text_at..][0..first_len]);
}
