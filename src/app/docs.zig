//! The embedded manual, one section at a time — what a hover-help
//! entry's `docs` link opens (`info_view_copy.Link.docs`).
//!
//! `docs/CONFIG.md` ships inside the binary (`zon_schema.config_md`,
//! the same text the Settings rows read their comments from), so a
//! link can open *The launcher dock* or *Workspace trust* rendered,
//! on any install, without a docs directory on disk. A section is the
//! heading line and everything under it up to the next heading of the
//! same or a higher level; it opens as a markdown preview whose path
//! is virtual — `mnml-docs://CONFIG.md — The launcher dock` — so the
//! pane finder dedupes it, the session brings it back by that path,
//! and `swapToEditor` knows there is nothing to edit.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const md_preview = @import("md_preview.zig");
const zon_schema = @import("../config/zon_schema.zig");

/// The documents the binary carries. Additive: a new one is a file
/// embedded in `build.zig` and a case in `text` / `file`.
pub const Doc = enum {
    config,

    pub fn text(d: Doc) []const u8 {
        return switch (d) {
            .config => zon_schema.config_md,
        };
    }

    pub fn file(d: Doc) []const u8 {
        return switch (d) {
            .config => "CONFIG.md",
        };
    }

    fn byFile(name: []const u8) ?Doc {
        inline for (comptime std.enums.values(Doc)) |d| if (std.mem.eql(u8, d.file(), name)) return d;
        return null;
    }
};

pub const scheme = "mnml-docs://";
const sep = " \u{2014} ";

/// The section headed `## name` (or `### name`, any level) of `doc`:
/// the heading line through the line before the next heading of the
/// same or a higher level. Null when no heading has that text — the
/// lint reports a link to one.
pub fn section(doc: Doc, name: []const u8) ?[]const u8 {
    const md = doc.text();
    var start: ?usize = null;
    var level: usize = 0;
    var pos: usize = 0;
    while (pos <= md.len) {
        const end = std.mem.indexOfScalarPos(u8, md, pos, '\n') orelse md.len;
        const line = md[pos..end];
        const lvl = headingLevel(line);
        if (start) |s| {
            if (lvl > 0 and lvl <= level) return md[s..pos];
        } else if (lvl > 0 and std.mem.eql(u8, std.mem.trim(u8, line[lvl..], " \t"), name)) {
            start = pos;
            level = lvl;
        }
        if (end == md.len) break;
        pos = end + 1;
    }
    return if (start) |s| md[s..] else null;
}

/// The count of leading `#` when `line` is a heading, else 0.
fn headingLevel(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == '#') n += 1;
    if (n == 0 or n >= line.len or line[n] != ' ') return 0;
    return n;
}

/// The preview's path for a section: virtual, and the tab's title is
/// its basename — `CONFIG.md — The launcher dock`.
pub fn virtualPath(arena: Allocator, doc: Doc, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{ scheme, doc.file(), sep, name });
}

pub const Ref = struct { doc: Doc, name: []const u8 };

/// The section a virtual path names, or null for a path on disk.
pub fn parse(path: []const u8) ?Ref {
    if (!std.mem.startsWith(u8, path, scheme)) return null;
    const rest = path[scheme.len..];
    const cut = std.mem.indexOf(u8, rest, sep) orelse return null;
    const doc = Doc.byFile(rest[0..cut]) orelse return null;
    return .{ .doc = doc, .name = rest[cut + sep.len ..] };
}

pub fn isVirtual(path: []const u8) bool {
    return std.mem.startsWith(u8, path, scheme);
}

/// The text a virtual path renders: the section, or a line saying the
/// heading is gone (a session file older than a docs rewrite).
pub fn textFor(path: []const u8) ?[]const u8 {
    const ref = parse(path) orelse return null;
    return section(ref.doc, ref.name) orelse "_This section is no longer in the manual._\n";
}

/// Open the section as a glance preview (the same tab the last docs
/// glance used), or reveal it when it is already open.
pub fn open(app: *App, doc: Doc, name: []const u8) Allocator.Error!PaneId {
    const path = try virtualPath(app.frame.allocator(), doc, name);
    const id = try md_preview.open(app, path, .here, null);
    app.setActive(id);
    app.focus = .{ .pane = id };
    return id;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "section: a `##` heading runs to the next `##`, a `###` stops at the next heading of either level, a missing heading is null" {
    const dock = section(.config, "The launcher dock").?;
    try t.expect(std.mem.startsWith(u8, dock, "## The launcher dock\n"));
    try t.expect(std.mem.indexOf(u8, dock, "\n## Session worktrees") == null);
    try t.expect(std.mem.indexOf(u8, dock, "`ui.dock`") != null);
    const overlay = section(.config, "The settings overlay").?;
    try t.expect(std.mem.startsWith(u8, overlay, "### The settings overlay\n"));
    try t.expect(std.mem.indexOf(u8, overlay, "### Themes") == null);
    // `## Writes` holds its `###` children.
    const writes = section(.config, "Writes").?;
    try t.expect(std.mem.indexOf(u8, writes, "### The settings overlay") != null);
    try t.expect(std.mem.indexOf(u8, writes, "## Coming from 0.2.x") == null);
    try t.expect(section(.config, "No such heading") == null);
    // The last section runs to the end of the file.
    const last = section(.config, "Coming from 0.2.x (TOML)").?;
    try t.expect(std.mem.endsWith(u8, zon_schema.config_md, last));
}

test "virtualPath round-trips through parse; a disk path is not virtual" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const p = try virtualPath(a, .config, "Workspace trust");
    try t.expectEqualStrings("mnml-docs://CONFIG.md \u{2014} Workspace trust", p);
    try t.expectEqualStrings("CONFIG.md \u{2014} Workspace trust", std.fs.path.basename(p));
    const ref = parse(p).?;
    try t.expectEqual(Doc.config, ref.doc);
    try t.expectEqualStrings("Workspace trust", ref.name);
    try t.expect(std.mem.startsWith(u8, textFor(p).?, "## Workspace trust"));
    try t.expect(parse("/tmp/README.md") == null);
    try t.expect(!isVirtual("/tmp/README.md"));
    try t.expect(parse("mnml-docs://OTHER.md \u{2014} x") == null);
    // A heading the manual no longer has renders a line, not a crash.
    try t.expect(std.mem.indexOf(u8, textFor("mnml-docs://CONFIG.md \u{2014} Gone").?, "no longer") != null);
}

test "open: the section renders as a preview pane on the virtual path, a second open reveals the same pane, and typing does not swap an editor in" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 30 });
    defer app.deinit();
    const id = try open(&app, .config, "The launcher dock");
    const pane = app.panes.get(id).?;
    try t.expect(pane.* == .md_preview);
    try t.expectEqualStrings("CONFIG.md \u{2014} The launcher dock", pane.title());
    try t.expect(std.mem.startsWith(u8, pane.md_preview.text, "## The launcher dock\n"));
    try t.expectEqual(id, try open(&app, .config, "The launcher dock"));
    try t.expectEqual(@as(usize, 1), app.panes.count());
    // Typing on the manual: no editor opens on the virtual path.
    try t.expect(try md_preview.handleKey(&app, id, .{ .code = .{ .char = 'x' } }));
    const still = app.panes.get(id) orelse return error.TestUnexpectedResult;
    try t.expect(still.* == .md_preview);
    try t.expectEqual(@as(usize, 1), app.panes.count());
    // Another section takes over the glance tab.
    const trust = try open(&app, .config, "Workspace trust");
    try t.expectEqual(id, trust);
    try t.expect(std.mem.startsWith(u8, app.panes.get(id).?.md_preview.text, "## Workspace trust\n"));
}
