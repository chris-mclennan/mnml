//! The glyph audit and bake as commands — `tools/glyph_audit.zig`'s
//! logic run in-process (the tool is an import of the app), the
//! result in a scratch pane:
//!
//! - `integrations.audit_glyphs` / `menu.glyph_audit`: every Nerd Font
//!   literal under `<workspace>/src` against `<workspace>/data/
//!   nerd-glyphnames.json`, with its `--ascii` twin — the audit `zig
//!   build glyph-audit` runs, for the mnml-zig tree. `menu.glyph_audit`
//!   adds the menu glyph table (`ui/menu_glyph.zig`) first: one row per
//!   command group, glyph, catalog name and ASCII twin.
//! - `integrations.bake_ai_glyphs` / `bake_all_glyphs` /
//!   `bake_integration_glyphs`: the catalog baked into `<data root>/
//!   nerd-glyphs.tsv`. Rust baked SVGs into a font — cut here (docs/
//!   PARITY.md); the three ids do the one bake this build has.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const tool = @import("glyph_audit");
const menu_glyph = @import("../ui/menu_glyph.zig");

pub const table = .{
    .@"integrations.audit_glyphs" = &auditCmd,
    .@"menu.glyph_audit" = &menuAuditCmd,
    .@"integrations.bake_ai_glyphs" = &bakeCmd,
    .@"integrations.bake_all_glyphs" = &bakeCmd,
    .@"integrations.bake_integration_glyphs" = &bakeCmd,
};

pub const catalog_rel = "data/nerd-glyphnames.json";
pub const table_name = "nerd-glyphs.tsv";

/// The catalog, from the workspace's `data/nerd-glyphnames.json`.
fn catalog(app: *App, arena: Allocator) CommandError![]tool.Glyph {
    const path = try std.fs.path.join(arena, &.{ app.workspace, catalog_rel });
    const json = std.Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(64 * 1024 * 1024)) catch
        return app.diag.fail(arena, "glyph audit: no {s} in this workspace (the mnml-zig tree has it)", .{catalog_rel});
    return tool.parseCatalog(arena, json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "glyph audit: {s} — {s}", .{ catalog_rel, @errorName(err) }),
    };
}

fn tableOf(app: *App, arena: Allocator) CommandError!tool.Table {
    const cat = try catalog(app, arena);
    var out: std.Io.Writer.Allocating = .init(arena);
    tool.bakeTable(&out.writer, cat) catch return error.OutOfMemory;
    return tool.loadTable(arena, out.written());
}

/// The report over `<workspace>/src`, appended to `w`.
fn audit(app: *App, arena: Allocator, w: *std.Io.Writer) CommandError!tool.Summary {
    const tbl = try tableOf(app, arena);
    const src = try std.fs.path.join(arena, &.{ app.workspace, "src" });
    const sites = tool.walk(arena, app.io, src) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "glyph audit: src/ — {s}", .{@errorName(err)}),
    };
    const summary = tool.report(w, sites, tbl) catch return error.OutOfMemory;
    w.print("\nglyph-audit: {d} sites, {d} tests, {d} without a fallback, {d} unknown to the catalog\n", .{ summary.sites, summary.tests, summary.no_fallback, summary.unknown }) catch return error.OutOfMemory;
    return summary;
}

/// The text into a scratch pane, the cursor at the top.
fn show(app: *App, text: []const u8) CommandError!void {
    const id = app.openScratch() catch return error.OutOfMemory;
    const e = app.panes.editor(id) orelse return;
    try e.buf.editor.setText(text);
    e.buf.editor.setCursor(0);
    app.needs_render = true;
}

fn auditCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("# glyph audit — every Nerd Font literal under src/, with its --ascii twin\n\n") catch return error.OutOfMemory;
    const s = try audit(app, arena, &out.writer);
    try show(app, out.written());
    app.toast("glyph audit: {d} sites, {d} without a fallback, {d} unknown", .{ s.sites, s.no_fallback, s.unknown });
}

/// `menu.glyph_audit`: the menu glyph table first — group, glyph,
/// catalog name, ASCII twin, and whether the glyph is one cell wide —
/// then the source audit.
fn menuAuditCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const tbl = try tableOf(app, arena);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("# menu glyph audit — one glyph per command group (ui/menu_glyph.zig)\n\n") catch return error.OutOfMemory;
    var wide: usize = 0;
    for (menu_glyph.by_group) |e| {
        const cp = std.unicode.utf8Decode(e.glyph) catch 0;
        const cells = std.unicode.utf8CountCodepoints(e.glyph) catch 1;
        if (cells != 1) wide += 1;
        w.print("{s: <14} U+{X:0>5}  {s: <28} ascii: \"{s}\"{s}\n", .{ e.group, cp, tool.nameOf(tbl, cp), e.fallback, if (cells != 1) "  ← not one codepoint" else "" }) catch return error.OutOfMemory;
    }
    w.print("\n{d} groups, {d} not a single codepoint\n\n# source audit\n\n", .{ menu_glyph.by_group.len, wide }) catch return error.OutOfMemory;
    const s = try audit(app, arena, w);
    try show(app, out.written());
    app.toast("menu glyph audit: {d} groups · {d} sites, {d} without a fallback", .{ menu_glyph.by_group.len, s.sites, s.no_fallback });
}

/// The catalog → `<data root>/nerd-glyphs.tsv`.
fn bakeCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    if (app.data_root.len == 0) return app.diag.fail(arena, "glyph bake: no data root to write {s} into", .{table_name});
    const cat = try catalog(app, arena);
    var out: std.Io.Writer.Allocating = .init(arena);
    tool.bakeTable(&out.writer, cat) catch return error.OutOfMemory;
    const target = try std.fs.path.join(arena, &.{ app.data_root, table_name });
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(app.io, app.data_root) catch {};
    cwd.writeFile(app.io, .{ .sub_path = target, .data = out.written() }) catch |err| return app.diag.fail(arena, "glyph bake: {s} — {s}", .{ target, @errorName(err) });
    app.toast("glyph bake: {d} glyphs → {s}", .{ cat.len, target });
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "audit / menu audit report the workspace's glyph sites into a scratch pane; bake writes the table; no catalog explains itself" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 100, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"integrations.audit_glyphs" }));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, catalog_rel) != null);
    try tmp.dir.createDirPath(t.io, "data");
    try tmp.dir.writeFile(t.io, .{ .sub_path = catalog_rel, .data =
        \\{"METADATA":{"date":"x"},"fa-sort":{"char":"","code":"f0dc"},"fa-refresh":{"char":"","code":"f021"}}
    });
    try tmp.dir.createDirPath(t.io, "src/ui");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/ui/chip.zig", .data =
        \\pub const sort_icon_nerd = "\u{f0dc}";
        \\pub const sort_icon_ascii = "~";
        \\pub const lonely = "\u{f1e6}";
        \\
    });
    try command.run(&app, .{ .static = .@"integrations.audit_glyphs" });
    const e = app.activeEditor().?;
    const text = e.buf.editor.bytes();
    try t.expect(std.mem.indexOf(u8, text, "ui/chip.zig:1") != null);
    try t.expect(std.mem.indexOf(u8, text, "fa-sort") != null);
    try t.expect(std.mem.indexOf(u8, text, "ascii: \"~\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "2 sites, 0 tests, 1 without a fallback, 1 unknown") != null);
    try t.expectEqualStrings("glyph audit: 2 sites, 1 without a fallback, 1 unknown", app.lastToast().?);
    // The menu audit leads with the group table; every group's glyph is one codepoint.
    try command.run(&app, .{ .static = .@"menu.glyph_audit" });
    const menu_text = app.activeEditor().?.buf.editor.bytes();
    try t.expect(std.mem.indexOf(u8, menu_text, "# menu glyph audit") != null);
    try t.expect(std.mem.indexOf(u8, menu_text, "todos          U+0F0AE") != null);
    try t.expect(std.mem.indexOf(u8, menu_text, "0 not a single codepoint") != null);
    try t.expect(std.mem.indexOf(u8, menu_text, "# source audit") != null);
    // Bake: the sorted table lands in the data root.
    try command.run(&app, .{ .static = .@"integrations.bake_all_glyphs" });
    const tsv = try tmp.dir.readFileAlloc(t.io, table_name, t.allocator, .limited(4096));
    defer t.allocator.free(tsv);
    try t.expectEqualStrings("f021\tfa-refresh\nf0dc\tfa-sort\n", tsv);
    try t.expect(std.mem.startsWith(u8, app.lastToast().?, "glyph bake: 2 glyphs"));
}
