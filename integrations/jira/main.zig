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
pub const version = "0.2.0";

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

    try stderr.writeAll("mnml-jira is an mnml integration: open it from mnml (jira_work.open), or run `mnml-jira --install` / `--check`.\n");
    return 2;
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
    try testing.expectEqual(@as(usize, 1), spec_work.statusline.len);
    try testing.expectEqualStrings("jira_work.open", spec_work.statusline[0].click_command.?);
    try testing.expectEqualStrings("#1B5DCF", spec_work.statusline[0].color.?);
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
