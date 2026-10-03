//! What a terminal pane's child is told about the app it runs in.
//!
//! Every child: `MNML_PANE=1` — an integration opened with `:term
//! <binary>` keys its chrome on it (no outer border, the pane already
//! has one) — and `MNML_WORKSPACE`, the workspace it belongs to (a
//! session worktree's own `MNML_WORKSPACE` from `env_extra` wins).
//!
//! A shell additionally gets the prompt's environment: the theme's
//! colours as `MNML_PROMPT_{BG,FG,ACCENT,BLUE,GREEN,RED,YELLOW,GREY}`
//! (`#rrggbb`), `MNML_CONTEXT=mnml`, and `MNML_PROMPT_SCRIPT` — the path
//! of `themes/mnml-prompt.sh`, written into the data root and kept
//! current, which a user's rc file opts into with
//! `[ -n "$MNML_PROMPT_SCRIPT" ] && . "$MNML_PROMPT_SCRIPT"`. With no
//! data root (a unit test) there is no file and no `MNML_PROMPT_SCRIPT`.
//! And, with `terminal.shell_integration` on, what makes the shell load
//! mnml's shell integration — prompt marks, whatever the prompt
//! (`shell_integration.zig`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const App = @import("../app.zig").App;
const Theme = @import("../ui/theme.zig");
const shell_integration = @import("shell_integration.zig");
const api = @import("api.zig");
const api_paths = @import("../api/paths.zig");

pub const prompt_script = @import("themes").prompt_script;
pub const prompt_file = "prompt.sh";

pub const Launch = shell_integration.Launch;

/// The child's environment: the app's, the pane's `extra` `KEY=VALUE`
/// lines over it, and the variables above. `shell` is non-null for a
/// shell, and gets how to start it (the integration's handoff; its
/// strings are on the frame arena). The caller owns the map.
pub fn build(app: *App, pane: ?@import("../app.zig").PaneId, extra: []const []const u8, shell: ?*Launch) Allocator.Error!std.process.Environ.Map {
    var env = try app.env.clone(app.gpa);
    errdefer env.deinit();
    try env.put("MNML_PANE", "1");
    try env.put("MNML_WORKSPACE", app.workspace);
    // The API socket and this pane's own token (`app/api.zig`): what
    // `mnml remote` run in the pane reaches, as `pane:<id>`. An
    // inherited pair from an outer mnml never leaks through.
    _ = env.swapRemove(api_paths.env_socket);
    _ = env.swapRemove(api_paths.env_token);
    if (pane) |id| if (try api.mintToken(app, id)) |tok| {
        try env.put(api_paths.env_socket, app.api.socket);
        try env.put(api_paths.env_token, &tok);
    };
    for (extra) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        try env.put(kv[0..eq], kv[eq + 1 ..]);
    }
    if (shell) |launch| {
        try putPrompt(app, &env);
        launch.* = try shell_integration.apply(app.io, app.frame.allocator(), &env, app.data_root, app.cfg.terminal.shell_integration);
    }
    return env;
}

fn putPrompt(app: *App, env: *std.process.Environ.Map) Allocator.Error!void {
    const p = app.theme.palette;
    const pairs = [_]struct { []const u8, Theme.Color }{
        .{ "MNML_PROMPT_BG", p.bg_darker },
        .{ "MNML_PROMPT_FG", p.fg },
        .{ "MNML_PROMPT_ACCENT", p.teal },
        .{ "MNML_PROMPT_BLUE", p.blue },
        .{ "MNML_PROMPT_GREEN", p.green },
        .{ "MNML_PROMPT_RED", p.red },
        .{ "MNML_PROMPT_YELLOW", p.yellow },
        .{ "MNML_PROMPT_GREY", p.grey },
    };
    for (pairs) |pair| {
        // A palette slot without an rgb is left to the script's default.
        const rgb = switch (pair[1]) {
            .rgb => |v| v,
            else => continue,
        };
        var buf: [7]u8 = undefined;
        const hex = std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgb[0], rgb[1], rgb[2] }) catch unreachable;
        try env.put(pair[0], hex);
    }
    try env.put("MNML_CONTEXT", "mnml");
    if (try installPromptScript(app)) |path| try env.put("MNML_PROMPT_SCRIPT", path);
}

/// `<data root>/prompt.sh`, rewritten when it differs from the one this
/// build carries (an upgrade reaches it without the user deleting
/// anything). On the frame arena; null when there is nowhere to put it.
fn installPromptScript(app: *App) Allocator.Error!?[]const u8 {
    if (app.data_root.len == 0) return null;
    const arena = app.frame.allocator();
    const path = try std.fs.path.join(arena, &.{ app.data_root, prompt_file });
    const cwd = Io.Dir.cwd();
    const same = if (cwd.readFileAlloc(app.io, path, arena, .limited(1024 * 1024))) |have|
        std.mem.eql(u8, have, prompt_script)
    else |_|
        false;
    if (!same) {
        cwd.createDirPath(app.io, app.data_root) catch return null;
        cwd.writeFile(app.io, .{ .sub_path = path, .data = prompt_script }) catch return null;
    }
    return path;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "every child gets MNML_PANE and the workspace; a shell also gets the prompt's colours, and the script once there is a data root" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    var cmd = try build(&app, null, &.{"MNML_WORKSPACE=/tmp/worktree"}, null);
    defer cmd.deinit();
    try t.expectEqualStrings("1", cmd.get("MNML_PANE").?);
    // A session worktree's own workspace wins over the app's.
    try t.expectEqualStrings("/tmp/worktree", cmd.get("MNML_WORKSPACE").?);
    try t.expect(cmd.get("MNML_PROMPT_BG") == null);

    var launch: Launch = .{};
    var sh = try build(&app, null, &.{}, &launch);
    defer sh.deinit();
    try t.expectEqualStrings(app.workspace, sh.get("MNML_WORKSPACE").?);
    try t.expectEqualStrings("mnml", sh.get("MNML_CONTEXT").?);
    const bg = sh.get("MNML_PROMPT_BG").?;
    try t.expectEqual(@as(usize, 7), bg.len);
    try t.expectEqual(@as(u8, '#'), bg[0]);
    // No data root in a unit test: no file, so no variable.
    try t.expect(sh.get("MNML_PROMPT_SCRIPT") == null);

    // With one, the script is written there and named.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const old = app.data_root;
    app.data_root = root;
    defer app.data_root = old;
    var sh2 = try build(&app, null, &.{}, &launch);
    defer sh2.deinit();
    const path = sh2.get("MNML_PROMPT_SCRIPT").?;
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .limited(1024 * 1024));
    defer t.allocator.free(text);
    try t.expectEqualStrings(prompt_script, text);
}

test "a pane's child gets the API socket and its own token, minted at spawn and dropped when the pane closes" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    // An outer mnml's pair never leaks into a child.
    try app.env.put(api_paths.env_token, "outer");
    // Nothing serving: no socket, no token.
    var bare = try build(&app, 0, &.{}, null);
    defer bare.deinit();
    try t.expect(bare.get(api_paths.env_token) == null);
    try t.expectEqual(@as(usize, 0), app.api.tokens.count());

    app.api.socket = "/run/mnml/42.sock";
    const file = try std.fs.path.join(t.allocator, &.{ app.workspace, "x.txt" });
    defer t.allocator.free(file);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = file, .data = "x" });
    const id = try app.openPath(file);
    var env = try build(&app, id, &.{}, null);
    defer env.deinit();
    try t.expectEqualStrings("/run/mnml/42.sock", env.get(api_paths.env_socket).?);
    const tok = env.get(api_paths.env_token).?;
    try t.expectEqual(@as(usize, api.token_len), tok.len);
    try t.expectEqualStrings(tok, &app.api.tokens.get(id).?);
    // A respawn is a new token.
    var again = try build(&app, id, &.{}, null);
    defer again.deinit();
    try t.expect(!std.mem.eql(u8, tok, again.get(api_paths.env_token).?));

    try app.forceClosePane(id);
    try t.expect(app.api.tokens.get(id) == null);
}
