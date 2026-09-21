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
//!
//! Space is the install key: a Nerd Font once "boxes" is answered, the
//! missing AI CLIs, the `code` shim (`first_launch_install.zig`). Each
//! opens a pane, closes the wizard for it without persisting anything,
//! and the wizard comes back on the pane's exit with the section's
//! detection re-run.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Key = app_mod.Key;
const config = @import("../config/root.zig");
const Config = config.Config;
const input = @import("../input/mod.zig");
const wizard = @import("../ui/wizard.zig");
const settings = @import("settings.zig");
const install = @import("first_launch_install.zig");
const key_doctor = @import("key_doctor.zig");
const setup = @import("setup.zig");

pub const Section = wizard.Section;

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
    code_shim_ok: bool = false,
    /// What Space did on the Keyboard section, for the row under it.
    kb_note: [note_cap]u8 = undefined,
    kb_note_len: u8 = 0,

    pub const note_cap = 200;

    pub fn keyboardNote(st: *const State) []const u8 {
        return st.kb_note[0..st.kb_note_len];
    }
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

/// The PATH probes behind the badge rows — the same `onPath` the chip
/// reads, so a row says "installed" exactly when the chip appears.
fn detect(app: *App, st: *State) void {
    st.claude_installed = install.claudeInstalled(app);
    st.codex_installed = install.codexInstalled(app);
    st.code_shim_ok = install.codeShimInstalled(app);
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
    };
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .wizard = st };
    detect(app, &app.overlay.wizard);
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
    const macos_note = "macOS 26: use this — dragging the .ttf into Font Book looks like it works,\nbut CoreText silently skips unsigned Nerd Fonts. The cask registers.";
    return .{
        .code_shim_ok = st.code_shim_ok,
        .keyboard_note = st.keyboardNote(),
        .nerd_install = install.nerdFontSummary(install.host_os),
        .nerd_note = if (install.host_os == .macos) macos_note else "",
        .code_shim_note = switch (install.host_os) {
            .macos => "Space links VS Code.app's `code` into /usr/local/bin (sudo asks in a pane).",
            else => "Not macOS: install `code` from VS Code itself\n(Shell Command: Install 'code' command in PATH).",
        },
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
        .action => try action(app, st.ui.section),
    }
    app.needs_render = true;
}

/// Space: the section's install where it has one, else the same as →.
fn action(app: *App, section: wizard.Section) Allocator.Error!void {
    const st = &app.overlay.wizard;
    switch (section) {
        // "boxes" first, then the install — the row Space fires is
        // the one that appears under that answer.
        .nerd_font => if (st.nerd_font_icons == false) try toastOnFail(app, install.installNerdFont(app)) else answer(app, section, false),
        .claude_codex => try toastOnFail(app, install.installAiClis(app)),
        .vscode_shim => try toastOnFail(app, install.installCodeShim(app)),
        .keyboard => try applyKeyboardFix(app),
        .input_style, .ai_routing, .ai_ghost_text => adjust(app, section, 1),
    }
}

/// Space on the Keyboard section: the one fix mnml applies itself —
/// `macos-option-as-alt = true` in ghostty's config when an Option/Alt
/// chord has not ticked (`key_doctor`) — with what happened as the note
/// under the row and a toast. Any other terminal gets its steps as a
/// toast; nothing is written. An Option chord that already arrived
/// means nothing to fix, and says so.
fn applyKeyboardFix(app: *App) Allocator.Error!void {
    const st = &app.overlay.wizard;
    const term = key_doctor.detectTerminal(&app.env);
    const macos = key_doctor.host_is_macos;
    const alt_seen = st.keys_seen[2] or st.keys_seen[3];
    var applied: ?key_doctor.Applied = null;
    if (!alt_seen and key_doctor.remedy(.alt_right, term, macos).fix == .ghostty_option_as_alt) {
        const arena = app.frame.allocator();
        if (try key_doctor.ghosttyConfigPath(arena, app.io, &app.env)) |path| {
            // The note names the file as `~/…`: a long home path would
            // otherwise push "Restart ghostty." past the note's cap.
            applied = .{ .path = try setup.tilde(app, arena, path), .outcome = key_doctor.applyGhosttyOptionAsAlt(app.gpa, app.io, path) };
        }
    }
    const note = key_doctor.fixNote(&st.kb_note, alt_seen, term, macos, applied);
    st.kb_note_len = @intCast(note.len);
    if (term == .ghostty or alt_seen) app.toast("{s}", .{note}) else app.toast("{s}", .{key_doctor.remedy(.alt_right, term, macos).text});
    app.needs_render = true;
}

/// A pane that could not open says why; the wizard stays.
fn toastOnFail(app: *App, result: command.CommandError!void) Allocator.Error!void {
    result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => {},
        else => if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("{s}", .{@errorName(err)}),
    };
}

/// A click on a section header focuses it; on an answer chip, answers;
/// on an install row, installs.
pub fn click(app: *App, hit: u32) Allocator.Error!void {
    const st = &app.overlay.wizard;
    switch (wizard.decodeHit(hit) orelse return) {
        .section => |s| st.ui.section = s,
        .chip => |c| {
            st.ui.section = c.section;
            switch (c.section) {
                .ai_routing => st.ai_row = @intCast(c.choice & 1),
                .nerd_font => if (c.choice == 2) try action(app, .nerd_font) else answer(app, c.section, c.choice == 1),
                .claude_codex, .vscode_shim => try action(app, c.section),
                else => answer(app, c.section, c.choice == 1),
            }
        },
    }
    app.needs_render = true;
}

/// An install pane is opening: close without persisting or toasting
/// (the install's own toast follows), keeping the answers for the
/// pane's exit.
pub fn closeForInstall(app: *App) void {
    if (app.overlay != .wizard) return;
    app.wizard_stash = app.overlay.wizard;
    app.overlay.deinit(app.gpa);
    app.focus = if (app.active) |a| .{ .pane = a } else .tree;
    app.needs_render = true;
}

/// An install pane ended: re-run detection into the open wizard, or
/// bring it back — with the answers it closed on — focused on
/// `section`, when nothing else is up.
pub fn refresh(app: *App, section: wizard.Section) void {
    if (app.overlay == .wizard) {
        detect(app, &app.overlay.wizard);
    } else if (app.overlay == .none) {
        const st = app.wizard_stash orelse return;
        app.wizard_stash = null;
        app.overlay = .{ .wizard = st };
        app.focus = .overlay;
        detect(app, &app.overlay.wizard);
    } else return;
    app.overlay.wizard.ui.section = section;
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
const builtin = @import("builtin");
const pty_pane = @import("pty_pane.zig");

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

/// A private PATH with fake tools in it, for the install flows: the
/// pane runs `/bin/sh -c <line>` with the app's env, so a `brew` or
/// `curl` script here is what the line reaches.
const InstallRig = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    env: std.process.Environ.Map,

    fn init() !InstallRig {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &buf);
        const root = try t.allocator.dupe(u8, buf[0..n]);
        errdefer t.allocator.free(root);
        var env = std.process.Environ.Map.init(t.allocator);
        errdefer env.deinit();
        try tmp.dir.createDirPath(t.io, "tools");
        try tmp.dir.createDirPath(t.io, "installed");
        const path = try std.fmt.allocPrint(t.allocator, "{s}/tools:{s}/installed:/bin:/usr/bin", .{ root, root });
        defer t.allocator.free(path);
        try env.put("PATH", path);
        const fake_bin = try std.fmt.allocPrint(t.allocator, "{s}/installed", .{root});
        defer t.allocator.free(fake_bin);
        try env.put("MNML_FAKE_BIN", fake_bin);
        return .{ .tmp = tmp, .root = root, .env = env };
    }

    fn deinit(r: *InstallRig) void {
        r.env.deinit();
        t.allocator.free(r.root);
        r.tmp.cleanup();
    }

    fn tool(r: *InstallRig, name: []const u8, script: []const u8) !void {
        const rel = try std.fmt.allocPrint(t.allocator, "tools/{s}", .{name});
        defer t.allocator.free(rel);
        try r.tmp.dir.writeFile(t.io, .{ .sub_path = rel, .data = script });
        const abs = try std.fs.path.join(t.allocator, &.{ r.root, rel });
        defer t.allocator.free(abs);
        const perms: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o755);
        try std.Io.Dir.cwd().setFilePermissions(t.io, abs, perms, .{});
    }

    fn app(r: *InstallRig) !App {
        var a = try App.initWith(t.allocator, t.io, .{ .workspace = r.root, .data_root = r.root, .cols = 120, .rows = 40, .env = &r.env });
        a.tree.visible = false;
        return a;
    }
};

/// The newest pane labelled `label`.
fn installPane(app: *App, label: []const u8) ?*pty_pane.PtyPane {
    var found: ?*pty_pane.PtyPane = null;
    for (app.panes.slots.items) |*slot| if (slot.*) |*pane| if (pane.* == .pty and std.mem.eql(u8, pane.pty.label, label)) {
        found = &pane.pty;
    };
    return found;
}

/// Tick until the newest `label` pane has exited.
fn waitExit(app: *App, label: []const u8) !pty_pane.Exit {
    const pane = installPane(app, label) orelse return error.TestUnexpectedResult;
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 10) {
        try app.tick(App.nowMs(app.io));
        try app.render();
        if (pane.exit) |e| return e;
        app.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

test "Nerd Font: Space on 'boxes' runs the install in a pane; the terminal hint toasts on exit 0 and never before; a failed install says so" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (install.host_os != .macos and install.host_os != .linux) return error.SkipZigTest;
    var rig = try InstallRig.init();
    defer rig.deinit();
    // What this OS's line reaches; `MNML_FAKE_FAIL` makes it fail.
    const script = "#!/bin/sh\nif [ -n \"$MNML_FAKE_FAIL\" ]; then echo 'boom'; exit 3; fi\necho \"fake $0 $*\"\n";
    try rig.tool("brew", script);
    try rig.tool("curl", "#!/bin/sh\nwhile [ $# -gt 0 ]; do if [ \"$1\" = -o ]; then : > \"$2\"; fi; shift; done\n");
    try rig.tool("unzip", script);
    try rig.tool("fc-cache", script);
    try rig.env.put("HOME", rig.root);
    try rig.env.put("TERM_PROGRAM", "ghostty");
    var app = try rig.app();
    defer app.deinit();

    try command.run(&app, .{ .static = .@"first_launch.show" });
    // Space with "icons" still unanswered answers "boxes" first…
    try app.handle(.{ .key = Key.char(' ') });
    try t.expect(app.overlay == .wizard);
    try t.expectEqual(@as(?bool, false), app.overlay.wizard.nerd_font_icons);
    try t.expect(installPane(&app, install.nerd_font_label) == null);
    // …and the next Space installs: the wizard closes for the pane.
    try app.handle(.{ .key = Key.char(' ') });
    try t.expect(app.overlay == .none);
    const pane = installPane(&app, install.nerd_font_label) orelse return error.TestUnexpectedResult;
    try t.expectEqual(pty_pane.Kind.task, pane.kind);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "watch the `install: nerd font` pane") != null);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "JetBrainsMono") == null);
    try t.expect((try waitExit(&app, install.nerd_font_label)).ok());
    // exit 0: the ghostty hint, and the wizard is back on the section
    // with its answers
    var saw_hint = false;
    for (app.toasts.items) |toast| saw_hint = saw_hint or std.mem.indexOf(u8, toast.text, "font-family = JetBrainsMono Nerd Font Mono") != null;
    try t.expect(saw_hint);
    try t.expect(app.overlay == .wizard);
    try t.expect(app.overlay.wizard.ui.section == .nerd_font);
    try t.expectEqual(@as(?bool, false), app.overlay.wizard.nerd_font_icons);
    try t.expect(!app.cfg.ui.first_launch_complete);

    // A failing install: no hint, the failure named.
    try rig.env.put("MNML_FAKE_FAIL", "1");
    app.env.deinit();
    app.env = try rig.env.clone(t.allocator);
    while (app.toasts.items.len > 0) app.dismissToastAt(0);
    try app.handle(.{ .key = Key.char(' ') });
    try t.expect(app.overlay == .none);
    try t.expectEqual(pty_pane.Exit{ .code = 3 }, try waitExit(&app, install.nerd_font_label));
    var saw_fail = false;
    saw_hint = false;
    for (app.toasts.items) |toast| {
        saw_fail = saw_fail or std.mem.indexOf(u8, toast.text, "`install: nerd font` failed (exit 3)") != null;
        saw_hint = saw_hint or std.mem.indexOf(u8, toast.text, "JetBrainsMono") != null;
    }
    try t.expect(saw_fail and !saw_hint);
}

test "Claude / Codex: Space runs the missing CLIs' installers in a pane; the row flips to found when the pane ends; both present is a toast" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (install.host_os != .macos and install.host_os != .linux) return error.SkipZigTest;
    var rig = try InstallRig.init();
    defer rig.deinit();
    // The fake installer script `curl` prints: it drops a `claude` into
    // the PATH dir the rig made for it.
    try rig.tool("curl", "#!/bin/sh\necho 'printf \"#!/bin/sh\\nexit 0\\n\" > \"$MNML_FAKE_BIN/claude\"; chmod +x \"$MNML_FAKE_BIN/claude\"; echo fake-installer-ran'\n");
    var app = try rig.app();
    defer app.deinit();
    try command.run(&app, .{ .static = .@"first_launch.show" });
    try t.expect(!app.overlay.wizard.claude_installed and !app.overlay.wizard.codex_installed);
    try app.handle(.{ .key = Key.char('4') });
    try app.handle(.{ .key = Key.char(' ') });
    try t.expect(app.overlay == .none);
    const pane = installPane(&app, install.ai_cli_label) orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("curl -fsSL https://claude.ai/install.sh | bash && curl -fsSL https://chatgpt.com/codex/install.sh | sh", pane.argv[2]);
    try t.expect((try waitExit(&app, install.ai_cli_label)).ok());
    try t.expect(app.overlay == .wizard);
    try t.expect(app.overlay.wizard.ui.section == .claude_codex);
    try t.expect(app.overlay.wizard.claude_installed);
    try t.expect(!app.overlay.wizard.codex_installed);
    var saw = false;
    for (app.toasts.items) |toast| saw = saw or std.mem.indexOf(u8, toast.text, "Claude Code: found · Codex: not found") != null;
    try t.expect(saw);
    // Only the missing one now.
    try app.handle(.{ .key = Key.char(' ') });
    const second = installPane(&app, install.ai_cli_label).?;
    try t.expect(second != pane);
    try t.expectEqualStrings("curl -fsSL https://chatgpt.com/codex/install.sh | sh", second.argv[2]);
    try t.expect((try waitExit(&app, install.ai_cli_label)).ok());
    // Both present: no pane, a toast.
    try rig.tool("codex", "#!/bin/sh\nexit 0\n");
    try t.expect(app.overlay == .wizard);
    try app.handle(.{ .key = Key.char(' ') });
    try t.expect(app.overlay == .wizard);
    try t.expectEqualStrings("Claude Code + Codex already installed.", app.lastToast().?);
}

test "code shim: on PATH already is a toast, never a pane" {
    var rig = try InstallRig.init();
    defer rig.deinit();
    try rig.tool("code", "#!/bin/sh\nexit 0\n");
    var app = try rig.app();
    defer app.deinit();
    try command.run(&app, .{ .static = .@"first_launch.show" });
    try t.expect(app.overlay.wizard.code_shim_ok);
    try app.handle(.{ .key = Key.char('7') });
    try app.handle(.{ .key = Key.char(' ') });
    try t.expect(app.overlay == .wizard);
    try t.expectEqualStrings("`code` is already on PATH.", app.lastToast().?);
    try t.expect(installPane(&app, install.code_shim_label) == null);
}

test "Space on Keyboard: in ghostty on macOS with no Option chord seen the fix is written under HOME and the row says so; another terminal only gets its steps as a toast; a seen Option chord means nothing to fix" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("TERM_PROGRAM", "iterm.app");
    {
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 120, .rows = 40, .env = &env });
        defer app.deinit();
        try command.run(&app, .{ .static = .@"first_launch.show" });
        try app.handle(.{ .key = Key.named(.down) });
        try t.expect(app.overlay.wizard.ui.section == .keyboard);
        try app.handle(.{ .key = Key.char(' ') });
        // Not ghostty: the steps, nothing on disk, the note says no auto-fix.
        try t.expect(std.mem.indexOf(u8, app.lastToast().?, "Esc+") != null);
        try t.expectError(error.FileNotFound, tmp.dir.access(t.io, ".config/ghostty/config", .{}));
        try t.expect(std.mem.startsWith(u8, app.overlay.wizard.keyboardNote(), "No auto-fix for iTerm2"));
    }
    try env.put("TERM_PROGRAM", "ghostty");
    {
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 120, .rows = 40, .env = &env });
        defer app.deinit();
        try command.run(&app, .{ .static = .@"first_launch.show" });
        try app.handle(.{ .key = Key.named(.down) });
        try app.handle(.{ .key = Key.char(' ') });
        const note = app.overlay.wizard.keyboardNote();
        if (key_doctor.host_is_macos) {
            try t.expect(std.mem.startsWith(u8, note, "Added macos-option-as-alt = true to "));
            try t.expect(std.mem.endsWith(u8, note, "Restart ghostty."));
            // The file is named under `~`, so a long HOME never truncates the note.
            try t.expect(std.mem.indexOf(u8, note, " to ~/.config/ghostty/config ") != null);
            const text = try tmp.dir.readFileAlloc(t.io, ".config/ghostty/config", t.allocator, .limited(65536));
            defer t.allocator.free(text);
            try t.expect(std.mem.endsWith(u8, text, "macos-option-as-alt = true\n"));
            try t.expectEqualStrings(note, app.lastToast().?);
            // The row shows the note.
            try app.render();
            const screen = try @import("../ipc/screen.zig").toTestText(t.allocator, &app.screen);
            defer t.allocator.free(screen);
            try t.expect(std.mem.indexOf(u8, screen, "Added macos-option-as-alt = true") != null);
            // Second press: already set, still nothing more written.
            try app.handle(.{ .key = Key.char(' ') });
            try t.expect(std.mem.indexOf(u8, app.overlay.wizard.keyboardNote(), "already has macos-option-as-alt = true") != null);
        } else {
            try t.expect(std.mem.startsWith(u8, note, "No auto-fix for ghostty"));
        }
        // An Option chord that ticked: nothing to fix.
        try app.handle(.{ .key = .{ .code = .right, .mods = .{ .alt = true } } });
        try t.expect(app.overlay.wizard.keys_seen[2]);
        try app.handle(.{ .key = Key.char(' ') });
        try t.expectEqualStrings("Option+→ already arrives — nothing to fix.", app.overlay.wizard.keyboardNote());
    }
}
