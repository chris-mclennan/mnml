//! Baking a user's own SVG into mnml's face — the half the two
//! replaceable marks share.
//!
//! Two of mnml's own glyphs are the user's to replace: the terminal
//! mark at `U+F2000` (`ui.terminal_glyph = .custom`, with the path in
//! `ui.terminal_glyph_svg`) and the Claude Code mark at `U+F1E00`
//! (`ui.claude_mark = .custom`, `ui.claude_mark_svg`). Everything about
//! the two is the same but the words and the keys: a prompt for a path,
//! the whole face rebuilt with that art in one slot, written to
//! `<data root>/fonts/MnmlSymbols.ttf`, and a toast offering the
//! restart a rasteriser needs to notice. So the flow lives here once
//! and `app/terminal_glyph.zig` / `app/claude_mark.zig` each hand it a
//! `Slot`.
//!
//! The face is the WHOLE face, not a patch — the other product marks
//! and the connectors come with it. Which means a bake of one slot has
//! to carry the other slot's art too, or setting a custom Claude mark
//! would quietly undo a custom terminal mark baked last week. So
//! `sources` reads the other key's SVG back off disk; a path that has
//! since moved falls back to the shipped drawing and says so, rather
//! than failing a bake that is about the other mark entirely.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const Config = @import("../config/Config.zig");
const Prompt = @import("../ui/prompt.zig");
const builder = @import("../glyph/builder.zig");
const settings = @import("settings.zig");

/// Which mark is being replaced.
pub const Slot = enum {
    claude,
    terminal,

    /// The word the user sees for this mark, which opens every message.
    /// Capitalised for Claude's because *Claude* is a name; the
    /// terminal's is a common noun and its toasts have always been
    /// lower case.
    pub fn noun(s: Slot) []const u8 {
        return switch (s) {
            .claude => "Claude icon",
            .terminal => "terminal icon",
        };
    }

    /// The prompt's title.
    pub fn title(s: Slot) []const u8 {
        return switch (s) {
            .claude => "Claude icon: path to an SVG",
            .terminal => "Terminal icon: path to an SVG",
        };
    }

    fn purpose(s: Slot) app_mod.PromptPurpose {
        return switch (s) {
            .claude => .claude_mark_svg,
            .terminal => .terminal_glyph_svg,
        };
    }

    /// The SVG path this slot's config holds, empty when it has none.
    pub fn svgPath(s: Slot, app: *const App) []const u8 {
        return switch (s) {
            .claude => app.cfg.ui.claude_mark_svg,
            .terminal => app.cfg.ui.terminal_glyph_svg,
        };
    }

    /// Is this slot on `.custom` right now?
    fn isCustom(s: Slot, app: *const App) bool {
        return switch (s) {
            .claude => app.cfg.ui.claude_mark == .custom,
            .terminal => app.cfg.ui.terminal_glyph == .custom,
        };
    }
};

/// `<data root>/fonts/MnmlSymbols.ttf` — where a custom bake lands.
pub fn userFontPath(app: *const App, arena: Allocator) Allocator.Error![]const u8 {
    return std.fs.path.join(arena, &.{ app.data_root, builder.user_dir, builder.file_name });
}

/// Open the prompt for `slot`, seeded with the SVG already in use so a
/// re-bake after an edit is Enter.
pub fn openPrompt(app: *App, slot: Slot) CommandError!void {
    app.overlay.deinit(app.gpa);
    var state = Prompt.init(app.gpa, slot.title());
    const seed = slot.svgPath(app);
    if (seed.len > 0) try state.setText(app.gpa, seed);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = slot.purpose() } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// `raw` as a path mnml can read: `~` expanded, a relative one taken
/// against the workspace.
fn resolve(app: *App, arena: Allocator, raw: []const u8) CommandError![]const u8 {
    const expanded = try app.expandTilde(raw);
    return if (std.fs.path.isAbsolute(expanded)) expanded else std.fs.path.join(arena, &.{ app.workspace, expanded });
}

/// The art this bake should carry in BOTH slots: `replacement` in
/// `slot`, and whatever the other slot's config points at — its shipped
/// drawing when it has none, or when the file it names has gone.
fn sources(app: *App, arena: Allocator, slot: Slot, replacement: []const u8) CommandError!builder.Sources {
    var src: builder.Sources = .{};
    switch (slot) {
        .claude => src.claude = replacement,
        .terminal => src.terminal = replacement,
    }
    const other: Slot = switch (slot) {
        .claude => .terminal,
        .terminal => .claude,
    };
    if (!other.isCustom(app)) return src;
    const path = other.svgPath(app);
    if (path.len == 0) return src;
    const kept = Io.Dir.cwd().readFileAlloc(app.io, try resolve(app, arena, path), arena, .limited(builder.max_svg_bytes)) catch {
        app.toast("{s}: {s} is gone — that mark went back to the shipped art", .{ other.noun(), path });
        return src;
    };
    switch (other) {
        .claude => src.claude = kept,
        .terminal => src.terminal = kept,
    }
    return src;
}

/// Write `slot`'s two keys: `.custom`, and the path behind it.
fn persist(app: *App, slot: Slot, path: []const u8) CommandError!void {
    // The config's strings live on the loader's arena, not the gpa
    // (`App.loaded` owns it). With no loaded config there is nowhere to
    // put it — the file below still has it, and the next start reads it
    // back.
    const held: ?[]const u8 = if (app.loaded) |*l| try l.allocator().dupe(u8, path) else null;
    switch (slot) {
        .claude => {
            if (held) |h| app.cfg.ui.claude_mark_svg = h;
            app.cfg.ui.claude_mark = .custom;
            _ = try settings.persist(app, .home, &.{ "ui", "claude_mark_svg" }, path);
            _ = try settings.persist(app, .home, &.{ "ui", "claude_mark" }, Config.ClaudeMark.custom);
        },
        .terminal => {
            if (held) |h| app.cfg.ui.terminal_glyph_svg = h;
            app.cfg.ui.terminal_glyph = .custom;
            _ = try settings.persist(app, .home, &.{ "ui", "terminal_glyph_svg" }, path);
            _ = try settings.persist(app, .home, &.{ "ui", "terminal_glyph" }, Config.TerminalGlyph.custom);
        },
    }
}

/// The prompt's Enter for either slot: read `text`'s SVG, bake the
/// whole face with it, write it into the data root, set the two keys
/// and offer the restart.
pub fn accept(app: *App, slot: Slot, text: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const noun = slot.noun();
    const raw = std.mem.trim(u8, text, " \t\r\n");
    if (raw.len == 0) return app.diag.fail(arena, "{s}: no path given", .{noun});
    const path = try resolve(app, arena, raw);
    const source = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(builder.max_svg_bytes)) catch |err|
        return app.diag.fail(arena, "{s}: {s}: {s}", .{ noun, path, @errorName(err) });
    const bytes = builder.buildWith(arena, try sources(app, arena, slot, source)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The reader's own words: an SVG with no viewBox, no filled
        // shape, or a transform that would mis-place it.
        else => return app.diag.fail(arena, "{s}: {s} is not a glyph mnml can bake ({s})", .{ noun, path, @errorName(err) }),
    };
    const out = try userFontPath(app, arena);
    Io.Dir.cwd().createDirPath(app.io, std.fs.path.dirname(out).?) catch {};
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = out, .data = bytes }) catch |err|
        return app.diag.fail(arena, "{s}: could not write {s}: {s}", .{ noun, out, @errorName(err) });
    try persist(app, slot, path);
    app.needs_render = true;

    const action: app_mod.ToastAction = .{ .restart = .{ .label = try app.gpa.dupe(u8, "Restart") } };
    errdefer action.deinit(app.gpa);
    try app.toastWithAction(.info, action, "baked {s} — install it and restart the terminal to load the new face", .{out});
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const config_load = @import("../config/load.zig");
const ttf = @import("../glyph/ttf.zig");

/// An app WITH a loaded config, as `main.zig` always builds one: the
/// path a bake persists is held on the loader's arena, and `sources`
/// reads it back from there when the OTHER slot bakes. A fixture with
/// no loader (`App.initWith` alone, as the two icon files' own tests
/// use) would write the key to disk and then not find it in memory,
/// which is not a state the running app is ever in. `MNML_DATA_ROOT`
/// points the home config at the scratch dir, so nothing reaches
/// `~/.config`.
const Fx = struct {
    tmp: std.testing.TmpDir,
    app: App,
    root: []const u8,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    vars: std.process.Environ.Map,

    fn init(fx: *Fx) !void {
        fx.tmp = t.tmpDir(.{});
        errdefer fx.tmp.cleanup();
        const n = try fx.tmp.dir.realPath(t.io, &fx.buf);
        fx.root = fx.buf[0..n];
        fx.vars = std.process.Environ.Map.init(t.allocator);
        errdefer fx.vars.deinit();
        try fx.vars.put("MNML_DATA_ROOT", fx.root);
        var loaded = try config_load.load(t.allocator, t.io, .{ .workspace = fx.root, .env = .{ .vars = &fx.vars } });
        errdefer loaded.deinit();
        fx.app = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = fx.root, .data_root = fx.root, .cols = 100, .rows = 40 });
    }

    fn deinit(fx: *Fx) void {
        fx.app.deinit();
        fx.vars.deinit();
        fx.tmp.cleanup();
    }
};

/// A square, as a one-path SVG: art that is neither mark's, so a
/// codepoint carrying it can be told from a codepoint that did not
/// change.
const square = "<svg viewBox=\"0 0 10 10\"><path d=\"M1 1 L9 1 L9 9 L1 9 Z\"/></svg>";
/// A triangle — the same for the second slot, and different from the
/// square.
const triangle = "<svg viewBox=\"0 0 10 10\"><path d=\"M1 1 L9 1 L5 9 Z\"/></svg>";

/// How many contours the built face gives `cp` — 1 for either shape
/// above, 3 for the Claude figure (a body and two eye holes). The
/// ghost's is read off the shipped face (`shippedContours`) rather than
/// written here: the number is the drawing's, not this file's.
fn contourCount(arena: Allocator, bytes: []const u8, cp: u21) !usize {
    for (try ttf.read(arena, bytes)) |g| if (g.codepoint == cp) return g.contours.len;
    return error.NotInFace;
}

/// `cp`'s contour count in the face as it ships.
fn shippedContours(arena: Allocator, cp: u21) !usize {
    return contourCount(arena, try builder.buildDefault(arena), cp);
}

test "baking one slot keeps the other slot's custom art — the whole face is rewritten, so it has to carry both" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "term.svg", .data = square });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "claude.svg", .data = triangle });
    try accept(app, .terminal, "term.svg");
    try accept(app, .claude, "claude.svg");
    try t.expectEqual(Config.TerminalGlyph.custom, app.cfg.ui.terminal_glyph);
    try t.expectEqual(Config.ClaudeMark.custom, app.cfg.ui.claude_mark);

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try userFontPath(app, arena);
    const face = try Io.Dir.cwd().readFileAlloc(app.io, out, arena, .unlimited);
    // The bug this is for: the second bake rebuilding the face from the
    // shipped sources would put the ghost back at U+F2000 and nobody
    // would notice until they looked at a shell tab.
    try t.expectEqual(@as(usize, 1), try contourCount(arena, face, builder.terminal));
    try t.expectEqual(@as(usize, 1), try contourCount(arena, face, builder.claude));
    // And the marks that are NOT slots are still the shipped drawings.
    try t.expectEqual(try shippedContours(arena, builder.claude_spark), try contourCount(arena, face, builder.claude_spark));
    try t.expectEqual(try shippedContours(arena, builder.codex), try contourCount(arena, face, builder.codex));
}

test "a slot whose SVG has gone falls back to the shipped art and says so, rather than failing the other slot's bake" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "term.svg", .data = square });
    try accept(app, .terminal, "term.svg");
    try fx.tmp.dir.deleteFile(t.io, "term.svg");
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "claude.svg", .data = triangle });
    try accept(app, .claude, "claude.svg");

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const face = try Io.Dir.cwd().readFileAlloc(app.io, try userFontPath(app, arena), arena, .unlimited);
    // The bake it was asked for landed…
    try t.expectEqual(@as(usize, 1), try contourCount(arena, face, builder.claude));
    // …and the slot it could not read is the ghost again, with a toast
    // naming it rather than a silent swap. (The square it replaced is
    // one contour; the ghost is more than one, whatever its exact
    // count.)
    const ghost = try shippedContours(arena, builder.terminal);
    try t.expect(ghost > 1);
    try t.expectEqual(ghost, try contourCount(arena, face, builder.terminal));
    var said = false;
    for (app.toasts.items) |toast| said = said or std.mem.indexOf(u8, toast.text, "went back to the shipped art") != null;
    try t.expect(said);
}
