//! mnml-jira — the Jira ticket viewer, written on `mnml-sdk`.
//!
//!   mnml-jira --install            write the manifest (then `integrations.refresh`)
//!   mnml-jira --uninstall          delete it
//!   mnml-jira --version
//!   mnml-jira --check              the config and the token, no network
//!   mnml-jira --write-config       drop an example config.zon where one belongs
//!   mnml-jira --values             {"assigned_open": N} for a statusline poller
//!   mnml-jira [--tab NAME] [--filter] [--refresh-all] [--config PATH]
//!                                  connect to `$MNML_MOUNT_SOCKET` and paint
//!
//! The manifest is `manifest.zon` beside this file, `@import`ed so the
//! binary and the INTEGRATIONS panel's Dev tab read one definition. Its
//! three commands are the three ways in: the pane (`jira.open`), the
//! pane with every tab reloaded (`jira.refresh`, `--refresh-all`), and
//! the pane with the filter box already up (`jira.search`, `--filter`).
//!
//! The mount loop is the SDK's: size a `Frame` to `mount.geometry`,
//! paint, `send`; then react to `resize`, `input`, `focus` and
//! `goodbye`. A refresh happens on that loop (see `src/app.zig`), and
//! the progress sink below is what makes its line move while it runs.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const sdk = @import("mnml_sdk");

const app_mod = @import("src/app.zig");
const auth = @import("src/auth.zig");
const config = @import("src/config.zig");
const jira = @import("src/jira.zig");
const theme = @import("src/theme.zig");
const ui = @import("src/ui.zig");

pub const spec: sdk.Manifest = @import("manifest.zon");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var err_buf: [4096]u8 = undefined;
    var err_w: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const stderr = &err_w.interface;
    defer stderr.flush() catch {};
    var out_buf: [4096]u8 = undefined;
    var out_w: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const stdout = &out_w.interface;
    defer stdout.flush() catch {};

    var opts: Opts = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--install")) {
            const path = sdk.manifest.write(gpa, io, env, spec) catch |e| {
                try stderr.print("mnml-jira: could not write the manifest: {s}\n", .{@errorName(e)});
                return 1;
            };
            defer gpa.free(path);
            try stderr.print("mnml-jira: wrote {s}\n", .{path});
            return 0;
        }
        if (std.mem.eql(u8, a, "--uninstall")) {
            const went = sdk.manifest.remove(gpa, io, env, spec.id) catch |e| {
                try stderr.print("mnml-jira: could not remove the manifest: {s}\n", .{@errorName(e)});
                return 1;
            };
            try stderr.print("mnml-jira: {s}\n", .{if (went) "removed the manifest" else "nothing to remove"});
            return 0;
        }
        if (std.mem.eql(u8, a, "--version")) {
            try stderr.print("mnml-jira {s} (bridge protocol {d})\n", .{ spec.version, sdk.protocol });
            return 0;
        }
        if (std.mem.eql(u8, a, "--check")) opts.check = true;
        if (std.mem.eql(u8, a, "--values")) opts.values = true;
        if (std.mem.eql(u8, a, "--write-config")) opts.write_config = true;
        if (std.mem.eql(u8, a, "--filter")) opts.filter = true;
        if (std.mem.eql(u8, a, "--refresh-all")) opts.refresh_all = true;
        if (std.mem.eql(u8, a, "--config") and i + 1 < args.len) {
            i += 1;
            opts.config_path = args[i];
        }
        if (std.mem.eql(u8, a, "--tab") and i + 1 < args.len) {
            i += 1;
            opts.tab = args[i];
        }
    }

    // Where everything lives, before anything is read.
    const data_root = try sdk.manifest.dataRoot(arena, env);
    const cfg_path = try config.resolvePath(arena, io, .{
        .explicit = opts.config_path,
        .workspace = env.get("MNML_WORKSPACE"),
        .data_root = data_root,
    }, env.get(config.env_path));

    if (opts.write_config) {
        if (std.fs.path.dirname(cfg_path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
        Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = config.example }) catch |e| {
            try stderr.print("mnml-jira: could not write {s}: {s}\n", .{ cfg_path, @errorName(e) });
            return 1;
        };
        try stderr.print("mnml-jira: wrote {s} — edit it, then open the pane\n", .{cfg_path});
        return 0;
    }

    const loaded = try config.load(arena, io, cfg_path);
    const token = try auth.resolve(arena, io, env, .{
        .config_path = loaded.config.jira.token_file,
        .env_name = loaded.config.jira.token_env,
        .data_root = data_root,
    });

    if (opts.check) return check(arena, stderr, cfg_path, loaded, token);
    if (opts.values) return values(gpa, io, arena, stderr, stdout, loaded.config, token);

    const mount = sdk.Mount.connectEnv(gpa, io, env) catch |e| switch (e) {
        error.NoSocket => {
            try stderr.print(
                "mnml-jira is an mnml integration: open it from mnml (jira.open), or run `mnml-jira --install` / `--check`\n",
                .{},
            );
            return 2;
        },
        else => return e,
    };
    defer mount.destroy();

    var app = app_mod.App.init(gpa, io);
    defer app.deinit();
    app.cfg = loaded.config;
    app.cfg_path = cfg_path;
    app.palette = theme.Palette.forTheme(mount.hello.theme);
    app.cols = mount.geometry.cols;
    app.rows = mount.geometry.rows;

    // Why the pane cannot show tickets, when it cannot. Every arm names
    // the file and the next step, so nothing is ever a blank screen.
    var why: []const u8 = "";
    if (loaded.missing) {
        app.blocked = try missingConfig(arena, cfg_path);
    } else if (loaded.parse_error) |e| {
        app.blocked = try parseError(arena, cfg_path, e);
    } else if (config.validate(loaded.config, &why)) |_| {
        switch (token) {
            .missing => |m| app.blocked = try auth.explain(arena, m),
            .ok => |t| {
                app.client = jira.Client.init(
                    gpa,
                    io,
                    loaded.config.jira.url,
                    try auth.basicHeader(arena, loaded.config.jira.email, t.value),
                    loaded.config.jira.api,
                    loaded.config.jira.rate,
                );
                try app.openTabs();
                if (opts.tab) |name| for (app.tabs, 0..) |*t2, n| {
                    if (std.mem.eql(u8, t2.cfg.name, name)) app.active = n;
                };
            },
        }
    } else |_| {
        app.blocked = try configProblem(arena, cfg_path, why);
    }

    // The config first, then the settings mnml hands down
    // (`MNML_SETTING_<KEY>`), which are what the user last chose in the
    // settings overlay and so win.
    app.detail_open = loaded.config.mnml.detail_open;
    if (env.get("MNML_SETTING_DETAIL")) |v| app.detail_open = !std.mem.eql(u8, v, "hidden");
    if (env.get("MNML_SETTING_GROUP")) |v| {
        const by: config.GroupBy = if (std.mem.eql(u8, v, "status")) .status else .hierarchy;
        for (app.tabs) |*t| t.cfg.group_by = by;
    }

    const chrome: ui.Chrome = .{
        .ascii = mount.hello.capabilities.ascii or !mount.hello.capabilities.nerd_font,
        .triangle = loaded.config.mnml.expand_indicator == .triangle or
            std.mem.eql(u8, env.get("MNML_EXPAND_INDICATOR") orelse "", "triangle"),
    };

    var frame = try sdk.Frame.init(gpa, app.cols, app.rows);
    defer frame.deinit();

    // The sink: a repaint from inside a refresh, so the progress line
    // moves while the pane is on the wire.
    var painter: Painter = .{ .app = &app, .frame = &frame, .mount = mount, .chrome = chrome };
    app.sink = .{ .ctx = &painter, .paint = Painter.paint };

    try mount.setTitle("jira");
    if (app.blocked == null) {
        app.setStatus("loading\u{2026}", .{});
        painter.repaint();
        const was = app.active;
        if (opts.refresh_all) {
            var n: usize = 0;
            while (n < app.tabs.len) : (n += 1) {
                app.active = n;
                app.refresh() catch |e| app.setStatus("refresh failed: {s}", .{@errorName(e)});
            }
            app.active = was;
        } else {
            app.refresh() catch |e| app.setStatus("refresh failed: {s}", .{@errorName(e)});
        }
        publish(gpa, io, env, &app) catch {};
        if (opts.filter) app.key("/") catch {};
    }
    painter.repaint();

    var msg_arena = std.heap.ArenaAllocator.init(gpa);
    defer msg_arena.deinit();
    while (true) {
        _ = msg_arena.reset(.retain_capacity);
        const msg = (try mount.next(msg_arena.allocator())) orelse break;
        switch (msg) {
            .hello => {},
            .focus => |on| if (on) {
                app.focusGained() catch |e| app.setStatus("{s}", .{@errorName(e)});
            } else {
                app.focused = false;
            },
            .goodbye => break,
            .resize => |r| {
                try frame.resize(r.geometry.cols, r.geometry.rows);
                app.cols = r.geometry.cols;
                app.rows = r.geometry.rows;
            },
            .input => |in| switch (in.event) {
                .key => |k| {
                    app.key(k.spec) catch |e| app.setStatus("{s}", .{@errorName(e)});
                    if (app.done) {
                        mount.bye();
                        break;
                    }
                },
                .click => |c| app.click(c.col, c.row, c.button == .right) catch {},
                .scroll => |s| app.wheel(s.dy) catch {},
                .hover, .paste => {},
            },
        }
        painter.repaint();
    }
    return 0;
}

const Opts = struct {
    check: bool = false,
    values: bool = false,
    write_config: bool = false,
    filter: bool = false,
    refresh_all: bool = false,
    config_path: ?[]const u8 = null,
    tab: ?[]const u8 = null,
};

/// Holds what a repaint needs, so `App.sink` can be a plain function.
const Painter = struct {
    app: *app_mod.App,
    frame: *sdk.Frame,
    mount: *sdk.Mount,
    chrome: ui.Chrome,

    fn repaint(p: *Painter) void {
        ui.draw(p.frame, p.app, p.chrome) catch return;
        p.mount.send(p.frame) catch {};
    }

    fn paint(ctx: ?*anyopaque) void {
        const p: *Painter = @ptrCast(@alignCast(ctx orelse return));
        p.repaint();
    }
};

/// `--check`: everything a diagnostic needs and nothing that needs the
/// network — and never the token, only its length.
fn check(arena: Allocator, w: *Io.Writer, cfg_path: []const u8, loaded: config.Loaded, token: auth.Result) !u8 {
    try w.print("mnml-jira {s}\n", .{spec.version});
    try w.print("config: {s}{s}\n", .{ cfg_path, if (loaded.missing) "  (not there yet \u{2014} --write-config makes one)" else "" });
    if (loaded.parse_error) |e| try w.print("config: PARSE ERROR {s}\n", .{e});
    try w.print("site:   {s}\n", .{if (loaded.config.jira.url.len > 0) loaded.config.jira.url else "(unset)"});
    try w.print("email:  {s}\n", .{if (loaded.config.jira.email.len > 0) loaded.config.jira.email else "(unset)"});
    try w.print("api:    {s}\n", .{@tagName(loaded.config.jira.api)});
    try w.print("{s}\n", .{try auth.describe(arena, token)});
    for (loaded.config.tabs, 0..) |t, n| {
        const jql = (try t.staticJql(arena)) orelse "(resolved at refresh)";
        try w.print("tab {d}: {s} [{s}] {s}\n", .{ n + 1, t.name, @tagName(t.kind), jql });
    }
    var why: []const u8 = "";
    config.validate(loaded.config, &why) catch {
        try w.print("config: {s}\n", .{why});
        return 1;
    };
    return 0;
}

/// `--values`: one search, one JSON line — what a statusline poller reads.
fn values(gpa: Allocator, io: Io, arena: Allocator, err: *Io.Writer, out: *Io.Writer, cfg: config.Config, token: auth.Result) !u8 {
    const t: auth.Token = switch (token) {
        .ok => |v| v,
        .missing => |m| {
            try err.print("mnml-jira --values: no token ({s})\n", .{@tagName(m.reason)});
            try out.print("{{\"assigned_open\":null}}\n", .{});
            return 1;
        },
    };
    var client = jira.Client.init(
        gpa,
        io,
        cfg.jira.url,
        try auth.basicHeader(arena, cfg.jira.email, t.value),
        cfg.jira.api,
        cfg.jira.rate,
    );
    const base = config.TabKind.work_assigned.defaultJql().?;
    const jql = try jira.withProjects(arena, base, cfg.jira.projects);
    switch (try jira.search(&client, arena, jql, &.{})) {
        .ok => |items| try out.print("{{\"assigned_open\":{d}}}\n", .{items.len}),
        .failed => |f| {
            try err.print("mnml-jira --values: {s}\n", .{f.message});
            try out.print("{{\"assigned_open\":null}}\n", .{});
            return 1;
        },
    }
    return 0;
}

/// The statusline segment and the activity badge, over Tier-2 IPC — the
/// count of tickets assigned to me in the first `work_*` tab, or the
/// first tab when there is none. The manifest's own `statusline` entry
/// is the static twin, for when the pane is not running.
fn publish(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, app: *app_mod.App) !void {
    var ipc = (try sdk.Ipc.fromEnv(gpa, io, env)) orelse return;
    defer ipc.deinit();
    const mine = mineCount(app);
    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "JIRA {d}", .{mine}) catch "JIRA";
    ipc.statuslineSetSegment(.{
        .id = "jira",
        .text = label,
        .color = "blue",
        .click_command = "jira.open",
        .priority = 60,
    }) catch {};
    ipc.setActivityBadge("integrations", @intCast(mine)) catch {};
}

/// How many tickets are mine: the first `work_assigned` / `work_unified`
/// tab's count, else the first tab's.
pub fn mineCount(app: *app_mod.App) usize {
    for (app.tabs) |*t| switch (t.cfg.kind) {
        .work_assigned, .work_unified => return t.issues.len,
        else => {},
    };
    return if (app.tabs.len > 0) app.tabs[0].issues.len else 0;
}

fn missingConfig(arena: Allocator, path: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    try out.append(arena, "No Jira config yet.");
    try out.append(arena, "");
    try out.append(arena, try std.fmt.allocPrint(arena, "Write one at {s}", .{path}));
    try out.append(arena, "or run:  mnml-jira --write-config");
    try out.append(arena, "");
    try out.append(arena, "It needs .jira.url, .jira.email and at least one tab.");
    try out.append(arena, "integrations/jira/README.md documents every key.");
    return out.toOwnedSlice(arena);
}

fn parseError(arena: Allocator, path: []const u8, why: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    try out.append(arena, "The config did not parse.");
    try out.append(arena, "");
    try out.append(arena, path);
    var it = std.mem.splitScalar(u8, why, '\n');
    while (it.next()) |line| try out.append(arena, line);
    return out.toOwnedSlice(arena);
}

fn configProblem(arena: Allocator, path: []const u8, why: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    try out.append(arena, "The config is not usable yet.");
    try out.append(arena, "");
    try out.append(arena, why);
    try out.append(arena, "");
    try out.append(arena, path);
    return out.toOwnedSlice(arena);
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test {
    _ = @import("src/ratelimit.zig");
    _ = @import("src/theme.zig");
    _ = @import("src/json.zig");
    _ = @import("src/text.zig");
    _ = @import("src/config.zig");
    _ = @import("src/auth.zig");
    _ = @import("src/jira.zig");
    _ = @import("src/model.zig");
    _ = @import("src/tree.zig");
    _ = @import("src/keys.zig");
    _ = @import("src/os.zig");
    _ = @import("src/app.zig");
    _ = @import("src/ui.zig");
}

test "the manifest names the pane command first, with a chip, a segment, settings and auth fields" {
    try testing.expectEqualStrings("jira", spec.id);
    try testing.expectEqualStrings("mnml-jira", spec.binary);
    try testing.expectEqualStrings("jira.open", spec.commands[0].id);
    try testing.expect(spec.commands[0].ex == null);
    try testing.expectEqual(@as(usize, 3), spec.commands.len);
    try testing.expect(spec.chip != null);
    try testing.expect(spec.chip.?.fallback.len > 0);
    try testing.expectEqual(@as(usize, 1), spec.statusline.len);
    try testing.expectEqualStrings("jira.open", spec.statusline[0].click_command.?);
    try testing.expectEqual(@as(usize, 2), spec.settings.len);
    try testing.expectEqual(@as(usize, 3), spec.auth.len);
    try sdk.manifest.validateId(spec.id);
    var why: []const u8 = "";
    try sdk.manifest.validate(spec, &why);
}

test "every id the manifest points at is one the manifest declares, and every id is namespaced" {
    // A command id that does not exist compiles, renders and reviews
    // clean; resolving it here is the only way to catch one.
    for (spec.commands) |c| try testing.expect(std.mem.startsWith(u8, c.id, "jira."));
    for (spec.statusline) |s| if (s.click_command) |id| try testing.expect(declares(id));
    for (spec.context_menu) |m| try testing.expect(declares(m.command));
    for (spec.menu_bar) |m| try testing.expect(declares(m.command));
}

fn declares(id: []const u8) bool {
    for (spec.commands) |c| if (std.mem.eql(u8, c.id, id)) return true;
    return false;
}

test "every argument a manifest command passes is one main.zig answers" {
    // `--refresh-all` and `--filter` reach the loop; a typo here would
    // make the command open a plain pane and look perfectly fine.
    const known = [_][]const u8{ "--refresh-all", "--filter", "--tab", "--config" };
    for (spec.commands) |c| for (c.args) |arg| {
        var ok = false;
        for (known) |k| if (std.mem.eql(u8, k, arg)) {
            ok = true;
        };
        try testing.expect(ok);
    };
}

test "the manifest renders and parses back to the same shape" {
    const rendered = try sdk.manifest.render(testing.allocator, spec);
    defer testing.allocator.free(rendered);
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const z = try a.allocator().dupeZ(u8, rendered);
    const back = try std.zon.parse.fromSliceAlloc(sdk.Manifest, a.allocator(), z, null, .{ .free_on_error = false });
    try testing.expectEqualStrings(spec.id, back.id);
    try testing.expectEqualStrings(spec.binary, back.binary);
    try testing.expectEqualStrings(spec.commands[0].id, back.commands[0].id);
    try testing.expectEqualStrings("--refresh-all", back.commands[1].args[0]);
    try testing.expectEqualStrings("jira", back.statusline[0].id);
    try testing.expectEqualStrings("api_token", back.auth[2].key);
    try testing.expectEqualStrings("JIRA_API_TOKEN", back.auth[2].env_fallback.?);
}

test "the blocked screens name the file and what to do about it" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const none = try missingConfig(arena, "/h/.config/mnml/integrations/jira/config.zon");
    try testing.expectEqualStrings("No Jira config yet.", none[0]);
    try testing.expect(std.mem.indexOf(u8, none[2], "/h/.config/mnml") != null);
    try testing.expect(std.mem.indexOf(u8, none[3], "--write-config") != null);
    const broken = try parseError(arena, "/x/config.zon", "1:3: expected a field");
    try testing.expectEqualStrings("The config did not parse.", broken[0]);
    try testing.expect(std.mem.indexOf(u8, broken[3], "expected a field") != null);
    const bad = try configProblem(arena, "/x/config.zon", "jira.url is empty");
    try testing.expect(std.mem.indexOf(u8, bad[2], "jira.url") != null);
}

test "--check prints the config, the tabs and the token's length, and never the token" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const src = try arena.dupeZ(u8, config.example);
    const loaded = try config.parse(arena, src, "/x/config.zon");
    const code = try check(arena, &out.writer, "/x/config.zon", loaded, .{
        .ok = .{ .value = "sup3r-s3cret-token", .source = .environment },
    });
    try testing.expectEqual(@as(u8, 0), code);
    const s = out.written();
    try testing.expect(std.mem.indexOf(u8, s, "https://acme.atlassian.net") != null);
    try testing.expect(std.mem.indexOf(u8, s, "tab 1: Mine [work_assigned] assignee = currentUser()") != null);
    try testing.expect(std.mem.indexOf(u8, s, "tab 3: Release [fix_version] (resolved at refresh)") != null);
    try testing.expect(std.mem.indexOf(u8, s, "token: 18 chars") != null);
    try testing.expect(std.mem.indexOf(u8, s, "sup3r") == null);
}

test "--check fails on a config that cannot work, and says which key" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const loaded: config.Loaded = .{ .config = .{}, .path = "/x", .missing = true };
    const code = try check(arena, &out.writer, "/x/config.zon", loaded, .{
        .missing = .{ .reason = .nowhere, .path = "/x/token", .env_name = "JIRA_API_TOKEN" },
    });
    try testing.expectEqual(@as(u8, 1), code);
    const s = out.written();
    try testing.expect(std.mem.indexOf(u8, s, "not there yet") != null);
    try testing.expect(std.mem.indexOf(u8, s, "token: MISSING") != null);
    try testing.expect(std.mem.indexOf(u8, s, "jira.url is empty") != null);
}

test "mineCount prefers the assigned-to-me tab, and copes with no tabs at all" {
    var app = app_mod.App.init(testing.allocator, testing.io);
    defer app.deinit();
    try testing.expectEqual(@as(usize, 0), mineCount(&app));
    app.cfg = .{ .tabs = &.{
        .{ .name = "Release", .kind = .custom, .jql = "project = ENG" },
        .{ .name = "Mine", .kind = .work_assigned },
    } };
    try app.openTabs();
    try testing.expectEqual(@as(usize, 2), app.tabs.len);
    try testing.expectEqual(@as(usize, 0), mineCount(&app));
}
