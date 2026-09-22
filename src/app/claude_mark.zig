//! Which mark Claude Code wears in mnml's chrome.
//!
//! *Mark* is the word this file uses for the thing; the word the USER
//! sees is **icon** — the chips' `Icon ▸` submenu, the `Claude icon: …`
//! toast, Settings → UI's *Claude icon* row. The config key stays
//! `ui.claude_mark` so a config already on disk keeps working.
//!
//! `ui.claude_mark` has three values:
//!
//!   - `.figure` (the default) — the Claude Code figure, which mnml
//!     carries in its own block at `U+F1E00` and bakes into
//!     `MnmlSymbols`.
//!   - `.spark` — the Anthropic spark, one codepoint along at
//!     `U+F1E02` (`ui/bufferline.zig`'s `spark_glyph`). The mark Claude
//!     Code wore before the figure; some people want it back.
//!   - `.custom` — the user's own SVG, named by `ui.claude_mark_svg`
//!     and baked at the figure's own `U+F1E00`. Same codepoint on
//!     purpose: nothing in the chrome and nothing in the terminal's
//!     `font-codepoint-map` has to change when the art does. The bake
//!     is `app/mark_bake.zig`, shared with the terminal icon's
//!     `.custom` — the two differ in their words and their keys and in
//!     nothing else.
//!
//! `mark` is the ONE place the choice is read. Every surface that draws
//! the mark — the tab bar's right cluster, a Claude pty tab, the
//! statusline meter, the launcher dock, a SESSIONS card — calls it
//! rather than naming `claude_glyph`, so a change lands on all of them
//! in the same frame. The terminal's twin is `app/terminal_glyph.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Config = @import("../config/Config.zig");
const bufferline = @import("../ui/bufferline.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const mark_bake = @import("mark_bake.zig");
const settings = @import("settings.zig");

pub const table = .{
    .@"view.claude_mark_custom" = &openCustomPrompt,
};

/// The mark, per `ui.claude_mark`.
pub fn mark(app: *const App) bufferline.Mark {
    return bufferline.claudeMark(app.cfg.ui.claude_mark);
}

/// The glyph, or its `--ascii` twin — what a painter with a `ui` wants.
pub fn glyph(app: *const App, ascii: bool) []const u8 {
    const m = mark(app);
    return if (ascii) m.fallback else m.glyph;
}

/// The `Icon ▸` menu rows' action (`command.MenuAction.set_claude_mark`)
/// and the Settings row's write: set the key, persist it, repaint.
pub fn set(app: *App, value: Config.ClaudeMark) Allocator.Error!void {
    app.cfg.ui.claude_mark = value;
    _ = try settings.persist(app, .home, &.{ "ui", "claude_mark" }, value);
    app.toast("Claude icon: {s}", .{label(value)});
    app.needs_render = true;
}

/// What a toast and Settings call each value — the descriptive name,
/// which has to stand on its own with no picture beside it.
pub fn label(value: Config.ClaudeMark) []const u8 {
    return switch (value) {
        .figure => "Claude Code figure",
        .spark => "Anthropic spark",
        .custom => "Custom SVG",
    };
}

/// What an `Icon ▸` menu row calls each value. Shorter than `label`,
/// and deliberately: the row DRAWS the glyph it picks
/// (`ui/menu_glyph.zig`), so the picture says which mark and the word
/// only has to say whose it is.
pub fn rowLabel(value: Config.ClaudeMark) []const u8 {
    return switch (value) {
        .figure => "Claude Code",
        .spark => "Anthropic",
        .custom => "Custom SVG",
    };
}

// ─── the custom bake ────────────────────────────────────────────────────

/// `view.claude_mark_custom`: the path of an SVG to bake at `U+F1E00`.
fn openCustomPrompt(app: *App) CommandError!void {
    return mark_bake.openPrompt(app, .claude);
}

/// The prompt's Enter: bake `text` into the user's own MnmlSymbols.
pub fn customAccept(app: *App, text: []const u8) CommandError!void {
    return mark_bake.accept(app, .claude, text);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

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

test "the shipped mark is the figure; `.spark` resolves to the spark codepoint, and each keeps its own ascii twin" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const app = &fx.app;
    try t.expectEqual(Config.ClaudeMark.figure, app.cfg.ui.claude_mark);
    try t.expectEqualStrings(bufferline.claude_glyph, mark(app).glyph);
    try t.expectEqualStrings(bufferline.claude_ascii, mark(app).fallback);
    try t.expectEqualStrings(bufferline.claude_glyph, glyph(app, false));
    try t.expectEqualStrings(bufferline.claude_ascii, glyph(app, true));
    app.cfg.ui.claude_mark = .spark;
    try t.expectEqualStrings(bufferline.spark_glyph, mark(app).glyph);
    try t.expectEqualStrings(bufferline.spark_ascii, mark(app).fallback);
    try t.expectEqualStrings(bufferline.spark_glyph, glyph(app, false));
    try t.expectEqualStrings(bufferline.spark_ascii, glyph(app, true));
    // Two marks, told apart with a Nerd Font and without one.
    try t.expect(!std.mem.eql(u8, bufferline.claude_glyph, bufferline.spark_glyph));
    try t.expect(!std.mem.eql(u8, bufferline.claude_ascii, bufferline.spark_ascii));
    // The spark sits one along from the figure, where the glyph
    // builder bakes it. Two sides, two greps: the chrome's copy of the
    // number and the font's own must be the SAME number, or the mark
    // the menu offers renders as tofu.
    try t.expectEqual(@as(u21, 0xF1E02), bufferline.spark_cp);
    try t.expectEqual(bufferline.spark_cp, try std.unicode.utf8Decode(bufferline.spark_glyph));
    try t.expectEqual(@import("../glyph/builder.zig").claude_spark, bufferline.spark_cp);
}

test "set writes the key to the home config and says which mark is on" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const app = &fx.app;
    try set(app, .spark);
    try t.expectEqual(Config.ClaudeMark.spark, app.cfg.ui.claude_mark);
    try t.expectEqualStrings("Claude icon: Anthropic spark", app.lastToast().?);
    const home = try std.fs.path.join(app.frame.allocator(), &.{ fx.root, "config.zon" });
    const text = try std.Io.Dir.cwd().readFileAlloc(app.io, home, app.frame.allocator(), .limited(64 * 1024));
    try t.expect(std.mem.indexOf(u8, text, ".claude_mark = .spark") != null);
    try set(app, .figure);
    try t.expectEqualStrings("Claude icon: Claude Code figure", app.lastToast().?);
}

test "a custom SVG bakes the whole face into the data root, sets both keys, and offers the restart" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "mine.svg", .data = "<svg viewBox=\"0 0 10 10\"><path d=\"M1 1 L9 1 L9 9 L1 9 Z\"/></svg>" });
    try command.run(app, .{ .static = .@"view.claude_mark_custom" });
    try t.expect(app.overlay == .prompt);
    try t.expectEqual(app_mod.PromptPurpose.claude_mark_svg, app.overlay.prompt.purpose);
    try customAccept(app, "mine.svg");
    try t.expectEqual(Config.ClaudeMark.custom, app.cfg.ui.claude_mark);
    // `.custom` paints the figure's own codepoint: only the art moved,
    // so nothing in the chrome or in ghostty's codepoint map changes.
    try t.expectEqualStrings(bufferline.claude_glyph, mark(app).glyph);
    // Both keys reached the config file; the in-memory copy follows
    // only when there is a loader arena to hold it.
    const home = try std.fs.path.join(app.frame.allocator(), &.{ fx.root, "config.zon" });
    const conf = try std.Io.Dir.cwd().readFileAlloc(app.io, home, app.frame.allocator(), .limited(64 * 1024));
    try t.expect(std.mem.indexOf(u8, conf, "mine.svg") != null);
    try t.expect(std.mem.indexOf(u8, conf, ".claude_mark = .custom") != null);
    // The face, not a patch: the marks that are not Claude's came with
    // it, and the figure's codepoint is in the cmap rather than missing
    // because the bake replaced the spec rather than the art.
    const out = try mark_bake.userFontPath(app, app.frame.allocator());
    const builder = @import("../glyph/builder.zig");
    var cps = (try @import("font_scan.zig").cmapCodepoints(t.allocator, app.io, out)).?;
    defer cps.deinit(t.allocator);
    for ([_]u21{ builder.claude, builder.claude_spark, builder.codex, builder.terminal, builder.tree_vertical, builder.tree_corner }) |cp| {
        errdefer std.debug.print("missing U+{X}\n", .{cp});
        try t.expect(cps.contains(cp));
    }
    // The toast carries the button — a rasteriser holds a font open for
    // the life of its process, so a bake is only visible after one.
    try t.expectEqualStrings("Restart", app.toasts.items[app.toasts.items.len - 1].action.?.label());
}

test "a path that is not an SVG fails loudly and leaves the mark alone" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "notes.txt", .data = "not an svg\n" });
    try t.expectError(error.Failed, customAccept(app, "notes.txt"));
    try t.expectEqual(Config.ClaudeMark.figure, app.cfg.ui.claude_mark);
    try t.expectError(error.Failed, customAccept(app, "nothing-here.svg"));
    try t.expectError(error.Failed, customAccept(app, "   "));
    try t.expectEqual(Config.ClaudeMark.figure, app.cfg.ui.claude_mark);
}

test "the mark survives a restart: the loader reads the persisted key back off the home config" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try set(&fx.app, .spark);
    // The bug this is for: a key written and never READ looks right
    // until the next launch. `config.load` on the same data root is
    // that launch — the path `main.zig` takes.
    var vars = std.process.Environ.Map.init(t.allocator);
    defer vars.deinit();
    try vars.put("MNML_DATA_ROOT", fx.root);
    const config_load = @import("../config/load.zig");
    var loaded = try config_load.load(t.allocator, t.io, .{ .workspace = fx.root, .env = .{ .vars = &vars }, .trust = .trusted });
    defer loaded.deinit();
    try t.expectEqual(@as(usize, 0), loaded.diagnostics.count());
    try t.expectEqual(Config.ClaudeMark.spark, loaded.config.ui.claude_mark);
    var again = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .workspace = fx.root, .data_root = fx.root, .cols = 100, .rows = 40 });
    defer again.deinit();
    try t.expectEqualStrings(bufferline.spark_glyph, mark(&again).glyph);
}

/// The surfaces that draw the Claude mark. Each must take it from the
/// resolver: a painter that names the codepoint keeps the old mark
/// after the menu changes it, and nothing but clicking would find it.
/// `ui/bufferline.zig` is the one file that spells a codepoint, and
/// the registry defaults that need the shipped figure by value borrow
/// it from there (`config/Config.zig`, `app/integrations.zig`) rather
/// than write it again.
const painters = [_]struct { name: []const u8, src: []const u8, resolves: bool }{
    .{ .name = "app/render.zig", .src = @embedFile("render.zig"), .resolves = true },
    .{ .name = "app/statusline.zig", .src = @embedFile("statusline.zig"), .resolves = true },
    .{ .name = "app/integrations.zig", .src = @embedFile("integrations.zig"), .resolves = true },
    .{ .name = "app/sessions_table.zig", .src = @embedFile("sessions_table.zig"), .resolves = true },
    .{ .name = "ui/sessions_table_view.zig", .src = @embedFile("../ui/sessions_table_view.zig"), .resolves = true },
    // Draws the dock's items from `integrations.allChips`, which has
    // already resolved the mark — so no codepoint of its own either.
    .{ .name = "app/launcher_dock.zig", .src = @embedFile("launcher_dock.zig"), .resolves = false },
};

test "every surface that draws the Claude mark takes it from the resolver, and none names a mark codepoint itself" {
    // The needles are BUILT, not written: a `\u{…}` escape spelled out
    // here would be a glyph site of its own to `zig build glyph-audit`
    // (and one with no `--ascii` twin), and it could drift from the
    // constants besides. These decode the real ones.
    for ([_][]const u8{ bufferline.claude_glyph, bufferline.spark_glyph }) |g| {
        var buf: [16]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buf, "\\u{{{X}}}", .{try std.unicode.utf8Decode(g)});
        for (painters) |p| if (std.mem.indexOf(u8, p.src, needle) != null) {
            std.debug.print("{s} names the mark codepoint `{s}` — paint `claude_mark.mark(app)` instead\n", .{ p.name, needle });
            return error.TestUnexpectedResult;
        };
    }
    for (painters) |p| {
        if (p.resolves and std.mem.indexOf(u8, p.src, "claude_mark") == null) {
            std.debug.print("{s} is listed as a Claude-mark painter but never calls the resolver\n", .{p.name});
            return error.TestUnexpectedResult;
        }
    }
}
