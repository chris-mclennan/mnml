//! The first-launch wizard, app side: the answers, what opens it, and
//! what Enter writes.
//!
//! Gated by one key, `ui.first_launch_complete`: the terminal loop opens
//! the wizard on start while it is false, and only Enter sets it. Esc is
//! "ask me later" and persists nothing — an undecided user must not have
//! their config rewritten. The `.test` runner never opens it on its own;
//! a script asks with `first_launch.show`.
//!
//! Enter writes only what was touched: `editor.input_style` if the row
//! was cycled (a returning vim user who never visits it keeps vim),
//! `ui.ascii_icons` from the Nerd Font answer, `ai.routing.<product>.backend`
//! per row cycled, `ai.inline_suggestions` from the ghost-text row — and
//! always `ui.first_launch_complete = true`, all to the home config.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Key = app_mod.Key;
const config = @import("../config/root.zig");
const Config = config.Config;
const input = @import("../input/mod.zig");
const wizard = @import("../ui/wizard.zig");
const settings = @import("settings.zig");

pub const State = struct {
    ui: wizard.State = .{},
    /// null = not answered.
    nerd_font_icons: ?bool = null,
    input_style: input.Style,
    input_touched: bool = false,
    route_claude: wizard.Route,
    route_codex: wizard.Route,
    routes_touched: [2]bool = .{ false, false },
    ai_row: u1 = 0,
    ghost_text: bool,
    ghost_touched: bool = false,
    keys_seen: [wizard.probes.len]bool = .{false} ** wizard.probes.len,
    claude_installed: bool = false,
    codex_installed: bool = false,
};

fn routeOf(backend: ?Config.AiBackend) wizard.Route {
    const b = backend orelse return .auto;
    return switch (b) {
        .auto => .auto,
        .sub => .sub,
        .api => .api,
        .off => .off,
    };
}

fn backendOf(r: wizard.Route) ?Config.AiBackend {
    return switch (r) {
        .auto => null,
        .sub => .sub,
        .api => .api,
        .off => .off,
    };
}

/// Does `$HOME/<dir>` exist — the cheap "is this CLI set up" probe.
fn homeHas(app: *App, dir: []const u8) bool {
    const home = app.homeDir() orelse return false;
    const p = std.fs.path.join(app.frame.allocator(), &.{ home, dir }) catch return false;
    var d = Io.Dir.cwd().openDir(app.io, p, .{}) catch return false;
    d.close(app.io);
    return true;
}

/// `first_launch.show`: open on the persisted answers.
pub fn show(app: *App) Allocator.Error!void {
    const c = &app.cfg;
    const st: State = .{
        .input_style = App.styleOf(c.editor.input_style),
        .route_claude = routeOf(c.ai.routing.claude.backend orelse c.ai.backend),
        .route_codex = routeOf(c.ai.routing.codex.backend orelse c.ai.backend),
        .ghost_text = c.ai.inline_suggestions,
        .nerd_font_icons = if (c.ui.ascii_icons) false else null,
        .claude_installed = homeHas(app, ".claude"),
        .codex_installed = homeHas(app, ".codex"),
    };
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .wizard = st };
    app.focus = .overlay;
    app.needs_render = true;
}

/// Open on start when nobody has finished it yet.
pub fn showIfPending(app: *App) Allocator.Error!void {
    if (app.cfg.ui.first_launch_complete) return;
    if (app.overlay != .none) return; // the trust dialog goes first
    try show(app);
}

pub fn model(app: *App) wizard.Model {
    const st = &app.overlay.wizard;
    return .{
        .nerd_font_icons = st.nerd_font_icons,
        .keys_seen = st.keys_seen,
        .vim = st.input_style == .vim,
        .claude_installed = st.claude_installed,
        .codex_installed = st.codex_installed,
        .route_claude = st.route_claude,
        .route_codex = st.route_codex,
        .ai_row = st.ai_row,
        .ghost_text = st.ghost_text,
    };
}

pub fn key(app: *App, k: Key) Allocator.Error!void {
    const st = &app.overlay.wizard;
    switch (wizard.handleKey(&st.ui, k)) {
        .consumed => {},
        .cancel => later(app),
        .finish => try finish(app),
        .adjust => |d| adjust(app, st.ui.section, d),
        .answer => |yes| answer(app, st.ui.section, yes),
        .probe => |i| st.keys_seen[i] = true,
        .other_row => st.ai_row +%= 1,
    }
    app.needs_render = true;
}

/// A click on a section header focuses it; on an answer chip, answers.
pub fn click(app: *App, hit: u32) void {
    const st = &app.overlay.wizard;
    switch (wizard.decodeHit(hit) orelse return) {
        .section => |s| st.ui.section = s,
        .chip => |c| {
            st.ui.section = c.section;
            switch (c.section) {
                .ai_routing => st.ai_row = @intCast(c.choice & 1),
                else => answer(app, c.section, c.choice == 1),
            }
        },
    }
    app.needs_render = true;
}

/// ←→ on a section: cycle its answer.
fn adjust(app: *App, section: wizard.Section, delta: i8) void {
    const st = &app.overlay.wizard;
    switch (section) {
        .nerd_font => answer(app, section, !(st.nerd_font_icons orelse false)),
        .input_style => answer(app, section, st.input_style != .vim),
        .ai_ghost_text => answer(app, section, !st.ghost_text),
        .ai_routing => {
            const n = wizard.route_labels.len;
            const cur: *wizard.Route = if (st.ai_row == 0) &st.route_claude else &st.route_codex;
            const i = @intFromEnum(cur.*);
            cur.* = @enumFromInt(if (delta < 0) (i + n - 1) % n else (i + 1) % n);
            st.routes_touched[st.ai_row] = true;
        },
        .keyboard, .claude_codex, .vscode_shim => {},
    }
}

/// A yes/no on a section: `yes` is icons / vim / ghost-text on.
fn answer(app: *App, section: wizard.Section, yes: bool) void {
    const st = &app.overlay.wizard;
    app.needs_render = true;
    switch (section) {
        .nerd_font => st.nerd_font_icons = yes,
        .input_style => {
            st.input_style = if (yes) .vim else .standard;
            st.input_touched = true;
        },
        .ai_ghost_text => {
            st.ghost_text = yes;
            st.ghost_touched = true;
        },
        .keyboard, .claude_codex, .ai_routing, .vscode_shim => {},
    }
}

/// Esc: close, persist nothing, say so.
fn later(app: *App) void {
    app.overlay.deinit(app.gpa);
    app.focus = if (app.active) |a| .{ .pane = a } else .tree;
    app.toast("Setup skipped — asked again next launch; `first_launch.show` reopens it now.", .{});
    app.needs_render = true;
}

/// Enter: apply the touched answers, write them home, mark it done.
fn finish(app: *App) Allocator.Error!void {
    const st = app.overlay.wizard;
    app.overlay.deinit(app.gpa);
    app.focus = if (app.active) |a| .{ .pane = a } else .tree;
    var writes: usize = 0;
    if (st.nerd_font_icons) |icons| {
        app.cfg.ui.ascii_icons = !icons;
        if (try settings.persist(app, .home, &.{ "ui", "ascii_icons" }, !icons)) writes += 1;
    }
    if (st.input_touched) {
        if (st.input_style != app.input_style) try app.setInputStyle(st.input_style);
        if (try settings.persist(app, .home, &.{ "editor", "input_style" }, App.configStyleOf(st.input_style))) writes += 1;
    }
    if (st.routes_touched[0]) {
        app.cfg.ai.routing.claude.backend = backendOf(st.route_claude);
        if (try settings.persist(app, .home, &.{ "ai", "routing", "claude", "backend" }, backendOf(st.route_claude))) writes += 1;
    }
    if (st.routes_touched[1]) {
        app.cfg.ai.routing.codex.backend = backendOf(st.route_codex);
        if (try settings.persist(app, .home, &.{ "ai", "routing", "codex", "backend" }, backendOf(st.route_codex))) writes += 1;
    }
    if (st.ghost_touched) {
        app.cfg.ai.inline_suggestions = st.ghost_text;
        if (try settings.persist(app, .home, &.{ "ai", "inline_suggestions" }, st.ghost_text)) writes += 1;
    }
    app.cfg.ui.first_launch_complete = true;
    if (try settings.persist(app, .home, &.{ "ui", "first_launch_complete" }, true)) writes += 1;
    app.toast("Setup saved ({d} setting(s)). Reopen anytime with `first_launch.show`.", .{writes});
    app.needs_render = true;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const command = @import("../core/command.zig");

test "Esc persists nothing and the wizard reopens; Enter writes the touched answers and first_launch_complete" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 120, .rows = 40 });
    defer app.deinit();
    try t.expect(!app.cfg.ui.first_launch_complete);

    try command.run(&app, .{ .static = .@"first_launch.show" });
    try t.expect(app.overlay == .wizard);
    // y answers Nerd Font; ↓↓ → cycles input style to vim; ↓↓ tab → routes Codex to Sub
    try app.handle(.{ .key = Key.char('y') });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.right) });
    try t.expectEqual(input.Style.vim, app.overlay.wizard.input_style);
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.tab) });
    try app.handle(.{ .key = Key.named(.right) });
    try t.expect(app.overlay.wizard.route_codex == .sub);
    // a listed chord ticks the keyboard row from anywhere
    try app.handle(.{ .key = .{ .code = .right, .mods = .{ .ctrl = true } } });
    try t.expect(app.overlay.wizard.keys_seen[0]);
    // Esc: nothing on disk, nothing applied, still pending
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.overlay == .none);
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "config.zon", .{}));
    try t.expectEqual(input.Style.standard, app.input_style);
    try t.expect(!app.cfg.ui.first_launch_complete);
    try showIfPending(&app);
    try t.expect(app.overlay == .wizard);

    // Enter with only the input row touched: that and the gate persist.
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.right) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try t.expect(app.cfg.ui.first_launch_complete);
    try t.expectEqual(input.Style.vim, app.input_style);
    const text = try tmp.dir.readFileAlloc(t.io, "config.zon", t.allocator, .unlimited);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".first_launch_complete = true") != null);
    try t.expect(std.mem.indexOf(u8, text, ".input_style = .vim") != null);
    try t.expect(std.mem.indexOf(u8, text, "ascii_icons") == null);
    try t.expect(std.mem.indexOf(u8, text, "routing") == null);
    try showIfPending(&app);
    try t.expect(app.overlay == .none); // done means done
}

test "the wizard renders its sections on the 120x40 screen and walks them" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"first_launch.show" });
    const screen_mod = @import("../ipc/screen.zig");
    try app.render();
    const first = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(first);
    try t.expect(std.mem.indexOf(u8, first, "First-launch setup") != null);
    try t.expect(std.mem.indexOf(u8, first, "Render as icons") != null);
    try t.expect(std.mem.indexOf(u8, first, "Ctrl+") != null);
    try t.expect(std.mem.indexOf(u8, first, "Option/Alt+") != null);
    try t.expect(std.mem.indexOf(u8, first, "Input style") != null);
    try t.expect(std.mem.indexOf(u8, first, "AI billing preference") != null);
    try t.expect(std.mem.indexOf(u8, first, "Sub") != null);
    // clicking the input-style vim chip answers it
    var vim_hit: ?@import("../ui/rect.zig") = null;
    for (app.hits.items.items) |h| if (h.target == .overlay_item) if (wizard.decodeHit(h.target.overlay_item)) |hit| if (hit == .chip and hit.chip.section == .input_style and hit.chip.choice == 1) {
        vim_hit = h.rect;
    };
    try app.handle(.{ .mouse = .{ .x = vim_hit.?.x + 2, .y = vim_hit.?.y, .kind = .press, .button = .left } });
    try t.expect(app.overlay == .wizard);
    try t.expectEqual(input.Style.vim, app.overlay.wizard.input_style);
    try t.expect(app.overlay.wizard.ui.section == .input_style);
}
