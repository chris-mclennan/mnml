//! The glyph audit and bake as commands — `tools/glyph_audit.zig`'s
//! logic run in-process (the tool is an import of the app), the
//! result in a scratch pane — and the tofu check that runs at startup.
//!
//! - `integrations.audit_glyphs` / `menu.glyph_audit`: the tofu check
//!   first (below), then every Nerd Font literal under `<workspace>/src`
//!   against the glyph catalog, with its `--ascii` twin — the audit `zig
//!   build glyph-audit` runs, for the mnml-zig tree. The catalog is
//!   `data/nerd-glyphnames.json`, embedded (`data/root.zig`), so the
//!   audit works in any workspace. `menu.glyph_audit` adds the menu glyph
//!   table (`ui/menu_glyph.zig`) first: one row per command group, glyph,
//!   catalog name and ASCII twin.
//! - `integrations.bake_ai_glyphs` / `bake_all_glyphs` /
//!   `bake_integration_glyphs`: the catalog baked into `<data root>/
//!   nerd-glyphs.tsv`. Rust baked SVGs into a font — cut here (docs/
//!   PARITY.md); the three ids do the one bake this build has.
//!
//! The tofu check (`tofuCheck`, Rust's #1205): every icon mnml will
//! paint — the config's `ui.integration_icons`, the installed manifests'
//! chips, the four core glyphs of mnml's own block — classified by
//! `classifyGlyph` into the three verdicts Rust names. Inside mnml's
//! U+F1B00–U+F20FF block and not in the installed MnmlSymbols face's
//! cmap: a guaranteed `?` (no other font carries the block; a route
//! into it cannot help). Force-routed by ghostty's `font-codepoint-map`
//! (`ghostty_config.zig`) to an installed font whose cmap lacks it: `?`,
//! since a routed range gets no fallback. Anything else — unrouted, or
//! routed to a font not found on disk — is the terminal's fallback
//! chain's to decide, which no app can see, so it passes. The `startup`
//! hook toasts the count and names the command; it stays silent when
//! clean, and mnml-block refs stand down while MnmlSymbols is not
//! installed (a first launch predates the first bake).

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const tool = @import("glyph_audit");
const data = @import("data");
const hooks = @import("../core/hooks.zig");
const menu_glyph = @import("../ui/menu_glyph.zig");
const statusline_view = @import("../ui/statusline.zig");
const tree_view = @import("../ui/tree_view.zig");
const bufferline_view = @import("../ui/bufferline.zig");
const pty_view = @import("../ui/pty_view.zig");
const font_scan = @import("font_scan.zig");
const ghostty_config = @import("ghostty_config.zig");

pub const table = .{
    .@"integrations.audit_glyphs" = &auditCmd,
    .@"menu.glyph_audit" = &menuAuditCmd,
    .@"integrations.bake_ai_glyphs" = &bakeCmd,
    .@"integrations.bake_all_glyphs" = &bakeCmd,
    .@"integrations.bake_integration_glyphs" = &bakeCmd,
};

pub const catalog_rel = "data/nerd-glyphnames.json";
pub const table_name = "nerd-glyphs.tsv";

/// The catalog, embedded from `data/nerd-glyphnames.json`.
fn catalog(app: *App, arena: Allocator) CommandError![]tool.Glyph {
    return tool.parseCatalog(arena, data.nerd_glyphnames) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "glyph audit: {s} — {s}", .{ catalog_rel, @errorName(err) }),
    };
}

// ─── the tofu check ─────────────────────────────────────────────────────

/// mnml's own block, baked into MnmlSymbols: presence is decidable.
pub const mnml_pua_start: u21 = 0xF1B00;
pub const mnml_pua_end: u21 = 0xF20FF;

pub fn inMnmlBlock(cp: u21) bool {
    return cp >= mnml_pua_start and cp <= mnml_pua_end;
}

/// Where ghostty forces a codepoint: the family, and its cmap when the
/// family was found on disk (null = unverifiable, never flagged).
pub const Route = struct { font: []const u8, cmap: ?*const font_scan.CpSet };

/// Rust's three verdicts (`integration_audit.rs` `classify_glyph`):
/// the sentence when the glyph is certain to render as `?`, null when
/// it renders or nothing can tell. `baked` is the installed MnmlSymbols
/// face's cmap; the caller stands mnml-block refs down when it is absent.
pub fn classifyGlyph(arena: Allocator, cp: u21, baked: *const font_scan.CpSet, route: ?Route) Allocator.Error!?[]const u8 {
    if (inMnmlBlock(cp)) return if (baked.contains(cp)) null else "not baked into MnmlSymbols.ttf — guaranteed `?`";
    if (route) |r| if (r.cmap) |cmap| if (!cmap.contains(cp))
        return try std.fmt.allocPrint(arena, "force-routed to `{s}` which lacks it — `?` (routed ranges get no fallback)", .{r.font});
    return null;
}

pub const Verdict = struct {
    id: []const u8,
    cp: u21,
    label: []const u8,
    /// `config icon`, `manifest`, `core UI`.
    source: []const u8,
    why: []const u8,
};

pub const Check = struct {
    verdicts: []Verdict = &.{},
    /// Icon references classified.
    refs: usize = 0,
    /// The MnmlSymbols face was found and its cmap read.
    mnml_present: bool = false,
    mnml_path: ?[]const u8 = null,
    map: ghostty_config.Map = .{},
};

/// An icon reference to classify: the id, the glyph's first codepoint,
/// a label and where it came from.
const Ref = struct { id: []const u8, cp: u21, label: []const u8, source: []const u8 };

fn firstCodepoint(s: []const u8) ?u21 {
    if (s.len == 0) return null;
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return null;
    if (n > s.len) return null;
    return std.unicode.utf8Decode(s[0..n]) catch null;
}

/// The core glyphs mnml paints from its own block every frame.
const core_glyphs = [_]struct { glyph: []const u8, name: []const u8 }{
    .{ .glyph = statusline_view.claude_glyph, .name = "claude-mark" },
    // The alternate `ui.claude_mark = .spark` paints — baked into the
    // same face, so an audit that skipped it would call a face fine
    // that turns the chosen mark into tofu.
    .{ .glyph = bufferline_view.spark_glyph, .name = "claude-spark" },
    .{ .glyph = statusline_view.codex_glyph, .name = "codex-mark" },
    .{ .glyph = tree_view.cont_glyph, .name = "tree-line-vertical" },
    .{ .glyph = tree_view.corner_glyph, .name = "tree-line-corner" },
    .{ .glyph = bufferline_view.ghost_glyph, .name = "terminal-mark" },
    .{ .glyph = pty_view.cursor_hollow_glyph, .name = "cursor-hollow" },
};

/// The check over this machine: the fonts `font_scan` found, ghostty's
/// map, the config's icons and the installed manifests' chips.
pub fn tofuCheck(app: *App, arena: Allocator) Allocator.Error!Check {
    const gpa = app.gpa;
    var out: Check = .{};
    out.map = try ghostty_config.load(arena, app.io, &app.env);
    var baked: ?font_scan.CpSet = null;
    defer if (baked) |*b| b.deinit(gpa);
    if (font_scan.mnmlSymbolsPath(app)) |p| {
        baked = try font_scan.cmapCodepoints(gpa, app.io, p);
        out.mnml_path = p;
    }
    out.mnml_present = baked != null;
    var none: font_scan.CpSet = .empty;
    const baked_set: *const font_scan.CpSet = if (baked) |*b| b else &none;
    // The cmap of each routed family, read once; null = not on disk.
    var routes: std.StringHashMapUnmanaged(?font_scan.CpSet) = .empty;
    defer {
        var it = routes.valueIterator();
        while (it.next()) |v| if (v.*) |*set| set.deinit(gpa);
        routes.deinit(gpa);
    }
    var refs: std.ArrayListUnmanaged(Ref) = .empty;
    for (app.cfg.ui.integration_icons) |icon| {
        const cp = firstCodepoint(icon.glyph) orelse continue;
        try refs.append(arena, .{ .id = icon.id, .cp = cp, .label = icon.label orelse icon.id, .source = "config icon" });
    }
    for (app.integrations.list) |*inst| {
        const chip = inst.manifest.chip orelse continue;
        const cp = firstCodepoint(chip.glyph) orelse continue;
        try refs.append(arena, .{ .id = inst.id(), .cp = cp, .label = inst.manifest.label, .source = "manifest" });
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var verdicts: std.ArrayListUnmanaged(Verdict) = .empty;
    for (refs.items) |ref| {
        // An ASCII letter is a fallback shim, not a glyph; a mnml-block
        // ref is unassertable before the first bake.
        if (ref.cp < 0x80) continue;
        const key = try std.fmt.allocPrint(arena, "{s}:{x}", .{ ref.id, ref.cp });
        if (seen.contains(key)) continue;
        try seen.put(arena, key, {});
        out.refs += 1;
        if (inMnmlBlock(ref.cp) and !out.mnml_present) continue;
        var route: ?Route = null;
        if (out.map.routedFont(ref.cp)) |font| {
            const slot = try routes.getOrPut(gpa, font);
            if (!slot.found_existing) slot.value_ptr.* = if (font_scan.familyNamed(app, font)) |fam| try font_scan.cmapCodepoints(gpa, app.io, fam.path) else null;
            route = .{ .font = font, .cmap = if (slot.value_ptr.*) |*set| set else null };
        }
        if (try classifyGlyph(arena, ref.cp, baked_set, route)) |why| {
            try verdicts.append(arena, .{ .id = ref.id, .cp = ref.cp, .label = ref.label, .source = ref.source, .why = why });
        }
    }
    if (out.mnml_present) for (core_glyphs) |g| {
        const cp = firstCodepoint(g.glyph) orelse continue;
        out.refs += 1;
        if (!baked_set.contains(cp)) try verdicts.append(arena, .{
            .id = g.name,
            .cp = cp,
            .label = "mnml core UI",
            .source = "core UI",
            .why = "not baked into MnmlSymbols.ttf — guaranteed `?` (rerun the bake)",
        });
    };
    out.verdicts = verdicts.items;
    return out;
}

/// The check as report lines.
fn writeCheck(w: *std.Io.Writer, c: Check) std.Io.Writer.Error!void {
    try w.writeAll("# tofu check — icons certain to render as ? on this terminal\n\n");
    if (c.map.path) |p| try w.print("ghostty map: {s} ({d} rule{s})\n", .{ p, c.map.rules.len, if (c.map.rules.len == 1) "" else "s" }) else try w.writeAll("ghostty map: no config found — unrouted glyphs are the terminal's to decide\n");
    if (c.mnml_path) |p| try w.print("MnmlSymbols: {s}{s}\n", .{ p, if (c.mnml_present) "" else " (no format-12 cmap — treated as not installed)" }) else try w.writeAll("MnmlSymbols: not installed — mnml-block refs stand down until the first bake\n");
    if (c.verdicts.len == 0) {
        try w.print("clean: {d} icon ref{s} checked\n", .{ c.refs, if (c.refs == 1) "" else "s" });
    } else {
        for (c.verdicts) |v| try w.print("{s: <20} U+{X:0>5}  {s}  ({s})  → {s}\n", .{ v.id, v.cp, v.label, v.source, v.why });
        try w.print("\n{d} of {d} icon refs will render as ?\n", .{ c.verdicts.len, c.refs });
    }
}

/// The startup toast: the count and the command, or nothing.
pub fn onStartup(app: *App, _: hooks.HookArgs) void {
    const c = tofuCheck(app, app.frame.allocator()) catch return;
    const n = c.verdicts.len;
    if (n == 0) return;
    const mark: []const u8 = if (app.cfg.ui.ascii_icons) "!" else "\u{26A0}";
    app.toastLevel(.warn, "{s} {d} integration icon{s} will render as ? — run :integrations.audit_glyphs", .{ mark, n, if (n == 1) "" else "s" }) catch {};
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
    writeCheck(&out.writer, try tofuCheck(app, arena)) catch return error.OutOfMemory;
    out.writer.writeAll("\n# glyph audit — every Nerd Font literal under src/, with its --ascii twin\n\n") catch return error.OutOfMemory;
    const s = try audit(app, arena, &out.writer);
    try show(app, out.written());
    app.toast("glyph audit: {d} sites, {d} without a fallback, {d} unknown", .{ s.sites, s.no_fallback, s.unknown });
}

/// `menu.glyph_audit`: the menu glyph tables first — needle, glyph,
/// catalog name, ASCII twin, and whether the glyph is one cell wide —
/// then the source audit.
fn menuAuditCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const tbl = try tableOf(app, arena);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("# menu glyph audit — Rust's rule: the action table, then the domain table (ui/menu_glyph.zig)\n\n") catch return error.OutOfMemory;
    var wide: usize = 0;
    inline for (.{ .{ "action", &menu_glyph.by_action }, .{ "domain", &menu_glyph.by_domain } }) |tab| {
        w.print("## by {s}\n", .{tab[0]}) catch return error.OutOfMemory;
        for (tab[1]) |e| {
            const cp = std.unicode.utf8Decode(e.glyph) catch 0;
            const cells = std.unicode.utf8CountCodepoints(e.glyph) catch 1;
            if (cells != 1) wide += 1;
            w.print("{s: <14} U+{X:0>5}  {s: <28} ascii: \"{s}\"{s}\n", .{ e.needle, cp, tool.nameOf(tbl, cp), e.fallback, if (cells != 1) "  ← not one codepoint" else "" }) catch return error.OutOfMemory;
        }
    }
    const n_entries = menu_glyph.by_action.len + menu_glyph.by_domain.len;
    w.print("\n{d} entries, {d} not a single codepoint\n\n# source audit\n\n", .{ n_entries, wide }) catch return error.OutOfMemory;
    const s = try audit(app, arena, w);
    try show(app, out.written());
    app.toast("menu glyph audit: {d} entries · {d} sites, {d} without a fallback", .{ n_entries, s.sites, s.no_fallback });
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

test "audit / menu audit report the workspace's glyph sites into a scratch pane; bake writes the table; the catalog is embedded" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 100, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    // No `src/` in the workspace: the audit says so, the catalog needs nothing.
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"integrations.audit_glyphs" }));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "src/") != null);
    try tmp.dir.createDirPath(t.io, "src/ui");
    // f0dc is fa-sort; f1e6 (fa-plug) has no twin; e0ff is private-use
    // outside the catalog and outside mnml's block — unknown.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/ui/chip.zig", .data =
        \\pub const sort_icon_nerd = "\u{f0dc}";
        \\pub const sort_icon_ascii = "~";
        \\pub const lonely = "\u{f1e6}";
        \\pub const own_nerd = "\u{e0ff}";
        \\pub const own_ascii = "o";
        \\
    });
    try command.run(&app, .{ .static = .@"integrations.audit_glyphs" });
    const e = app.activeEditor().?;
    const text = e.buf.editor.bytes();
    try t.expect(std.mem.indexOf(u8, text, "# tofu check") != null);
    try t.expect(std.mem.indexOf(u8, text, "MnmlSymbols: not installed") != null);
    try t.expect(std.mem.indexOf(u8, text, "clean: 4 icon refs checked") != null);
    try t.expect(std.mem.indexOf(u8, text, "ui/chip.zig:1") != null);
    // f0dc is `fa-sort` and `fa-unsorted` both; the table keeps one.
    try t.expect(std.mem.indexOf(u8, text, "U+F0DC  fa-") != null);
    try t.expect(std.mem.indexOf(u8, text, "fa-plug") != null);
    try t.expect(std.mem.indexOf(u8, text, "ascii: \"~\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "3 sites, 0 tests, 1 without a fallback, 1 unknown") != null);
    try t.expectEqualStrings("glyph audit: 3 sites, 1 without a fallback, 1 unknown", app.lastToast().?);
    // The menu audit leads with the two tables; every glyph is one codepoint.
    try command.run(&app, .{ .static = .@"menu.glyph_audit" });
    const menu_text = app.activeEditor().?.buf.editor.bytes();
    try t.expect(std.mem.indexOf(u8, menu_text, "# menu glyph audit") != null);
    try t.expect(std.mem.indexOf(u8, menu_text, "todos          U+0F046") != null);
    try t.expect(std.mem.indexOf(u8, menu_text, "0 not a single codepoint") != null);
    try t.expect(std.mem.indexOf(u8, menu_text, "# source audit") != null);
    // Bake: the sorted table lands in the data root.
    try command.run(&app, .{ .static = .@"integrations.bake_all_glyphs" });
    const tsv = try tmp.dir.readFileAlloc(t.io, table_name, t.allocator, .limited(1024 * 1024));
    defer t.allocator.free(tsv);
    try t.expect(std.mem.indexOf(u8, tsv, "f0dc\tfa-sort\n") != null);
    try t.expect(std.mem.startsWith(u8, app.lastToast().?, "glyph bake: "));
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, " glyphs") != null);
}

test "classifyGlyph: the mnml block against the baked cmap, a routed font that lacks the glyph, and the two silences" {
    const gpa = t.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var baked: font_scan.CpSet = .empty;
    defer baked.deinit(gpa);
    try baked.put(gpa, 0xF1C04, {});
    try t.expect((try classifyGlyph(arena, 0xF1C04, &baked, null)) == null);
    try t.expectEqualStrings("not baked into MnmlSymbols.ttf — guaranteed `?`", (try classifyGlyph(arena, 0xF1B0A, &baked, null)).?);
    // A route into MnmlSymbols cannot help a glyph the face lacks.
    var empty: font_scan.CpSet = .empty;
    defer empty.deinit(gpa);
    try t.expect((try classifyGlyph(arena, 0xF1B0A, &baked, .{ .font = "MnmlSymbols", .cmap = &empty })) != null);
    var nf: font_scan.CpSet = .empty;
    defer nf.deinit(gpa);
    try nf.put(gpa, 0xEB40, {});
    try t.expect((try classifyGlyph(arena, 0xEB40, &baked, .{ .font = "Symbols Nerd Font Mono", .cmap = &nf })) == null);
    try t.expectEqualStrings("force-routed to `Symbols Nerd Font Mono` which lacks it — `?` (routed ranges get no fallback)", (try classifyGlyph(arena, 0xEB41, &baked, .{ .font = "Symbols Nerd Font Mono", .cmap = &nf })).?);
    // Routed to a font not on disk, or unrouted: nothing can tell.
    try t.expect((try classifyGlyph(arena, 0xEB41, &baked, .{ .font = "Mystery Font", .cmap = null })) == null);
    try t.expect((try classifyGlyph(arena, 0xEB41, &baked, null)) == null);
}

test "the startup check: a MnmlSymbols face missing the config's marks toasts the count; the audit pane lists each verdict" {
    const gpa = t.allocator;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.createDirPath(io, "fonts");
    try tmp.dir.createDirPath(io, "xdg/ghostty");
    // The face carries the two tree connectors and the codex mark only;
    // the browser icon (EB01, outside the block) is routed to a Symbols
    // face that has EB00 but not EB01.
    const mnml = try font_scan.buildFixture(gpa, .{ .family = "MnmlSymbols", .cmap = &.{ .{ 0xF1E01, 0xF1E01 }, .{ 0xF1F04, 0xF1F05 } } });
    defer gpa.free(mnml);
    try tmp.dir.writeFile(io, .{ .sub_path = "fonts/MnmlSymbols.ttf", .data = mnml });
    const symbols = try font_scan.buildFixture(gpa, .{ .family = "Symbols Nerd Font Mono", .version = "Version 1;Nerd Fonts 3.5.1", .cmap = &.{.{ 0xEB00, 0xEB00 }} });
    defer gpa.free(symbols);
    try tmp.dir.writeFile(io, .{ .sub_path = "fonts/SymbolsNerdFontMono-Regular.ttf", .data = symbols });
    try tmp.dir.writeFile(io, .{ .sub_path = "xdg/ghostty/config", .data = "font-codepoint-map = U+EA60-U+EC1E=Symbols Nerd Font Mono\nfont-codepoint-map = U+F1B00-U+F20FF=MnmlSymbols\n" });
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const fonts_dir = try std.fs.path.join(gpa, &.{ root, "fonts" });
    defer gpa.free(fonts_dir);
    const xdg = try std.fs.path.join(gpa, &.{ root, "xdg" });
    defer gpa.free(xdg);
    try env.put("MNML_FONT_DIRS", fonts_dir);
    try env.put("MNML_NERDFONTS_LATEST", "3.5.1");
    try env.put("XDG_CONFIG_HOME", xdg);
    var app = try App.initWith(gpa, io, .{ .workspace = root, .data_root = root, .cols = 120, .rows = 30, .env = &env });
    defer app.deinit();
    app.tree.visible = false;
    font_scan.onStartup(&app, .startup);
    onStartup(&app, .startup);
    // The shipped icons: browser EB01 (routed, lacking), claude F1E00
    // (not baked), codex F1E01 (baked), http F1D8; the core claude
    // mark again, the terminal mark F2000, and the hollow cursor
    // F2001 — neither of which this fixture's face carries.
    try t.expectEqualStrings("\u{26A0} 5 integration icons will render as ? — run :integrations.audit_glyphs", app.lastToast().?);
    const c = try tofuCheck(&app, app.frame.allocator());
    try t.expect(c.mnml_present);
    try t.expectEqual(@as(usize, 2), c.map.rules.len);
    try t.expectEqual(@as(usize, 10), c.refs);
    try t.expectEqual(@as(usize, 5), c.verdicts.len);
    try t.expectEqualStrings("browser", c.verdicts[0].id);
    try t.expect(std.mem.startsWith(u8, c.verdicts[0].why, "force-routed to `Symbols Nerd Font Mono`"));
    try t.expectEqualStrings("claude_code", c.verdicts[1].id);
    try t.expectEqualStrings("claude-mark", c.verdicts[2].id);
    try t.expectEqualStrings("core UI", c.verdicts[2].source);
    // The terminal mark is core too, and this face does not carry it;
    // nor the hollow cursor an unfocused pty pane paints.
    try t.expectEqualStrings("terminal-mark", c.verdicts[3].id);
    try t.expectEqual(@as(u21, 0xF2000), c.verdicts[3].cp);
    try t.expectEqualStrings("cursor-hollow", c.verdicts[4].id);
    try t.expectEqual(@as(u21, 0xF2001), c.verdicts[4].cp);
    // The pane: the verdicts under the check's header.
    try tmp.dir.createDirPath(io, "src");
    try command.run(&app, .{ .static = .@"integrations.audit_glyphs" });
    const text = app.activeEditor().?.buf.editor.bytes();
    try t.expect(std.mem.indexOf(u8, text, "ghostty map: ") != null);
    try t.expect(std.mem.indexOf(u8, text, "(2 rules)") != null);
    try t.expect(std.mem.indexOf(u8, text, "browser              U+0EB01  Browser  (config icon)  → force-routed") != null);
    try t.expect(std.mem.indexOf(u8, text, "5 of 10 icon refs will render as ?") != null);
    // Without the face, the block stands down and only the routed miss remains.
    try tmp.dir.deleteFile(io, "fonts/MnmlSymbols.ttf");
    font_scan.onStartup(&app, .startup);
    const c2 = try tofuCheck(&app, app.frame.allocator());
    try t.expect(!c2.mnml_present);
    try t.expectEqual(@as(usize, 1), c2.verdicts.len);
    try t.expectEqualStrings("browser", c2.verdicts[0].id);
}
