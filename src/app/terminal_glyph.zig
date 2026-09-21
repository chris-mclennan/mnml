//! Which mark a terminal wears in mnml's chrome, and the one command
//! that bakes a new one.
//!
//! *Mark* is the word this file uses for the thing; the word the USER
//! sees is **icon** — the chips' `Icon ▸` submenu, the `terminal icon:
//! …` toast, Settings → UI's *Terminal icon* row. The config key stays
//! `ui.terminal_glyph` so a config already on disk keeps working.
//!
//! `ui.terminal_glyph` has three values:
//!
//!   - `.ghostty` (the default) — Ghostty's ghost, which mnml carries in
//!     its own block at `U+F2000` and bakes into `MnmlSymbols`. It is
//!     the mark whatever terminal mnml is running inside: the icon says
//!     "a terminal", not "this particular emulator".
//!   - `.terminal` — the plain codicon terminal, whatever the emulator.
//!     It replaces a table that gave each emulator a different mark
//!     (a Nerd Font ghost for Ghostty, a cat for kitty, an apple for
//!     Terminal.app): four icons for one idea, none of them the
//!     product's own logo, and which one a user saw depended on where
//!     they launched mnml from.
//!   - `.custom` — the user's own SVG, named by `ui.terminal_glyph_svg`
//!     and baked at the same `U+F2000`. Same codepoint on purpose:
//!     nothing in the chrome and nothing in the terminal's
//!     `font-codepoint-map` has to change when the art does.
//!
//! The custom bake writes `<data root>/fonts/MnmlSymbols.ttf` — the
//! whole face, not a patch, so the Claude and Codex marks and the two
//! tree connectors come with it. Install that file (it is the one the
//! terminal's font list has to find) and restart the terminal: a
//! rasteriser holds a font open for the life of its process.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const Config = @import("../config/Config.zig");
const Prompt = @import("../ui/prompt.zig");
const bufferline = @import("../ui/bufferline.zig");
const builder = @import("../glyph/builder.zig");
const settings = @import("settings.zig");

pub const table = .{
    .@"view.terminal_glyph_ghostty" = &setGhostty,
    .@"view.terminal_glyph_terminal" = &setTerminal,
    .@"view.terminal_glyph_custom" = &openCustomPrompt,
};

/// `<data root>/fonts/MnmlSymbols.ttf` — where a custom bake lands.
pub fn userFontPath(app: *const App, arena: Allocator) Allocator.Error![]const u8 {
    return std.fs.path.join(arena, &.{ app.data_root, builder.user_dir, builder.file_name });
}

/// The mark a terminal wears, per `ui.terminal_glyph`. `.ghostty` and
/// `.custom` are the same string — both are mnml's own `U+F2000`, and
/// which art is behind it is the font's business, not the chrome's.
pub fn mark(app: *const App) bufferline.Terminal {
    const name = @import("pty_pane.zig").hostTerminalName(app);
    const base = bufferline.terminalMark(app.cfg.ui.terminal_glyph);
    // Only the name comes from the environment.
    return .{ .label = name, .glyph = base.glyph, .fallback = base.fallback };
}

/// What an `Icon ▸` menu row calls (`command.MenuAction.set_terminal_mark`):
/// the same write the two commands do, named by the value.
pub fn setMark(app: *App, value: Config.TerminalGlyph) CommandError!void {
    return set(app, value, switch (value) {
        .ghostty => "terminal icon: the Ghostty ghost",
        .terminal => "terminal icon: the codicon terminal",
        .custom => "terminal icon: the baked SVG",
    });
}

/// What a toast and Settings call each value of `ui.terminal_glyph` —
/// the descriptive name, which has to stand on its own with no picture
/// beside it.
pub fn label(value: Config.TerminalGlyph) []const u8 {
    return switch (value) {
        .ghostty => "Ghostty ghost",
        .terminal => "Terminal",
        .custom => "Custom SVG",
    };
}

/// What an `Icon ▸` menu row calls each value. The twin of
/// `claude_mark.rowLabel`, and short for the same reason: the row
/// DRAWS the glyph it picks (`ui/menu_glyph.zig`), so the picture says
/// which mark and the word only has to say whose it is.
pub fn rowLabel(value: Config.TerminalGlyph) []const u8 {
    return switch (value) {
        .ghostty => "Ghostty",
        .terminal => "Terminal",
        .custom => "Custom SVG",
    };
}

// ─── the three commands ─────────────────────────────────────────────────

fn set(app: *App, value: Config.TerminalGlyph, msg: []const u8) CommandError!void {
    app.cfg.ui.terminal_glyph = value;
    _ = try settings.persist(app, .home, &.{ "ui", "terminal_glyph" }, value);
    app.toast("{s}", .{msg});
    app.needs_render = true;
}

fn setGhostty(app: *App) CommandError!void {
    return set(app, .ghostty, "terminal icon: the Ghostty ghost");
}

fn setTerminal(app: *App) CommandError!void {
    return set(app, .terminal, "terminal icon: the codicon terminal");
}

/// `view.terminal_glyph_custom`: the path of an SVG to bake.
fn openCustomPrompt(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    var state = Prompt.init(app.gpa, "Terminal icon: path to an SVG");
    // The SVG already in use is the seed, so a re-bake after an edit is
    // Enter.
    if (app.cfg.ui.terminal_glyph_svg.len > 0) try state.setText(app.gpa, app.cfg.ui.terminal_glyph_svg);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .terminal_glyph_svg } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The prompt's Enter: bake `text` into the user's own MnmlSymbols.
pub fn customAccept(app: *App, text: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const raw = std.mem.trim(u8, text, " \t\r\n");
    if (raw.len == 0) return app.diag.fail(arena, "terminal icon: no path given", .{});
    const expanded = try app.expandTilde(raw);
    const path = if (std.fs.path.isAbsolute(expanded)) expanded else try std.fs.path.join(arena, &.{ app.workspace, expanded });
    const source = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(builder.max_svg_bytes)) catch |err|
        return app.diag.fail(arena, "terminal icon: {s}: {s}", .{ path, @errorName(err) });
    const bytes = builder.buildWithTerminal(arena, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The reader's own words: an SVG with no viewBox, no filled
        // shape, or a transform that would mis-place it.
        else => return app.diag.fail(arena, "terminal icon: {s} is not a glyph mnml can bake ({s})", .{ path, @errorName(err) }),
    };
    const out = try userFontPath(app, arena);
    Io.Dir.cwd().createDirPath(app.io, std.fs.path.dirname(out).?) catch {};
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = out, .data = bytes }) catch |err|
        return app.diag.fail(arena, "terminal icon: could not write {s}: {s}", .{ out, @errorName(err) });

    // The config's strings live on the loader's arena, not the gpa
    // (`App.loaded` owns it). With no loaded config there is nowhere to
    // put it — the file below still has it, and the next start reads it
    // back.
    if (app.loaded) |*l| app.cfg.ui.terminal_glyph_svg = try l.allocator().dupe(u8, path);
    app.cfg.ui.terminal_glyph = .custom;
    _ = try settings.persist(app, .home, &.{ "ui", "terminal_glyph_svg" }, path);
    _ = try settings.persist(app, .home, &.{ "ui", "terminal_glyph" }, Config.TerminalGlyph.custom);
    app.needs_render = true;

    const action: app_mod.ToastAction = .{ .restart = .{ .label = try app.gpa.dupe(u8, "Restart") } };
    errdefer action.deinit(app.gpa);
    try app.toastWithAction(.info, action, "baked {s} — install it and restart the terminal to load the new face", .{out});
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const font_scan = @import("font_scan.zig");

const Fx = struct {
    tmp: std.testing.TmpDir,
    app: App,
    root: []const u8,
    buf: [std.fs.max_path_bytes]u8 = undefined,

    fn init(fx: *Fx) !void {
        fx.tmp = t.tmpDir(.{});
        const n = try fx.tmp.dir.realPath(t.io, &fx.buf);
        fx.root = fx.buf[0..n];
        fx.app = try App.initWith(t.allocator, t.io, .{ .workspace = fx.root, .data_root = fx.root, .cols = 100, .rows = 40 });
    }

    fn deinit(fx: *Fx) void {
        fx.app.deinit();
        fx.tmp.cleanup();
    }
};

test "the terminal mark is mnml's own under every emulator; `.terminal` is the codicon under every emulator too; only the name follows `$TERM_PROGRAM`" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const app = &fx.app;
    try app.env.put("TERM_PROGRAM", "kitty");
    // The shipped default: the ghost, not the cat.
    try t.expectEqual(Config.TerminalGlyph.ghostty, app.cfg.ui.terminal_glyph);
    try t.expectEqualStrings(bufferline.ghost_glyph, mark(app).glyph);
    try t.expectEqualStrings(bufferline.term_ascii, mark(app).fallback);
    // The label still names the emulator — that is the pane's title,
    // not its icon.
    try t.expectEqualStrings("kitty", mark(app).label);
    // `.custom` paints the same codepoint: only the art behind it moved.
    app.cfg.ui.terminal_glyph = .custom;
    try t.expectEqualStrings(bufferline.ghost_glyph, mark(app).glyph);
    // `.terminal` is the codicon — the same one under every emulator,
    // so nobody's icon depends on where they launched mnml from.
    app.cfg.ui.terminal_glyph = .terminal;
    try t.expectEqualStrings(bufferline.term_glyph, mark(app).glyph);
    try app.env.put("TERM_PROGRAM", "Apple_Terminal");
    try t.expectEqualStrings(bufferline.term_glyph, mark(app).glyph);
    try t.expectEqualStrings("Terminal", mark(app).label);
}

test "the two set commands write the key to the home config and toast which mark is on" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const app = &fx.app;
    try command.run(app, .{ .static = .@"view.terminal_glyph_terminal" });
    try t.expectEqual(Config.TerminalGlyph.terminal, app.cfg.ui.terminal_glyph);
    try t.expectEqualStrings("terminal icon: the codicon terminal", app.lastToast().?);
    try command.run(app, .{ .static = .@"view.terminal_glyph_ghostty" });
    try t.expectEqual(Config.TerminalGlyph.ghostty, app.cfg.ui.terminal_glyph);
    const home = try std.fs.path.join(app.frame.allocator(), &.{ fx.root, "config.zon" });
    const text = try Io.Dir.cwd().readFileAlloc(app.io, home, app.frame.allocator(), .limited(64 * 1024));
    try t.expect(std.mem.indexOf(u8, text, ".terminal_glyph = .ghostty") != null);
}

test "a custom SVG bakes the whole face into the data root, sets both keys, and offers the restart" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "mark.svg", .data = "<svg viewBox=\"0 0 10 10\"><path d=\"M1 1 L9 1 L9 9 L1 9 Z\"/></svg>" });
    try command.run(app, .{ .static = .@"view.terminal_glyph_custom" });
    try t.expect(app.overlay == .prompt);
    try customAccept(app, "mark.svg");
    try t.expectEqual(Config.TerminalGlyph.custom, app.cfg.ui.terminal_glyph);
    // The key reached the config file; the in-memory copy follows only
    // when there is a loader arena to hold it.
    const home = try std.fs.path.join(app.frame.allocator(), &.{ fx.root, "config.zon" });
    const conf = try Io.Dir.cwd().readFileAlloc(app.io, home, app.frame.allocator(), .limited(64 * 1024));
    try t.expect(std.mem.indexOf(u8, conf, "mark.svg") != null);
    try t.expect(std.mem.indexOf(u8, conf, ".terminal_glyph = .custom") != null);
    const out = try userFontPath(app, app.frame.allocator());
    // The face, not a patch: the marks that are not the terminal's came
    // with it.
    var cps = (try font_scan.cmapCodepoints(t.allocator, app.io, out)).?;
    defer cps.deinit(t.allocator);
    for ([_]u21{ builder.claude, builder.codex, builder.tree_vertical, builder.tree_corner, builder.terminal }) |cp| try t.expect(cps.contains(cp));
    // The toast carries the button.
    try t.expectEqualStrings("Restart", app.toasts.items[app.toasts.items.len - 1].action.?.label());
}

test "a path that is not an SVG fails loudly and changes nothing" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "notes.txt", .data = "not an svg\n" });
    try t.expectError(error.Failed, customAccept(app, "notes.txt"));
    try t.expectEqual(Config.TerminalGlyph.ghostty, app.cfg.ui.terminal_glyph);
    try t.expectError(error.Failed, customAccept(app, "nothing-here.svg"));
    try t.expectError(error.Failed, customAccept(app, "   "));
}
