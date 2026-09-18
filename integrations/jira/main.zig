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
pub const screen = @import("src/screen.zig");
pub const bitbucket = @import("src/bitbucket.zig");
pub const json = @import("src/json.zig");
pub const text = @import("src/text.zig");
pub const os = @import("src/os.zig");
pub const ratelimit = @import("src/ratelimit.zig");

pub const spec_work: sdk.Manifest = @import("manifest.zon");
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
pub const version = "0.2.0";

/// The two statusline segments the Work chip publishes — the
/// manifest's slots, replaced live with their counts. They are two
/// numbers about two different things, so they are two chips: one says
/// how much is on your plate, the other how much is waiting on you to
/// look at it.
pub const segment_id = "jira_work.assigned";
pub const segment_glyph = "\u{f0303}";
pub const segment_color = "#1B5DCF";
pub const segment_click = "jira_work.open";
pub const segment_priority: u8 = 60;

/// The second figure: the tab the user configures as "QA Actionable
/// Now". There is no tab *kind* for it yet (that is its own track), so
/// it is found by name; without such a tab the chip is not published
/// at all rather than showing a zero that means "not configured".
pub const qa_segment_id = "jira_work.qa_actionable";
pub const qa_segment_glyph = "\u{ed7a}"; // nf-fa-clipboard_check
pub const qa_segment_color = "#C678DD";
pub const qa_segment_priority: u8 = 59;

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
    config_path: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    /// `--dump --steps FILE [--size WxH]`: the headless driver behind
    /// tools/jira-diff.sh — the pane painted to stdout, no mnml.
    dump: bool = false,
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
        } else if (std.mem.eql(u8, s, "--config") and i + 1 < argv.len) {
            i += 1;
            a.config_path = argv[i];
        } else if (std.mem.eql(u8, s, "--workspace") and i + 1 < argv.len) {
            i += 1;
            a.workspace = argv[i];
        } else if (std.mem.eql(u8, s, "--dump")) {
            a.dump = true;
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
    \\  --config PATH             the config file (else $MNML_JIRA_CONFIG, the
    \\                            workspace's, the data root's)
    \\  --dump --steps FILE [--size WxH] [--only F]
    \\                            play a step script at the pane with no mnml and
    \\                            print every `snap` as text (tools/jira-diff.sh)
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
        for (specs) |s| {
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
        const loaded = try config.load(arena, io, cfg_path);
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
    ready: struct { cfg: config.Config, token: auth.Token },
    /// A setup screen: its title and its lines.
    problem: struct { title: []const u8, lines: []const []const u8 },
};

/// Load the config and the token; either everything a pane needs or the
/// screen that says what is missing. Everything returned is on `arena`.
fn setup(arena: Allocator, io: Io, env: *const std.process.Environ.Map, cfg_path: []const u8, data_root: ?[]const u8, family: ?config.Family) Allocator.Error!Setup {
    const loaded = try config.load(arena, io, cfg_path);
    if (loaded.missing) return .{ .problem = .{ .title = "No Jira config yet.", .lines = try missingConfig(arena, cfg_path) } };
    if (loaded.parse_error) |why| return .{ .problem = .{ .title = "The config did not parse.", .lines = try parseError(arena, cfg_path, why) } };
    var why: []const u8 = "";
    config.validate(loaded.config, &why) catch return .{ .problem = .{ .title = "The config is not usable yet.", .lines = try configProblem(arena, cfg_path, why) } };
    if (family) |f| {
        const tabs = try config.tabsOfFamily(arena, loaded.config.tabs, f);
        if (tabs.len == 0) return .{ .problem = .{ .title = "No tabs for this scope.", .lines = try noTabs(arena, cfg_path, f) } };
    }
    const token = try auth.resolve(arena, io, env, .{ .config_path = loaded.config.token_file, .env_name = loaded.config.token_env, .data_root = data_root });
    switch (token) {
        .ok => |t| return .{ .ready = .{ .cfg = loaded.config, .token = t } },
        .missing => |m| return .{ .problem = .{ .title = "No Jira API token.", .lines = try auth.explain(arena, m) } },
    }
}

const setup_hint = "r try again · q quit";

fn pane(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, arena: Allocator, mount: *sdk.Mount, args: Args, data_root: ?[]const u8) !u8 {
    defer mount.destroy();
    var frame = try sdk.Frame.init(gpa, mount.geometry.cols, mount.geometry.rows);
    defer frame.deinit();
    const family = args.only;
    const ui: screen.Ui = .{
        .ascii = mount.hello.capabilities.ascii,
        .nerd = mount.hello.capabilities.nerd_font,
        .th = sdk.pane.Theme.fromHelloBranded(mount.hello.palette, chipColorOf(family)),
    };
    try mount.setTitle(if (family) |f| f.label() else "Jira");

    var box = try inbox.Inbox.init(gpa, 64);
    defer box.deinit(io);
    var group: Io.Group = .init;
    try group.concurrent(io, inbox.Inbox.reader, .{ io, &box, mount });
    defer group.cancel(io);

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
    var client = jira.Client.init(gpa, io, rd.cfg.jira_url, authorization, rd.cfg.api);
    client.limiter = &limiter;
    const forge_token = if (rd.cfg.bitbucket_token_env.len > 0) env.get(rd.cfg.bitbucket_token_env) else env.get("BITBUCKET_ACCESS_TOKEN");
    const forge: bitbucket.Client = .{ .gpa = gpa, .io = io, .base_url = rd.cfg.bitbucket_api_url, .token = forge_token orelse "" };
    var app = try app_mod.App.init(gpa, io, rd.cfg, family, &client, forge);
    // The host sets this for every integration it spawns; a dispatched
    // `term` line goes to that channel and nowhere else.
    app.setIpcDir(env.get("MNML_IPC_DIR") orelse "");
    defer app.deinit();
    app.resize(frame.cols, frame.rows);
    var ipc = try sdk.Ipc.fromEnv(gpa, io, env);
    defer if (ipc) |*i| i.deinit();

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
    // The first fetch, after the first paint.
    try app.ensureLoaded();
    app.last_refresh_ms = app.nowMs();
    try repaint(&paint_arena, &frame, &app, ui);
    mount.send(&frame) catch return 0;
    publishSide(&app, mount, if (ipc) |*i| i else null);

    while (true) {
        var ended = false;
        while (box.take(io)) |item| {
            defer item.destroy(gpa);
            const msg = item.msg orelse {
                ended = true;
                break;
            };
            switch (msg) {
                .hello, .focus => {},
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
                    .hover => {},
                },
            }
            if (ended) break;
        }
        if (ended or box.ended) break;
        if (app.quit) {
            mount.bye();
            break;
        }
        try app.tick(app.nowMs());
        try repaint(&paint_arena, &frame, &app, ui);
        mount.send(&frame) catch break;
        publishSide(&app, mount, if (ipc) |*i| i else null);
        _ = box.wait(io, 500);
    }
    return 0;
}

fn repaint(paint_arena: *std.heap.ArenaAllocator, frame: *sdk.Frame, app: *app_mod.App, ui: screen.Ui) Allocator.Error!void {
    _ = paint_arena.reset(.retain_capacity);
    try screen.paint(paint_arena.allocator(), frame, app, ui);
}

/// The toast and the statusline segment, when the app has news.
fn publishSide(app: *app_mod.App, mount: *sdk.Mount, ipc: ?*const sdk.Ipc) void {
    if (app.toast_pending) {
        app.toast_pending = false;
        mount.toast(.info, app.toast.items) catch {};
    }
    if (app.segment_dirty) {
        app.segment_dirty = false;
        if (ipc) |i| if (app.assigned_open) |n| publishSegment(i, n) catch {};
    }
}

/// One status and how many of the counted issues are in it.
pub const StatusCount = struct { status: []const u8, n: usize };

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
};

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

/// The tab the user has set up as QA Actionable Now, by name. A tab
/// *kind* for it is the next track; until then the name is the
/// contract, matched loosely so "QA Actionable Now", "qa_actionable"
/// and "QA actionable" all count.
pub fn qaTab(tabs: []const config.Tab) ?config.Tab {
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

/// The Work chips' statusline segments: the glyph and the count, the
/// breakdown on hover, a click opens the pane — the manifest's slots,
/// live.
pub fn publishSegments(ipc: *const sdk.Ipc, arena: Allocator, v: Values) !void {
    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "{s} {d}", .{ segment_glyph, v.assigned_open }) catch segment_glyph;
    const lead = try std.fmt.allocPrint(arena, "Jira · {d} open item{s} assigned to me", .{ v.assigned_open, if (v.assigned_open == 1) "" else "s" });
    try ipc.statuslineSetSegment(.{
        .id = segment_id,
        .text = label,
        .color = segment_color,
        .click_command = segment_click,
        .priority = segment_priority,
        .tooltip = try breakdownText(arena, lead, v.assigned_by_status),
    });
    if (v.qa_actionable) |n| {
        var qbuf: [32]u8 = undefined;
        const qlabel = std.fmt.bufPrint(&qbuf, "{s} {d}", .{ qa_segment_glyph, n }) catch qa_segment_glyph;
        const qlead = try std.fmt.allocPrint(arena, "{s} · {d} actionable now", .{ if (v.qa_tab_name.len > 0) v.qa_tab_name else "QA Actionable Now", n });
        try ipc.statuslineSetSegment(.{
            .id = qa_segment_id,
            .text = qlabel,
            .color = qa_segment_color,
            .click_command = segment_click,
            .priority = qa_segment_priority,
            .tooltip = try breakdownText(arena, qlead, v.qa_by_status),
        });
    }
}

/// The one-figure form the pane's own refresh publishes as it goes.
pub fn publishSegment(ipc: *const sdk.Ipc, assigned_open: usize) sdk.ipc.Error!void {
    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "{s} {d}", .{ segment_glyph, assigned_open }) catch segment_glyph;
    try ipc.statuslineSetSegment(.{
        .id = segment_id,
        .text = label,
        .color = segment_color,
        .click_command = segment_click,
        .priority = segment_priority,
    });
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
        .work => "Work tabs: work_assigned · work_recently_done · work_recent · work_unified · filter.",
        .fix_versions => "Fix Versions tabs: fix_version_tree (with .project and .mode).",
        .boards => "Boards tabs: board_active_sprint · board_backlog (with .project, .board_id).",
    });
    return out.toOwnedSlice(arena);
}

// ─── --check / --diag / --values / --prefetch ────────────────────────────

fn kindName(k: ?config.TabKind) []const u8 {
    return if (k) |kk| switch (kk) {
        .work_assigned => "WorkAssigned",
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
    return ratelimit.Limiter.init(gpa, io, p, ratelimit.configFrom(rate));
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
        var client = jira.Client.init(gpa, io, c.jira_url, authorization, c.api);
        client.limiter = &limiter;
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
/// Now. There is no tab kind for it yet, so it is found by name; with
/// no such tab the key is `null` and the chip is not published, which
/// is not the same as a zero.
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
    var client = jira.Client.init(gpa, io, c.jira_url, try auth.basicHeader(arena, c.email, t.value), c.api);
    client.limiter = &limiter;

    var v: Values = .{};
    const base = config.TabKind.work_assigned.defaultJql().?;
    const jql = try jira.withProjects(arena, base, c.projects);
    switch (jira.search(&client, arena, jql, &.{}) catch jira.Answer([]const std.json.Value){ .failed = .{ .status = 0, .message = "the site did not answer" } }) {
        .ok => |items| {
            v.assigned_open = items.len;
            v.assigned_by_status = try countByStatus(arena, try jira.parseIssues(arena, items, c.team_field_id));
        },
        .failed => |f| {
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
            switch (jira.search(&client, arena, scoped, &.{}) catch jira.Answer([]const std.json.Value){ .failed = .{ .status = 0, .message = "the site did not answer" } }) {
                .ok => |items| {
                    v.qa_actionable = items.len;
                    v.qa_by_status = try countByStatus(arena, try jira.parseIssues(arena, items, c.team_field_id));
                },
                .failed => |f| try err.print("mnml-jira --values: {s}: {s}\n", .{ tab.name, f.message }),
            }
        } else try err.print("mnml-jira --values: the tab `{s}` has no jql to run\n", .{tab.name});
    }

    try out.print("{{\"assigned_open\":{d}", .{v.assigned_open});
    if (v.qa_actionable) |n| try out.print(",\"qa_actionable\":{d}", .{n}) else try out.writeAll(",\"qa_actionable\":null");
    try out.writeAll("}\n");

    if (try ipcFor(gpa, io, env, args.workspace)) |*ipc_ptr| {
        var ipc = ipc_ptr.*;
        defer ipc.deinit();
        publishSegments(&ipc, arena, v) catch |e| try err.print("mnml-jira --values: could not publish the segments: {s}\n", .{@errorName(e)});
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
    var client = jira.Client.init(gpa, io, c.jira_url, try auth.basicHeader(arena, c.email, t.value), c.api);
    client.limiter = &limiter;
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
            switch (jira.boardIssues(&client, arena, tab.board_id, null, extra) catch jira.Answer([]const std.json.Value){ .failed = .{ .status = 0, .message = "the site did not answer" } }) {
                .ok => |items| for (items) |v| try w.write(v),
                .failed => |f| try err.print("mnml-jira --prefetch: {s}: {s}\n", .{ tab.name, f.message }),
            }
        } else if (jql.len > 0) {
            const q = if (tab.team.len > 0) try jira.withTeam(arena, jql, tab.team, c.team_field_name, c.team_field_id) else jql;
            switch (jira.search(&client, arena, q, extra) catch jira.Answer([]const std.json.Value){ .failed = .{ .status = 0, .message = "the site did not answer" } }) {
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
    var client = jira.Client.init(gpa, io, c.jira_url, try auth.basicHeader(arena, c.email, t.value), c.api);
    client.limiter = &limiter;
    const forge_token = if (c.bitbucket_token_env.len > 0) env.get(c.bitbucket_token_env) else env.get("BITBUCKET_ACCESS_TOKEN");
    var app = try app_mod.App.init(gpa, io, c, args.only, &client, .{ .gpa = gpa, .io = io, .base_url = c.bitbucket_api_url, .token = forge_token orelse "" });
    app.setIpcDir(env.get("MNML_IPC_DIR") orelse "");
    defer app.deinit();
    app.resize(cols, rows);
    var frame = try sdk.Frame.init(gpa, cols, rows);
    defer frame.deinit();
    var paint_arena = std.heap.ArenaAllocator.init(gpa);
    defer paint_arena.deinit();
    try app.ensureLoaded();
    try repaint(&paint_arena, &frame, &app, .{});
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
            try repaint(&paint_arena, &frame, &app, .{});
            try out.print("=== {s}\n", .{rest});
            try out.writeAll(try screen.screenText(arena, &frame));
        } else if (std.mem.eql(u8, verb, "expect")) {
            try repaint(&paint_arena, &frame, &app, .{});
            if ((try findOnScreen(arena, &frame, rest)) == null) {
                try err.print("mnml-jira --dump: expect '{s}': not on screen\n", .{rest});
                return 1;
            }
        } else if (std.mem.eql(u8, verb, "quit")) {
            break;
        }
        // wait / settle / waitfor / waitsoft / find: nothing to wait for.
        try repaint(&paint_arena, &frame, &app, .{});
        if (app.quit) break;
    }
    return 0;
}

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
    // Two chips, because they are two numbers about two different
    // things: what is on my plate, and what is waiting for me to look
    // at it. Each carries its own resting hover text.
    try testing.expectEqual(@as(usize, 2), spec_work.statusline.len);
    try testing.expectEqualStrings("jira_work.open", spec_work.statusline[0].click_command.?);
    try testing.expectEqualStrings("#1B5DCF", spec_work.statusline[0].color.?);
    try testing.expectEqualStrings("assigned", spec_work.statusline[0].id);
    try testing.expectEqualStrings("qa_actionable", spec_work.statusline[1].id);
    for (spec_work.statusline) |seg| try testing.expect(seg.tooltip != null);
    // The ids the binary publishes on are the manifest's own slots,
    // prefixed with the manifest id — a mismatch is a chip that never
    // moves, which is only visible by running it.
    try testing.expectEqualStrings(segment_id, "jira_work." ++ "assigned");
    try testing.expectEqualStrings(qa_segment_id, "jira_work." ++ "qa_actionable");
    try testing.expectEqual(@as(usize, 0), spec_boards.statusline.len);
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

test "the statusline segment is the manifest's slot, live: the exact IPC line" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    var ipc = try sdk.Ipc.init(testing.allocator, testing.io, dir);
    defer ipc.deinit();
    try publishSegment(&ipc, 3);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const line = try tmp.dir.readFileAlloc(testing.io, "command", arena.allocator(), .unlimited);
    try testing.expectEqualStrings(
        "{\"cmd\":\"statusline-set-segment\",\"id\":\"jira_work.assigned\",\"side\":\"right\",\"text\":\"\u{f0303} 3\",\"color\":\"#1B5DCF\",\"click_command\":\"jira_work.open\",\"priority\":60,\"min_width\":4,\"max_width\":30}\n",
        line,
    );
    // The manifest's static slot and the live one name the same thing.
    try testing.expectEqualStrings(spec_work.statusline[0].color.?, segment_color);
    try testing.expectEqualStrings(spec_work.statusline[0].click_command.?, segment_click);
    try testing.expect(std.mem.endsWith(u8, segment_id, spec_work.statusline[0].id));
}

test "--check prints the config and where the token is, never the token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const loaded = try config.parse(ar,
        \\.{ .jira_url = "https://acme.atlassian.net", .email = "me@acme.com", .tabs = .{ .{ .name = "Assigned", .kind = .work_assigned }, .{ .name = "Current Release", .kind = .fix_version_tree, .project = "TE", .mode = .current_release } } }
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
    try testing.expect(std.mem.indexOf(u8, out, "    2: Current Release → CurrentRelease project=TE") != null);
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
    // The name is the contract until a tab kind exists for it, so it is
    // matched the way a user would write it.
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
    });
    var got = try tmp.dir.readFileAlloc(testing.io, "command", arena, .unlimited);
    try testing.expect(std.mem.indexOf(u8, got, "\"id\":\"jira_work.assigned\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\u{f0303} 7") != null);
    try testing.expect(std.mem.indexOf(u8, got, "7 open items assigned to me — 4 In Progress · 3 To Do") != null);
    // No tab, no chip: a zero here would read as "nothing to do" when
    // it means "not set up".
    try testing.expect(std.mem.indexOf(u8, got, "jira_work.qa_actionable") == null);

    try publishSegments(&ipc, arena, .{
        .assigned_open = 1,
        .qa_actionable = 3,
        .qa_by_status = &.{.{ .status = "Ready for QA", .n = 3 }},
        .qa_tab_name = "QA Actionable Now",
    });
    got = try tmp.dir.readFileAlloc(testing.io, "command", arena, .unlimited);
    try testing.expect(std.mem.indexOf(u8, got, "\"id\":\"jira_work.qa_actionable\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "QA Actionable Now · 3 actionable now — 3 Ready for QA") != null);
    // One item reads as one item, not "1 items".
    try testing.expect(std.mem.indexOf(u8, got, "1 open item assigned to me") != null);
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
