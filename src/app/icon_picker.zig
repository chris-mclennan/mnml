//! `integrations.icon_picker`: every Nerd Font glyph in the picker, from
//! the embedded catalog (`data/nerd-glyphnames.json`, the same one the
//! glyph audit reads), as Rust's `open_icon_picker` lists them — the
//! glyph, its human name, its category chip and its codepoint on the
//! row (`  repo pull  [cod]  U+EB40`), the canonical `nf-` name and the
//! `\u{…}` escape as the detail, and the font ghostty's
//! `font-codepoint-map` routes the codepoint to when one does
//! (`→ MnmlSymbols`). The picker's own fuzzy match runs over the whole
//! label, so `pull` finds every `*_pull`, `cod` narrows to Codicons and
//! `eb40` lands on the codepoint.
//!
//! Enter copies the glyph itself to the clipboard (the title says so)
//! and toasts the escape beside it; a right-click on a row — or Ctrl+C
//! on the cursor's — offers the codepoint escape (`\u{…}`) and the `nf-`
//! name as well. // changed: Rust's accept copies a three-part line
//! (`<glyph>  \u{…}  (<label>)`); a pasted glyph is what the config's
//! `.glyph` field wants, so the glyph alone goes, and the codepoint has
//! its own row.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const MenuItem = command.MenuItem;
const cmd_picker = @import("cmd_picker.zig");
const context_menus = @import("context_menus.zig");
const ghostty_config = @import("ghostty_config.zig");
const glyph_audit = @import("glyph_audit");
const data = @import("data");

pub const table = .{
    .@"integrations.icon_picker" = &open,
};

pub const title = "Pick glyph (Enter copies it)";

/// One catalog entry as the picker shows it.
pub const Entry = struct {
    codepoint: u21,
    /// `cod-repo_pull`.
    name: []const u8,
    /// `cod` — the part before the first `-`; empty when there is none.
    category: []const u8,
    /// `repo pull` — the rest, `_` as spaces.
    human: []const u8,
};

pub fn entryOf(arena: Allocator, g: glyph_audit.Glyph) Allocator.Error!Entry {
    const dash = std.mem.indexOfScalar(u8, g.name, '-');
    const category: []const u8 = if (dash) |d| g.name[0..d] else "";
    const suffix: []const u8 = if (dash) |d| g.name[d + 1 ..] else g.name;
    const human = try arena.dupe(u8, suffix);
    std.mem.replaceScalar(u8, human, '_', ' ');
    return .{ .codepoint = g.codepoint, .name = g.name, .category = category, .human = human };
}

/// The row: `<glyph>  <human>  [<category>]  U+<HEX>`.
pub fn label(gpa: Allocator, e: Entry) Allocator.Error![]u8 {
    var glyph: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(e.codepoint, &glyph) catch 0;
    if (e.category.len > 0) return std.fmt.allocPrint(gpa, "{s}  {s}  [{s}]  U+{X:0>4}", .{ glyph[0..n], e.human, e.category, e.codepoint });
    return std.fmt.allocPrint(gpa, "{s}  {s}  U+{X:0>4}", .{ glyph[0..n], e.human, e.codepoint });
}

/// The detail: `nf-<name>  \u{<HEX>}`, then `  → <font>` when ghostty
/// routes the codepoint.
pub fn detail(gpa: Allocator, e: Entry, routed: ?[]const u8) Allocator.Error![]u8 {
    if (routed) |f| return std.fmt.allocPrint(gpa, "nf-{s}  \\u{{{X:0>4}}}  \u{2192} {s}", .{ e.name, e.codepoint, f });
    return std.fmt.allocPrint(gpa, "nf-{s}  \\u{{{X:0>4}}}", .{ e.name, e.codepoint });
}

fn open(app: *App) CommandError!void {
    const gpa = app.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const catalog = glyph_audit.parseCatalog(arena, data.nerd_glyphnames) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(app.frame.allocator(), "icon picker: the glyph catalog did not parse — {s}", .{@errorName(err)}),
    };
    const map = try ghostty_config.load(arena, app.io, &app.env);
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    try labels.ensureTotalCapacity(gpa, catalog.len);
    try details.ensureTotalCapacity(gpa, catalog.len);
    for (catalog) |g| {
        const e = try entryOf(arena, g);
        const l = try label(gpa, e);
        errdefer gpa.free(l);
        const d = try detail(gpa, e, map.routedFont(e.codepoint));
        errdefer gpa.free(d);
        labels.appendAssumeCapacity(l);
        details.appendAssumeCapacity(d);
    }
    if (labels.items.len == 0) return app.diag.fail(app.frame.allocator(), "icon picker: the glyph catalog is empty", .{});
    const hints = try gpa.alloc([]u8, 0);
    errdefer gpa.free(hints);
    const panes = try gpa.alloc(PaneId, 0);
    errdefer gpa.free(panes);
    try cmd_picker.openPickerWith(app, title, .icon_glyphs, try labels.toOwnedSlice(gpa), panes, try details.toOwnedSlice(gpa), hints);
}

/// The codepoint a row names: the `U+<HEX>` at the label's end.
pub fn codepointOf(row_label: []const u8) ?u21 {
    const at = std.mem.lastIndexOf(u8, row_label, "U+") orelse return null;
    return std.fmt.parseInt(u21, row_label[at + 2 ..], 16) catch null;
}

/// Every row's codepoint as bare hex (`EB40`), for the ranker's id pin:
/// a typed codepoint lands on its own row, not on every row whose text
/// happens to spell those four characters in order.
pub fn hexIds(app: *App, arena: Allocator) Allocator.Error![]const []const u8 {
    const p = &app.overlay.picker;
    const out = try arena.alloc([]const u8, p.labels.len);
    for (p.labels, 0..) |l, i| {
        const at = std.mem.lastIndexOf(u8, l, "U+") orelse {
            out[i] = "";
            continue;
        };
        out[i] = l[at + 2 ..];
    }
    return out;
}

/// The `nf-…` name a row carries: the detail's first word.
fn nameOf(row_detail: []const u8) []const u8 {
    const sp = std.mem.indexOfScalar(u8, row_detail, ' ') orelse row_detail.len;
    return row_detail[0..sp];
}

fn glyphStr(buf: *[4]u8, cp: u21) []const u8 {
    const n = std.unicode.utf8Encode(cp, buf) catch return "?";
    return buf[0..n];
}

/// Enter: the glyph to the clipboard; the toast says how to paste it
/// either way. `i` indexes the unfiltered rows.
pub fn accept(app: *App, i: usize) Allocator.Error!void {
    const p = &app.overlay.picker;
    const cp = codepointOf(p.labels[i]) orelse return;
    app.overlay.deinit(app.gpa);
    app.focus = if (app.active) |a| .{ .pane = a } else .tree;
    var buf: [4]u8 = undefined;
    const glyph = glyphStr(&buf, cp);
    try app.clipboard.copy(glyph);
    app.toast("icon copied \u{2014} paste: {s} or \\u{{{X:0>4}}}", .{ glyph, cp });
}

/// Ctrl+C on the cursor's row: the codepoint escape to the clipboard;
/// the picker stays. False when the key is not that.
pub fn chord(app: *App, k: app_mod.Key) Allocator.Error!bool {
    if (k.code != .char or k.code.char != 'c' or !k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    const p = &app.overlay.picker;
    if (p.state.cursor >= p.filtered.items.len) return true;
    const cp = codepointOf(p.labels[p.filtered.items[p.state.cursor]]) orelse return true;
    const esc = try std.fmt.allocPrint(app.frame.allocator(), "\\u{{{X:0>4}}}", .{cp});
    try app.clipboard.copy(esc);
    app.toast("copied {s}", .{esc});
    return true;
}

/// Right-click on a row: Copy glyph / Copy codepoint / Copy name. The
/// menu takes the picker's place; `idx` indexes the filtered rows.
pub fn openRowMenu(app: *App, idx: usize, x: u16, y: u16) Allocator.Error!void {
    const p = &app.overlay.picker;
    if (idx >= p.filtered.items.len) return;
    const i = p.filtered.items[idx];
    const cp = codepointOf(p.labels[i]) orelse return;
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const a = mem.allocator();
    var buf: [4]u8 = undefined;
    const glyph = try a.dupe(u8, glyphStr(&buf, cp));
    const esc = try std.fmt.allocPrint(a, "\\u{{{X:0>4}}}", .{cp});
    const name = try a.dupe(u8, if (i < p.details.len) nameOf(p.details[i]) else "");
    const menu_title = try std.fmt.allocPrint(a, "{s}  U+{X:0>4}", .{ glyph, cp });
    const rows = try app.gpa.dupe(MenuItem, &.{
        .{ .label = "Copy glyph", .action = .{ .copy_text = glyph } },
        .{ .label = "Copy codepoint", .action = .{ .copy_text = esc } },
        .{ .label = "Copy name", .action = .{ .copy_text = name } },
    });
    errdefer app.gpa.free(rows);
    try context_menus.openOwned(app, menu_title, rows, x, y, mem);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Key = app_mod.Key;

test "the row and the detail: glyph, human name, category chip, codepoint; the nf- name and the escape; the routed font when ghostty maps the codepoint" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const e = try entryOf(arena, .{ .codepoint = 0xEB40, .name = "cod-repo_pull" });
    try t.expectEqualStrings("cod", e.category);
    try t.expectEqualStrings("repo pull", e.human);
    const l = try label(arena, e);
    try t.expectEqualStrings("\u{EB40}  repo pull  [cod]  U+EB40", l);
    try t.expectEqual(@as(?u21, 0xEB40), codepointOf(l));
    try t.expectEqualStrings("nf-cod-repo_pull  \\u{EB40}", try detail(arena, e, null));
    try t.expectEqualStrings("nf-cod-repo_pull  \\u{EB40}  \u{2192} MnmlSymbols", try detail(arena, e, "MnmlSymbols"));
    // A supplementary-plane glyph and a name without a category.
    const m = try entryOf(arena, .{ .codepoint = 0xF0162, .name = "md-cloud_download" });
    try t.expectEqualStrings("\u{F0162}  cloud download  [md]  U+F0162", try label(arena, m));
    const bare = try entryOf(arena, .{ .codepoint = 0xE000, .name = "lonely" });
    try t.expectEqualStrings("", bare.category);
    try t.expectEqualStrings("\u{E000}  lonely  U+E000", try label(arena, bare));
    try t.expect(codepointOf("no codepoint here") == null);
}

test "integrations.icon_picker: thousands of rows from the embedded catalog; typing narrows to the glyph; Enter copies the glyph; Ctrl+C the escape; the right-click menu offers glyph, codepoint and name" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 120, .rows = 40 });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"integrations.icon_picker" });
    try t.expect(app.overlay == .picker);
    try t.expect(app.overlay.picker.kind == .icon_glyphs);
    try t.expectEqualStrings(title, app.overlay.picker.state.title);
    try t.expect(app.overlay.picker.labels.len > 5000);
    try t.expectEqual(app.overlay.picker.labels.len, app.overlay.picker.details.len);
    // The name finds the row; the codepoint's hex finds it too.
    for ("cod-repo_pull") |c| try app.handle(.{ .key = Key.char(c) });
    const p = &app.overlay.picker;
    try t.expect(p.filtered.items.len > 0);
    const top = p.labels[p.filtered.items[0]];
    try t.expectEqualStrings("\u{EB40}  repo pull  [cod]  U+EB40", top);
    try t.expectEqualStrings("nf-cod-repo_pull  \\u{EB40}", p.details[p.filtered.items[0]]);
    // Ctrl+C: the escape, the picker stays.
    try app.handle(.{ .key = .{ .code = .{ .char = 'c' }, .mods = .{ .ctrl = true } } });
    try t.expect(app.overlay == .picker);
    try t.expectEqualStrings("\\u{EB40}", app.clipboard.text());
    // Right-click on the top row: the menu with its three rows.
    try app.render();
    var hit_y: u16 = 0;
    var hit_x: u16 = 0;
    for (app.hits.items.items) |h| if (h.target == .overlay_item and h.target.overlay_item == 0) {
        hit_x = h.rect.x;
        hit_y = h.rect.y;
    };
    try t.expect(hit_y > 0);
    try app.handle(.{ .mouse = .{ .x = hit_x, .y = hit_y, .kind = .press, .button = .right } });
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("\u{EB40}  U+EB40", app.overlay.menu.title);
    try t.expectEqual(@as(usize, 3), app.overlay.menu.items.len);
    try t.expectEqualStrings("Copy name", app.overlay.menu.items[2].label);
    try t.expectEqualStrings("nf-cod-repo_pull", app.overlay.menu.items[2].action.copy_text);
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("nf-cod-repo_pull", app.clipboard.text());
    // Enter on the row: the glyph alone.
    try command.run(&app, .{ .static = .@"integrations.icon_picker" });
    for ("eb40") |c| try app.handle(.{ .key = Key.char(c) });
    try t.expect(std.mem.endsWith(u8, app.overlay.picker.labels[app.overlay.picker.filtered.items[0]], "U+EB40"));
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try t.expectEqualStrings("\u{EB40}", app.clipboard.text());
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "\\u{EB40}") != null);
}
