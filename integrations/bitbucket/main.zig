//! mnml-bitbucket — the Bitbucket Cloud pull-request pane, written on
//! `mnml-sdk`. Tabs of pull requests (a repo's, the ones you opened,
//! the ones waiting on your review), a detail with the reviewers, the
//! build statuses, the diffstat, the diff and the comment threads, and
//! the actions: open, copy, approve, request changes, comment, merge,
//! and check the branch out in mnml's workspace.
//!
//!   mnml-bitbucket --install      write the manifest (then `integrations.refresh`)
//!   mnml-bitbucket --uninstall    delete it
//!   mnml-bitbucket --version
//!   mnml-bitbucket --scaffold     write config.zon and say where
//!   mnml-bitbucket --check        resolved config + auth + a live whoami
//!   mnml-bitbucket --diag         the whole tree, for a bug report
//!   mnml-bitbucket --refresh      headless: republish the review-queue
//!                                 count as a statusline segment + badge
//!   mnml-bitbucket --tab mine     open focused on that tab
//!   mnml-bitbucket                connect to `$MNML_MOUNT_SOCKET` and paint
//!
//! The manifest is `manifest.zon` beside this file, `@import`ed so the
//! binary and the Dev tab read one definition.
//!
//! **No token is ever printed.** `--check` and `--diag` name where each
//! one came from and how long it is; `auth.zig` has the test that holds
//! that line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sdk = @import("mnml_sdk");

const cfg = @import("src/config.zig");
const auth = @import("src/auth.zig");
const api = @import("src/api.zig");
const app_mod = @import("src/app.zig");
const screen = @import("src/screen.zig");
const view = @import("src/view.zig");
const links = @import("src/links.zig");
const os = @import("src/os.zig");
const j = @import("src/json.zig");

pub const spec: sdk.Manifest = @import("manifest.zon");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const args = try init.minimal.args.toSlice(arena_state.allocator());

    var out_buf: [4096]u8 = undefined;
    var out_w: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const stdout = &out_w.interface;
    var err_buf: [1024]u8 = undefined;
    var err_w: std.Io.File.Writer = .init(.stderr(), io, &err_buf);
    const stderr = &err_w.interface;

    var want_tab: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--install")) {
            const path = sdk.manifest.write(gpa, io, env, spec) catch |err| {
                try stderr.print("mnml-bitbucket: could not write the manifest: {s}\n", .{@errorName(err)});
                try stderr.flush();
                return 1;
            };
            defer gpa.free(path);
            try stdout.print("mnml-bitbucket: wrote {s}\n", .{path});
            // The config is private to this machine and lives beside
            // the manifest, not inside it; scaffold it now so the first
            // run has something to edit rather than an error.
            if (cfg.configPath(gpa, env) catch null) |p| {
                defer gpa.free(p);
                if (Io.Dir.cwd().access(io, p, .{})) |_| {
                    try stdout.print("mnml-bitbucket: config already at {s}\n", .{p});
                } else |_| {
                    cfg.scaffold(io, p) catch {};
                    try stdout.print("mnml-bitbucket: wrote the config scaffold to {s} — set `email`, `workspace` and `repos`\n", .{p});
                }
            }
            try stdout.flush();
            return 0;
        }
        if (std.mem.eql(u8, a, "--uninstall")) {
            const went = sdk.manifest.remove(gpa, io, env, spec.id) catch |err| {
                try stderr.print("mnml-bitbucket: could not remove the manifest: {s}\n", .{@errorName(err)});
                try stderr.flush();
                return 1;
            };
            try stdout.print("mnml-bitbucket: {s} (the config stays; delete it by hand)\n", .{if (went) "removed the manifest" else "nothing to remove"});
            try stdout.flush();
            return 0;
        }
        if (std.mem.eql(u8, a, "--version")) {
            try stdout.print("mnml-bitbucket {s} (bridge protocol {d})\n", .{ spec.version, sdk.protocol });
            try stdout.flush();
            return 0;
        }
        if (std.mem.eql(u8, a, "--scaffold")) {
            const p = cfg.configPath(gpa, env) catch {
                try stderr.writeAll("mnml-bitbucket: no HOME, XDG_CONFIG_HOME or MNML_DATA_ROOT to write into\n");
                try stderr.flush();
                return 1;
            };
            defer gpa.free(p);
            cfg.scaffold(io, p) catch {
                try stderr.print("mnml-bitbucket: could not write {s}\n", .{p});
                try stderr.flush();
                return 1;
            };
            try stdout.print("{s}\n", .{p});
            try stdout.flush();
            return 0;
        }
        if (std.mem.eql(u8, a, "--check")) return diagnose(gpa, io, env, stdout, false);
        if (std.mem.eql(u8, a, "--diag")) return diagnose(gpa, io, env, stdout, true);
        if (std.mem.eql(u8, a, "--refresh")) {
            // `--workspace {{workspace}}` is how the manifest's ex line
            // hands over mnml's workspace: a `term` child does not get
            // `MNML_IPC_DIR`, so without it the refresh can count but
            // has nowhere to publish the count.
            var workspace: []const u8 = "";
            var k: usize = i + 1;
            while (k + 1 < args.len) : (k += 1) {
                if (std.mem.eql(u8, args[k], "--workspace")) workspace = args[k + 1];
            }
            return refreshCounts(gpa, io, env, stdout, workspace);
        }
        if (std.mem.eql(u8, a, "--workspace") and i + 1 < args.len) {
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--tab") and i + 1 < args.len) {
            i += 1;
            want_tab = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try stdout.writeAll(usage);
            try stdout.flush();
            return 0;
        }
    }

    const mount = sdk.Mount.connectEnv(gpa, io, env) catch |err| switch (err) {
        error.NoSocket => {
            try stderr.writeAll("mnml-bitbucket is an mnml integration: open it from mnml (bitbucket.open), or run `mnml-bitbucket --install` / `--check`.\n");
            try stderr.flush();
            return 2;
        },
        else => return err,
    };
    defer mount.destroy();
    return pane(gpa, io, env, mount, want_tab);
}

const usage =
    \\mnml-bitbucket — Bitbucket Cloud pull requests as an mnml pane.
    \\
    \\  --install / --uninstall   register with mnml (and scaffold the config)
    \\  --version
    \\  --scaffold                write config.zon and print its path
    \\  --check                   resolved config + auth + a live whoami
    \\  --diag                    the whole tree, for a bug report
    \\  --refresh [--workspace W] republish the review-queue count, headless
    \\  --tab mine|reviewing|NAME open focused on that tab
    \\
;

// ─── the pane ────────────────────────────────────────────────────────────

fn pane(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, mount: *sdk.Mount, want_tab: []const u8) !u8 {
    var frame = try sdk.Frame.init(gpa, mount.geometry.cols, mount.geometry.rows);
    defer frame.deinit();
    try mount.setTitle("bitbucket");

    var ipc_opt = try sdk.Ipc.fromEnv(gpa, io, env);
    defer if (ipc_opt) |*x| x.deinit();
    if (ipc_opt) |*ipc| {
        // The four commands, registered on the live channel as well as
        // declared in the manifest: a pane opened from the Dev tab
        // before an install still puts them on the palette.
        for (spec.commands) |c| ipc.registerCommand(c.id, c.title, c.group, c.keys) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Config and auth first; a pane with neither paints the setup
    // screen and says what to do about it.
    var why: []const u8 = "";
    var loaded = cfg.load(gpa, io, env, &why) catch {
        return setupLoop(gpa, mount, &frame, &arena, why);
    };
    defer loaded.deinit();

    const config_dir = std.fs.path.dirname(loaded.path) orelse ".";
    var tokens = try auth.resolve(gpa, io, env, config_dir);
    defer tokens.deinit();
    if (!tokens.hasRead()) return setupLoop(gpa, mount, &frame, &arena, no_token_text);

    const base_url = try resolveBaseUrl(gpa, io, env, loaded.config);
    defer gpa.free(base_url);
    var client = try api.Client.init(gpa, io, base_url, loaded.config.email, tokens.read, tokens.write, loaded.config.rate);
    defer client.deinit();
    client.write_refusal = tokens.writeRefusal();

    var app = try app_mod.App.init(gpa, io, loaded.config, &client);
    defer app.deinit();
    app.cols = frame.cols;
    app.rows = frame.rows;
    app.workspace_dir = env.get("MNML_WORKSPACE") orelse ".";
    app.jira_installed = links.installed(gpa, io, env, "jira");
    app.github_installed = links.installed(gpa, io, env, "github");
    app.show_diff = !std.mem.eql(u8, env.get("MNML_SETTING_DIFF") orelse "on", "off");
    app.show_detail = std.mem.eql(u8, env.get("MNML_SETTING_DETAIL") orelse "closed", "open");

    try app.switchTab(pickTab(loaded.config, want_tab));
    try drain(gpa, io, env, mount, &ipc_opt, &app);
    publishCounts(&ipc_opt, &app);

    _ = arena.reset(.retain_capacity);
    try screen.paint(arena.allocator(), &frame, &app);
    try mount.send(&frame);

    var msg_arena = std.heap.ArenaAllocator.init(gpa);
    defer msg_arena.deinit();
    while (true) {
        _ = msg_arena.reset(.retain_capacity);
        const msg = (try mount.next(msg_arena.allocator())) orelse break;
        var running = true;
        switch (msg) {
            .hello, .focus => {},
            .goodbye => break,
            .resize => |r| {
                try frame.resize(r.geometry.cols, r.geometry.rows);
                app.cols = r.geometry.cols;
                app.rows = r.geometry.rows;
            },
            .input => |in| switch (in.event) {
                .key => |k| running = try app.key(k.spec),
                .paste => |p| try app.paste(p.text),
                .click => |c| running = try click(gpa, &app, c.col, c.row, c.button == .right),
                .scroll => |s| running = try app.key(if (s.dy > 0) "k" else "j"),
                .hover => {},
            },
        }
        try drain(gpa, io, env, mount, &ipc_opt, &app);
        if (!running) break;
        publishCounts(&ipc_opt, &app);
        _ = arena.reset(.retain_capacity);
        try screen.paint(arena.allocator(), &frame, &app);
        try mount.send(&frame);
    }
    if (ipc_opt) |*ipc| ipc.statuslineClearSegment("bitbucket.review") catch {};
    mount.bye();
    return 0;
}

/// Row 0 is the tab strip; row 2 is the column header; the rows below
/// are the list. A right-click on a row opens its detail.
fn click(gpa: Allocator, app: *app_mod.App, col: u16, row: u16, right: bool) Allocator.Error!bool {
    if (row == 0) {
        if (tabAtColumn(gpa, app, col)) |idx| try app.switchTab(idx);
        return true;
    }
    if (row < 3) return true;
    const tab = app.activeTab();
    const wanted = tab.scroll + (row - 3);
    if (wanted >= tab.visible.len) return true;
    _ = app.select(wanted);
    if (right) return app.key("d");
    return true;
}

/// Run what the last event queued: toasts and commands over the mount,
/// progress over the file channel, a browser and a clipboard through
/// the machine.
fn drain(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, mount: *sdk.Mount, ipc_opt: *?sdk.Ipc, app: *app_mod.App) !void {
    const taken = app.takeEffects();
    defer app.resetEffects(taken);
    for (taken) |e| switch (e) {
        .toast => |x| mount.toast(switch (x.level) {
            .info => .info,
            .warn => .warn,
            .err => .@"error",
        }, x.text) catch {},
        .command => |id| mount.command(id) catch {},
        .open_url => |url| {
            if (os.openUrl(gpa, io, url)) |whynot| mount.toast(.warn, whynot) catch {};
        },
        .copy => |text| {
            if (os.copy(gpa, io, env, text)) |whynot| mount.toast(.warn, whynot) catch {};
        },
        .progress_start => |x| if (ipc_opt.*) |*ipc| ipc.progressStart(x.id, x.label) catch {},
        .progress_update => |x| if (ipc_opt.*) |*ipc| ipc.progressUpdate(x.id, x.label, x.percent) catch {},
        .progress_end => |x| if (ipc_opt.*) |*ipc| ipc.progressEnd(x.id, if (x.ok) .success else .failed) catch {},
        .quit => {},
    };
}

/// The statusline segment and the activity badge, from whichever tab
/// is the review queue.
fn publishCounts(ipc_opt: *?sdk.Ipc, app: *app_mod.App) void {
    const ipc = if (ipc_opt.*) |*x| x else return;
    var count: ?usize = null;
    for (app.tabs) |*ts| {
        if (ts.tab.mode == .reviewing and ts.fetched) count = ts.rows.len;
    }
    const n = count orelse return;
    var buf: [32]u8 = undefined;
    ipc.statuslineSetSegment(.{
        .id = "bitbucket.review",
        .text = std.fmt.bufPrint(&buf, "BB·{d}", .{n}) catch "BB",
        .color = if (n > 0) "blue" else "comment",
        .click_command = "bitbucket.review_queue",
        .priority = 60,
    }) catch {};
    ipc.setActivityBadge("integrations", @intCast(n)) catch {};
}

/// Which tab `--tab` asked for: a mode name, a tab name, or the first.
fn pickTab(config: cfg.Config, want: []const u8) usize {
    if (want.len == 0) return 0;
    for (config.tabs, 0..) |tab, idx| {
        if (std.ascii.eqlIgnoreCase(@tagName(tab.mode), want)) return idx;
    }
    for (config.tabs, 0..) |tab, idx| {
        if (std.ascii.eqlIgnoreCase(tab.name, want)) return idx;
    }
    return 0;
}

/// The tab whose label covers column `col` of the strip. The arithmetic
/// mirrors `view.tabStrip`, which is the one place the label is built.
fn tabAtColumn(gpa: Allocator, app: *app_mod.App, col: u16) ?usize {
    _ = gpa;
    var x: u16 = 0;
    for (app.tabs, 0..) |*ts, idx| {
        var w: u16 = 2 + digits(idx + 1) + @as(u16, @intCast(ts.tab.name.len)); // "▸N name"
        if (ts.fetched) w += 3 + digits(ts.visible.len); // " (N)"
        if (ts.fallback_note.len > 0) w += 3 + @as(u16, @intCast(ts.fallback_note.len));
        if (col >= x and col < x + w) return idx;
        x += w + 2;
    }
    return null;
}

fn digits(n: usize) u16 {
    var d: u16 = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

// ─── the setup screen ────────────────────────────────────────────────────

const no_token_text = "no Bitbucket token: set BITBUCKET_API_TOKEN (or BITBUCKET_APP_PASSWORD), or drop one in the config folder's `token` file";

/// A pane that cannot run yet: say what is missing, where, and take a
/// key. Exiting straight to mnml's banner would hide the reason.
fn setupLoop(gpa: Allocator, mount: *sdk.Mount, frame: *sdk.Frame, arena: *std.heap.ArenaAllocator, reason: []const u8) !u8 {
    while (true) {
        _ = arena.reset(.retain_capacity);
        frame.clear(.{});
        const lines = [_]view.Line{
            .{ .text = "BITBUCKET — setup", .tone = .accent },
            .{ .text = "" },
            .{ .text = reason, .tone = .warn },
            .{ .text = "" },
            .{ .text = "1. edit config.zon: `email`, `workspace`, `repos`, `tabs`", .tone = .normal },
            .{ .text = "2. export BITBUCKET_API_TOKEN (Pull requests: Read, Account: Read)", .tone = .normal },
            .{ .text = "3. optionally export BITBUCKET_ACCESS_TOKEN for the writes", .tone = .normal },
            .{ .text = "" },
            .{ .text = "`mnml-bitbucket --check` prints the whole picture.", .tone = .dim },
            .{ .text = "q closes this pane; reopen it once the config is there", .tone = .dim },
        };
        view.paintLines(frame, &lines, .{ .width = frame.cols, .height = frame.rows }, 0, null);
        try mount.send(frame);
        var msg_arena = std.heap.ArenaAllocator.init(gpa);
        defer msg_arena.deinit();
        const msg = (try mount.next(msg_arena.allocator())) orelse break;
        switch (msg) {
            .goodbye => break,
            .resize => |r| try frame.resize(r.geometry.cols, r.geometry.rows),
            .input => |in| switch (in.event) {
                .key => |k| {
                    if (std.mem.eql(u8, k.spec, "q")) break;
                    if (std.mem.eql(u8, k.spec, "r")) mount.toast(.info, "reopen the pane to pick the config up") catch {};
                },
                else => {},
            },
            else => {},
        }
    }
    mount.bye();
    return 0;
}

// ─── the headless subcommands ────────────────────────────────────────────

fn resolveBaseUrl(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, config: cfg.Config) Allocator.Error![]u8 {
    const from_env = env.get("BITBUCKET_BASE_URL") orelse "";
    if (from_env.len > 0) {
        // `@<path>` reads the URL out of a file — the fake server
        // writes one with `--url-file`, so a test never has to pick a
        // port. The file may not be there yet; wait a moment for it.
        if (from_env[0] == '@') {
            const path = from_env[1..];
            var tries: u8 = 0;
            while (tries < 30) : (tries += 1) {
                if (Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096))) |text| {
                    defer gpa.free(text);
                    const trimmed = std.mem.trim(u8, text, " \t\r\n");
                    if (trimmed.len > 0) return gpa.dupe(u8, trimmed);
                } else |_| {}
                io.sleep(.fromMilliseconds(100), .awake) catch {};
            }
            return gpa.dupe(u8, api.default_base_url);
        }
        return gpa.dupe(u8, from_env);
    }
    if (config.base_url.len > 0) return gpa.dupe(u8, config.base_url);
    return gpa.dupe(u8, api.default_base_url);
}

fn diagnose(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, w: *Io.Writer, full: bool) !u8 {
    try w.print("mnml-bitbucket {s} (bridge protocol {d})\n\n", .{ spec.version, sdk.protocol });
    var why: []const u8 = "";
    var loaded = cfg.load(gpa, io, env, &why) catch |err| {
        try w.print("config: {s}\n  {s}\n", .{ @errorName(err), why });
        try w.flush();
        return 1;
    };
    defer loaded.deinit();
    const c = loaded.config;
    try w.print("config:      {s}\n", .{loaded.path});
    try w.print("email:       {s}\n", .{c.email});
    try w.print("workspace:   {s}\n", .{c.workspace});
    try w.print("repos:       {d} ({s}{s})\n", .{
        c.repos.len,
        if (c.repos.len > 0) c.repos[0] else "none",
        if (c.repos.len > 1) ", …" else "",
    });
    try w.print("tabs:        {d}\n", .{c.tabs.len});
    if (full) for (c.tabs) |tab| {
        try w.print("  · {s}  kind={s} mode={s} fallback={s} repo={s} state={s}\n", .{
            tab.name,
            @tagName(tab.kind),
            @tagName(tab.mode),
            @tagName(tab.fallback),
            if (tab.repo.len > 0) tab.repo else "—",
            @tagName(tab.state),
        });
    };

    const config_dir = std.fs.path.dirname(loaded.path) orelse ".";
    var tokens = try auth.resolve(gpa, io, env, config_dir);
    defer tokens.deinit();
    const described = try auth.describe(gpa, &tokens);
    defer gpa.free(described);
    try w.writeAll(described);
    if (tokens.writeRefusal()) |r| try w.print("writes:      refused — {s}\n", .{r});

    if (full) {
        try w.print("jira:        {s} (installed: {s})\n", .{
            if (c.jira.enabled) "on" else "off",
            if (links.installed(gpa, io, env, "jira")) "yes" else "no",
        });
        try w.print("github:      {s} (installed: {s})\n", .{
            if (c.github.enabled) "on" else "off",
            if (links.installed(gpa, io, env, "github")) "yes" else "no",
        });
        try w.print("checkout:    {s}\n", .{if (c.mnml.allow_checkout) "allowed" else "off"});
    }

    if (!tokens.hasRead()) {
        try w.writeAll("\nno read token — nothing to verify against Bitbucket.\n");
        try w.flush();
        return 1;
    }
    const base = try resolveBaseUrl(gpa, io, env, c);
    defer gpa.free(base);
    try w.print("api:         {s}\n", .{base});
    var client = try api.Client.init(gpa, io, base, c.email, tokens.read, tokens.write, c.rate);
    defer client.deinit();
    var reply = try client.whoami(gpa);
    defer reply.deinit(gpa);
    switch (reply) {
        .ok => |b| {
            var parsed = std.json.parseFromSlice(std.json.Value, gpa, b.bytes, .{}) catch {
                try w.writeAll("whoami:      answered, but not with JSON\n");
                try w.flush();
                return 1;
            };
            defer parsed.deinit();
            try w.print("whoami:      {s} ({s})\n", .{ j.str(parsed.value, "display_name"), j.str(parsed.value, "account_id") });
            try w.flush();
            return 0;
        },
        .failed => |f| {
            var buf: [96]u8 = undefined;
            try w.print("whoami:      {s} — {s}\n", .{ f.shortLabel(&buf), f.message });
            try w.flush();
            return 1;
        },
    }
}

/// `--refresh`: count the review queue and republish the segment and
/// the badge, with no pane. This is what `bitbucket.refresh` runs.
/// The file-IPC channel: `$MNML_IPC_DIR` when mnml set it (a mount
/// child always has it), else mnml's default under the workspace the
/// ex line passed. mnml's own subdir is a build option, so both
/// spellings are tried and the one that exists wins.
fn openIpc(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, workspace: []const u8) Allocator.Error!?sdk.Ipc {
    if (try sdk.Ipc.fromEnv(gpa, io, env)) |x| return x;
    const ws = if (workspace.len > 0) workspace else env.get("MNML_WORKSPACE") orelse return null;
    for ([_][]const u8{ "ipc-zig", "ipc" }) |subdir| {
        const dir = try std.fs.path.join(gpa, &.{ ws, ".mnml", subdir });
        defer gpa.free(dir);
        if (Io.Dir.cwd().access(io, dir, .{})) |_| return try sdk.Ipc.init(gpa, io, dir) else |_| {}
    }
    return null;
}

fn refreshCounts(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, w: *Io.Writer, workspace: []const u8) !u8 {
    var why: []const u8 = "";
    var loaded = cfg.load(gpa, io, env, &why) catch |err| {
        try w.print("mnml-bitbucket --refresh: {s}: {s}\n", .{ @errorName(err), why });
        try w.flush();
        return 1;
    };
    defer loaded.deinit();
    const c = loaded.config;
    const config_dir = std.fs.path.dirname(loaded.path) orelse ".";
    var tokens = try auth.resolve(gpa, io, env, config_dir);
    defer tokens.deinit();
    if (!tokens.hasRead()) {
        try w.writeAll("mnml-bitbucket --refresh: no read token\n");
        try w.flush();
        return 1;
    }
    const base = try resolveBaseUrl(gpa, io, env, c);
    defer gpa.free(base);
    var client = try api.Client.init(gpa, io, base, c.email, tokens.read, tokens.write, c.rate);
    defer client.deinit();

    var who = try client.whoami(gpa);
    defer who.deinit(gpa);
    if (who != .ok) {
        try w.writeAll("mnml-bitbucket --refresh: the token cannot read the account (Account: Read)\n");
        try w.flush();
        return 1;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, who.ok.bytes, .{}) catch {
        try w.writeAll("mnml-bitbucket --refresh: /2.0/user did not answer JSON\n");
        try w.flush();
        return 1;
    };
    defer parsed.deinit();
    const predicate = try api.reviewerPredicate(gpa, j.str(parsed.value, "account_id"));
    defer gpa.free(predicate);

    var count: usize = 0;
    for (c.repos) |slug| {
        if (c.isHidden(slug)) continue;
        var reply = try client.listPrs(gpa, c.workspace, slug, .OPEN, predicate, c.page_len);
        defer reply.deinit(gpa);
        if (reply != .ok) continue;
        var page = std.json.parseFromSlice(std.json.Value, gpa, reply.ok.bytes, .{}) catch continue;
        defer page.deinit();
        count += j.array(page.value, "values").len;
    }

    if (try openIpc(gpa, io, env, workspace)) |ipc_const| {
        var ipc = ipc_const;
        defer ipc.deinit();
        var buf: [32]u8 = undefined;
        ipc.statuslineSetSegment(.{
            .id = "bitbucket.review",
            .text = std.fmt.bufPrint(&buf, "BB·{d}", .{count}) catch "BB",
            .color = if (count > 0) "blue" else "comment",
            .click_command = "bitbucket.review_queue",
            .priority = 60,
        }) catch {};
        ipc.setActivityBadge("integrations", @intCast(count)) catch {};
    }
    try w.print("{d} pull requests waiting on your review\n", .{count});
    try w.flush();
    return 0;
}

// ─── tests ───────────────────────────────────────────────────────────────

test {
    _ = @import("src/json.zig");
    _ = @import("src/model.zig");
    _ = @import("src/config.zig");
    _ = @import("src/auth.zig");
    _ = @import("src/api.zig");
    _ = @import("src/git.zig");
    _ = @import("src/links.zig");
    _ = @import("src/view.zig");
    _ = @import("src/app.zig");
    _ = @import("src/os.zig");
    _ = @import("src/screen.zig");
}

const t = std.testing;
const listener = @import("tools/fake_bitbucket/listener.zig");

test "the manifest names the pane command first, with a chip, a segment, settings and the auth fields" {
    try t.expectEqualStrings("bitbucket", spec.id);
    try t.expectEqualStrings("mnml-bitbucket", spec.binary);
    try t.expectEqualStrings("bitbucket.open", spec.commands[0].id);
    try t.expect(spec.commands[0].ex == null);
    // The four the brief names, in the order the palette shows them.
    const ids = [_][]const u8{ "bitbucket.open", "bitbucket.my_prs", "bitbucket.review_queue", "bitbucket.refresh" };
    try t.expectEqual(ids.len, spec.commands.len);
    for (ids, spec.commands) |want, got| try t.expectEqualStrings(want, got.id);
    // my_prs and review_queue open the binary on a tab; refresh is the
    // headless one and carries a run line instead.
    try t.expectEqualStrings("--tab", spec.commands[1].args[0]);
    try t.expectEqualStrings("mine", spec.commands[1].args[1]);
    try t.expectEqualStrings("reviewing", spec.commands[2].args[1]);
    try t.expect(spec.commands[3].line() != null);
    try t.expect(spec.chip != null);
    try t.expectEqualStrings("BB", spec.chip.?.fallback);
    try t.expectEqual(@as(usize, 1), spec.statusline.len);
    try t.expectEqualStrings("bitbucket.review_queue", spec.statusline[0].click_command.?);
    try t.expectEqual(@as(usize, 2), spec.settings.len);
    try t.expectEqualStrings("diff", spec.settings[0].key);
    try t.expectEqual(@as(usize, 4), spec.auth.len);
    try t.expectEqualStrings("BITBUCKET_ACCESS_TOKEN", spec.auth[2].env_fallback.?);
    var why: []const u8 = "";
    try sdk.manifest.validate(spec, &why);
}

test "the manifest renders and parses back to the same shape" {
    const text = try sdk.manifest.render(t.allocator, spec);
    defer t.allocator.free(text);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const z = try arena_state.allocator().dupeZ(u8, text);
    const back = try std.zon.parse.fromSliceAlloc(sdk.Manifest, arena_state.allocator(), z, null, .{ .free_on_error = false });
    try t.expectEqualStrings(spec.id, back.id);
    try t.expectEqualStrings("bitbucket.open", back.commands[0].id);
    try t.expectEqualStrings("term mnml-bitbucket --refresh --workspace {{workspace}}", back.commands[3].line().?);
    try t.expectEqualStrings("review", back.statusline[0].id);
    try t.expectEqualStrings("BB", back.chip.?.fallback);
}

test "--tab picks by mode name, then by tab name, and falls back to the first" {
    const config: cfg.Config = .{
        .tabs = &.{
            .{ .name = "Everything", .mode = .workspace },
            .{ .name = "Mine", .mode = .mine },
            .{ .name = "Review queue", .mode = .reviewing },
        },
    };
    try t.expectEqual(@as(usize, 0), pickTab(config, ""));
    try t.expectEqual(@as(usize, 1), pickTab(config, "mine"));
    try t.expectEqual(@as(usize, 2), pickTab(config, "reviewing"));
    try t.expectEqual(@as(usize, 2), pickTab(config, "Review queue"));
    try t.expectEqual(@as(usize, 2), pickTab(config, "review queue"));
    // A name nothing answers to opens the first tab rather than none.
    try t.expectEqual(@as(usize, 0), pickTab(config, "nonsense"));
}

test "the base URL is the environment's, then the config's, then Bitbucket's" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const fallback = try resolveBaseUrl(t.allocator, t.io, &env, .{});
    defer t.allocator.free(fallback);
    try t.expectEqualStrings(api.default_base_url, fallback);

    const from_config = try resolveBaseUrl(t.allocator, t.io, &env, .{ .base_url = "https://example.test/2.0" });
    defer t.allocator.free(from_config);
    try t.expectEqualStrings("https://example.test/2.0", from_config);

    try env.put("BITBUCKET_BASE_URL", "http://127.0.0.1:9/2.0");
    const from_env = try resolveBaseUrl(t.allocator, t.io, &env, .{ .base_url = "https://example.test/2.0" });
    defer t.allocator.free(from_env);
    try t.expectEqualStrings("http://127.0.0.1:9/2.0", from_env);
}

test "an @file base URL is read out of the file the fake server wrote" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const url_file = try std.fs.path.join(t.allocator, &.{ dir, "bb.url" });
    defer t.allocator.free(url_file);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bb.url", .data = "http://127.0.0.1:41234/2.0\n" });
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const at = try std.fmt.allocPrint(t.allocator, "@{s}", .{url_file});
    defer t.allocator.free(at);
    try env.put("BITBUCKET_BASE_URL", at);
    const got = try resolveBaseUrl(t.allocator, t.io, &env, .{});
    defer t.allocator.free(got);
    try t.expectEqualStrings("http://127.0.0.1:41234/2.0", got);
}

test "--check prints the config, the token sources and the whoami, and never the token" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.createDirPath(t.io, "integrations/bitbucket");
    try tmp.dir.writeFile(t.io, .{
        .sub_path = "integrations/bitbucket/config.zon",
        .data =
        \\.{ .email = "me@example.com", .workspace = "acme", .repos = .{"api"},
        \\   .tabs = .{ .{ .name = "Review queue", .mode = .reviewing } } }
        ,
    });
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("MNML_DATA_ROOT", root);
    try env.put("BITBUCKET_API_TOKEN", "ATATT-super-secret-value");
    try env.put("BITBUCKET_BASE_URL", base);

    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try t.expectEqual(@as(u8, 0), try diagnose(t.allocator, t.io, &env, &out.writer, true));
    const text = out.written();
    try t.expect(std.mem.indexOf(u8, text, "me@example.com") != null);
    try t.expect(std.mem.indexOf(u8, text, "workspace:   acme") != null);
    try t.expect(std.mem.indexOf(u8, text, "mode=reviewing") != null);
    try t.expect(std.mem.indexOf(u8, text, "BITBUCKET_API_TOKEN") != null);
    try t.expect(std.mem.indexOf(u8, text, "whoami:      Chris M (acct-chris)") != null);
    // The secret is nowhere in the diagnostic, whole or in part.
    try t.expect(std.mem.indexOf(u8, text, "ATATT-super-secret-value") == null);
    try t.expect(std.mem.indexOf(u8, text, "secret") == null);
}

test "--check on a first run writes the scaffold, says so, and exits non-zero" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("MNML_DATA_ROOT", root);
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try t.expectEqual(@as(u8, 1), try diagnose(t.allocator, t.io, &env, &out.writer, false));
    try t.expect(std.mem.indexOf(u8, out.written(), "Scaffolded") != null);
    try t.expect(std.mem.indexOf(u8, out.written(), "config.zon") != null);
}

test "--refresh counts the review queue and publishes a segment and a badge" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.createDirPath(t.io, "integrations/bitbucket");
    try tmp.dir.createDirPath(t.io, "ipc");
    try tmp.dir.writeFile(t.io, .{
        .sub_path = "integrations/bitbucket/config.zon",
        .data =
        \\.{ .email = "me@example.com", .workspace = "acme", .repos = .{ "api", "web" },
        \\   .tabs = .{ .{ .name = "Review queue", .mode = .reviewing } } }
        ,
    });
    const ipc_dir = try std.fs.path.join(t.allocator, &.{ root, "ipc" });
    defer t.allocator.free(ipc_dir);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("MNML_DATA_ROOT", root);
    try env.put("BITBUCKET_API_TOKEN", "tok");
    try env.put("BITBUCKET_BASE_URL", base);
    try env.put("MNML_IPC_DIR", ipc_dir);

    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try t.expectEqual(@as(u8, 0), try refreshCounts(t.allocator, t.io, &env, &out.writer, ""));
    try t.expectEqualStrings("1 pull requests waiting on your review\n", out.written());

    const lines = try tmp.dir.readFileAlloc(t.io, "ipc/command", t.allocator, .unlimited);
    defer t.allocator.free(lines);
    try t.expect(std.mem.indexOf(u8, lines, "\"cmd\":\"statusline-set-segment\"") != null);
    try t.expect(std.mem.indexOf(u8, lines, "\"id\":\"bitbucket.review\"") != null);
    try t.expect(std.mem.indexOf(u8, lines, "\"text\":\"BB·1\"") != null);
    try t.expect(std.mem.indexOf(u8, lines, "\"click_command\":\"bitbucket.review_queue\"") != null);
    try t.expect(std.mem.indexOf(u8, lines, "\"cmd\":\"set-activity-badge\",\"section\":\"integrations\",\"count\":1") != null);
}

test "a click on the tab strip lands on the tab whose label is under the pointer" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    var client = try api.Client.init(t.allocator, t.io, base, "me@x.com", "tok", "tok", .{ .min_interval_ms = 0 });
    defer client.deinit();
    var app = try app_mod.App.init(t.allocator, t.io, .{
        .email = "me@x.com",
        .workspace = "acme",
        .repos = &.{"api"},
        .tabs = &.{
            .{ .name = "api", .mode = .repo, .repo = "api" },
            .{ .name = "web", .mode = .repo, .repo = "web" },
        },
    }, &client);
    defer app.deinit();
    app.rows = 24;
    app.cols = 120;
    try app.switchTab(0);
    // " 1 api (2)" is ten cells wide (the ▸ on the active one is one
    // cell); "web" starts two cells later.
    try t.expectEqual(@as(usize, 0), tabAtColumn(t.allocator, &app, 2).?);
    try t.expectEqual(@as(usize, 1), tabAtColumn(t.allocator, &app, 13).?);
    try t.expect(tabAtColumn(t.allocator, &app, 110) == null);
    _ = try click(t.allocator, &app, 13, 0, false);
    try t.expectEqual(@as(usize, 1), app.active);
    // A click in the body picks the row under the pointer; a
    // right-click opens its detail.
    _ = try click(t.allocator, &app, 0, 3, false);
    try t.expectEqual(@as(usize, 0), app.activeTab().selected);
    _ = try click(t.allocator, &app, 0, 99, false); // past the last row: nothing
    try t.expectEqual(@as(usize, 0), app.activeTab().selected);
}
