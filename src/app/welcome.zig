//! The welcome pane's app side (`ui/welcome.zig` paints it): what the
//! editor area shows while the layout is empty, per `ui.welcome`.
//!
//! `full` is the start surface. Its four lists are other surfaces'
//! own rows, read through the functions those surfaces list from —
//! nothing here keeps a second copy:
//!
//! - WORKSPACES — `tree.workspaceRows`, `view.switch_workspace`'s
//!   rows; Enter is that picker's accept (`Tree.switchTo`).
//! - RECENT FILES — `cmd_picker.recentFiles`, `picker.recent`'s rows;
//!   Enter opens the file.
//! - SESSIONS — `sessions.resumable`, the SESSIONS section's scan rows
//!   of this workspace that no live process holds; Enter is the
//!   section's own resume (`sessions.resumeItem`). The list's New row
//!   is `ai.claude_code_new`. The first frame that shows the list asks
//!   for the section's scan, as the section's own first frame does.
//! - SHORTCUTS — the commands worth knowing first, each with its chord
//!   under the active profile read off the spec table (`startChord`):
//!   `Space f f` under vim, `Ctrl+P` under the standard profile. A
//!   command the profile leaves unbound is left out.
//!
//! The keys (`handleKey`, while `app.focus == .welcome`): j / k and the
//! arrows walk the list the cursor is in, Tab / Shift+Tab move between
//! the lists on screen, Enter acts, `?` opens the cheatsheet, Esc hands
//! the keys back to the tree. Everything else goes on to the chord
//! chain, so every shortcut on the list works from here. The surface
//! takes the keys from the tree the way a pane does (`view.focus_pane`,
//! `Ctrl-W l` / `Ctrl+L`), and a click on a row both acts and puts the
//! cursor there.
//!
//! `minimal` is the shape the pane had before — the logo, the
//! workspace line, today's six shortcuts, the version — with its rows
//! clickable. `off` paints the bare ground.

const std = @import("std");
const sidebar_auto = @import("sidebar_auto.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Key = app_mod.Key;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const command = @import("../core/command.zig");
const keymap = @import("../core/keymap.zig");
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const hit = @import("../ui/hit.zig");
const ui_welcome = @import("../ui/welcome.zig");
const list_panel = @import("../ui/list_panel.zig");
const info_copy = @import("info_view_copy.zig");
const sessions = @import("../sessions.zig");
const tree_mod = @import("tree.zig");
const cmd_picker = @import("cmd_picker.zig");
const context_menus = @import("context_menus.zig");
const git_app = @import("git.zig");
const update = @import("update.zig");

pub const State = ui_welcome.State;
pub const List = ui_welcome.List;
pub const Entry = ui_welcome.Entry;
pub const Mode = @import("../config/Config.zig").WelcomeMode;

/// The welcome pane is on screen: the layout is empty and `ui.welcome`
/// is not `off`.
pub fn shown(app: *App) bool {
    return app.cfg.ui.welcome != .off and app.layouts.current().isEmpty();
}

/// The start surface is on screen.
pub fn full(app: *App) bool {
    return app.cfg.ui.welcome == .full and shown(app);
}

/// The start surface takes this key press: it has the keys, or nothing
/// else does (the tree put away or off screen — auto-hidden on a narrow
/// terminal — and no pane to fall back on).
pub fn takesKeys(app: *App) bool {
    if (!full(app)) return false;
    return switch (app.focus) {
        .welcome => true,
        .tree => !app.tree.visible or !sidebar_auto.focusOnScreen(app, .tree),
        .pane => app.active == null,
        .panel, .overlay => false,
    };
}

/// Hand the start surface the keys.
pub fn focus(app: *App) void {
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .welcome;
    app.needs_render = true;
}

// ─── the sources ────────────────────────────────────────────────────────

/// The start surface's shortcut rows, in order, and the command each
/// runs; `startChord` spells each one for the active profile.
pub const start_shortcuts = [_]struct { label: []const u8, command: command.CommandId }{
    .{ .label = "find a file", .command = .@"picker.files" },
    .{ .label = "recent files", .command = .@"picker.recent" },
    .{ .label = "the file tree", .command = .@"view.focus_tree" },
    .{ .label = "toggle the tree", .command = .@"view.toggle_tree" },
    .{ .label = "command palette", .command = .palette },
    .{ .label = "which-key menu", .command = .@"whichkey.leader" },
    .{ .label = "cheatsheet", .command = .@"view.cheatsheet" },
    .{ .label = "settings", .command = .@"view.settings" },
    .{ .label = "new file", .command = .@"file.new" },
    .{ .label = "quit", .command = .@"app.quit" },
};

/// The minimal form's rows — the list the pane had before the start
/// surface, in its `^P` spelling (`minimalChord`).
pub const minimal_shortcuts = [_]struct { label: []const u8, command: command.CommandId }{
    .{ .label = "find file", .command = .@"picker.files" },
    .{ .label = "recent files", .command = .@"picker.recent" },
    .{ .label = "which-key menu", .command = .@"whichkey.leader" },
    .{ .label = "new file", .command = .@"file.new" },
    .{ .label = "toggle tree", .command = .@"view.toggle_tree" },
    .{ .label = "quit", .command = .@"app.quit" },
};

pub const Shortcut = struct { chord: []const u8, label: []const u8, command: command.CommandId };

/// The shortcut rows the shown form lists under the active profile, on
/// `arena`. A row whose command the profile leaves unbound is left out.
pub fn shortcuts(app: *App, arena: Allocator) Allocator.Error![]const Shortcut {
    var out: std.ArrayListUnmanaged(Shortcut) = .empty;
    if (app.cfg.ui.welcome == .minimal) {
        for (minimal_shortcuts) |row| {
            const chord = try minimalChord(app, arena, command.spec(row.command).keys) orelse continue;
            try out.append(arena, .{ .chord = chord, .label = row.label, .command = row.command });
        }
    } else for (start_shortcuts) |row| {
        const chord = try startChord(app, arena, command.spec(row.command).keys) orelse continue;
        try out.append(arena, .{ .chord = chord, .label = row.label, .command = row.command });
    }
    return out.items;
}

/// The chord the start surface shows for `keys` under the active
/// profile, in the copy's spelling (`info_view_copy.chordDisplay`:
/// `Ctrl+P`, `Space f f`). Under vim the profile's own chords come
/// before the shared ones — NvChad's `Ctrl+N` over the shared which-key
/// row `Space t e` — and within a list a leader chord wins (the fewer
/// keys the better), then a single modified chord, then anything else:
/// NvChad's `Space f f`, not the shared `Ctrl+P`. The bare leader beats
/// everything (`Space` over `Space w K`). Under the standard profile the
/// shared ones come first (`Ctrl+P` over its own `Ctrl+O`), as the info
/// view's `chordOf` reads them; a single modified chord wins, then a
/// single key, then a sequence: VS Code's `Ctrl+P`. A which-key row
/// (`space ?`) is not offered there — that profile opens the popup on
/// `Ctrl+K`, not on a leader. Null when the profile binds nothing else.
pub fn startChord(app: *App, arena: Allocator, keys: command.Keys) Allocator.Error!?[]const u8 {
    const vim = App.profileOf(app.input_style) == .vim;
    const lists = if (vim) [_][]const []const u8{ keys.vim, keys.both } else [_][]const []const u8{ keys.both, keys.standard };
    var best: ?[]const u8 = null;
    var best_rank: u32 = std.math.maxInt(u32);
    for (lists, 0..) |list, li| for (list) |spec| {
        var buf: [64]u8 = undefined;
        const norm = keymap.normalizeSpec(spec, &buf) orelse spec;
        const tokens: u32 = @intCast(std.mem.count(u8, norm, " ") + 1);
        const first = norm[0 .. std.mem.indexOfScalar(u8, norm, ' ') orelse norm.len];
        const leader = std.mem.eql(u8, first, "space");
        const modified = std.mem.indexOfScalar(u8, first, '+') != null;
        if (!vim and leader) continue;
        const ranked: u32 = if (vim)
            (if (leader and tokens == 1) 0 else @as(u32, @intCast(li)) * 100 + (if (leader) tokens else if (modified and tokens == 1) 10 else 20 + tokens))
        else
            // The first list wins a tie.
            (if (modified and tokens == 1) 0 else if (tokens == 1) 10 else 20 + tokens) * 2 + @as(u32, @intCast(li));
        if (ranked < best_rank) {
            best_rank = ranked;
            best = try info_copy.chordDisplay(arena, norm);
        }
    };
    return best;
}

/// The minimal form's chord for `keys`, in its `^P` / `SPC` spelling.
/// The shared bindings come before the profile's own (`ctrl+p` over
/// standard's `ctrl+o`); a chord with a modifier comes before a bare
/// key (standard's `ctrl+k` over the shared `space`), and a single
/// chord before a sequence (`SPC` over `SPC w K`).
pub fn minimalChord(app: *App, arena: Allocator, keys: command.Keys) Allocator.Error!?[]const u8 {
    const own = switch (App.profileOf(app.input_style)) {
        .vim => keys.vim,
        .standard => keys.standard,
    };
    const lists = [_][]const []const u8{ keys.both, own };
    var best: ?[]const u8 = null;
    var best_rank: u8 = 3;
    for (lists) |list| for (list) |spec| {
        var buf: [64]u8 = undefined;
        const norm = keymap.normalizeSpec(spec, &buf) orelse spec;
        const sequence = std.mem.indexOfScalar(u8, norm, ' ') != null;
        const modified = std.mem.indexOfScalar(u8, norm, '+') != null;
        const rank: u8 = if (sequence) 2 else if (modified) 0 else 1;
        if (rank < best_rank) {
            best_rank = rank;
            best = try caretDisplay(arena, norm);
        }
    };
    return best;
}

/// `ctrl+p` → `^P`, `space` → `SPC`, a sequence chord by chord.
fn caretDisplay(arena: Allocator, spec: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.splitScalar(u8, spec, ' ');
    var first = true;
    while (it.next()) |chord| {
        if (chord.len == 0) continue;
        if (!first) try out.append(arena, ' ');
        first = false;
        if (chord.len == 6 and std.mem.startsWith(u8, chord, "ctrl+") and std.ascii.isAlphabetic(chord[5])) {
            try out.append(arena, '^');
            try out.append(arena, std.ascii.toUpper(chord[5]));
        } else if (std.mem.eql(u8, chord, "space")) {
            try out.appendSlice(arena, "SPC");
        } else {
            try out.appendSlice(arena, chord);
        }
    }
    return out.items;
}

/// The rows of list `l` as the start surface paints them, on `arena`.
pub fn entries(app: *App, ui: Ui, l: List) Allocator.Error![]const Entry {
    const arena = ui.arena;
    switch (l) {
        .workspaces => {
            const rows = try tree_mod.workspaceRows(app, arena);
            const out = try arena.alloc(Entry, rows.len);
            for (rows, out) |r, *o| o.* = .{ .text = r.name, .detail = if (r.expanded) "open" else "" };
            return out;
        },
        .recent => {
            const paths = try cmd_picker.recentFiles(app, arena);
            const out = try arena.alloc(Entry, paths.len);
            // The name first, its directory as the dim detail — a deep
            // path cut at the right edge left every such row reading the
            // same (the picker does the same).
            for (paths, out) |p, *o| {
                const rel = app.relPath(p);
                const dir = std.fs.path.dirname(rel) orelse "";
                o.* = .{ .text = std.fs.path.basename(rel), .detail = dir };
            }
            return out;
        },
        .sessions => {
            const items = try sessions.resumable(app, arena);
            const out = try arena.alloc(Entry, items.len);
            const now_s = sessions.wallNowS(app);
            for (items, out) |it, *o| o.* = .{
                .text = sessions.itemName(app, it),
                .detail = ui.fmt("{s} · {s}", .{ it.source.label(), list_panel.ageText(ui, now_s, it.last_activity_s) }),
            };
            return out;
        },
        .shortcuts => {
            const rows = try shortcuts(app, arena);
            const out = try arena.alloc(Entry, rows.len);
            var w: u16 = 0;
            for (rows) |r| w = @max(w, ui.width(r.chord));
            for (rows, out) |r, *o| o.* = .{ .lead = r.chord, .lead_w = w, .text = r.label };
            return out;
        },
    }
}

// ─── drawing ────────────────────────────────────────────────────────────

/// Files with tracked changes — what Rust counts from its line diffs;
/// an untracked file is not a changed one.
fn changedFiles(app: *App) u32 {
    const st = app.git.status orelse return 0;
    return st.staged + st.unstaged + st.conflicted;
}

pub fn draw(app: *App, ui: Ui, area: Rect) void {
    if (area.isEmpty()) return;
    const mode = app.cfg.ui.welcome;
    if (mode == .off) return ui.fill(area, ui.theme.bg);
    // The branch row wants the repo the workspace is in or under, and
    // the git state discovers on first use — the welcome pane is that
    // use. A workspace without one is left undiscovered so a `git init`
    // after launch is still found by the GIT panel's own first look.
    if (!app.git.discovered) {
        _ = git_app.requireRepo(app) catch null;
        if (app.git.activeRepo() == null) app.git.discovered = false;
    }
    const arena = ui.arena;
    const workspace = std.fs.path.basename(app.workspace);
    if (mode == .minimal) {
        const rows = shortcuts(app, arena) catch &.{};
        const out: []ui_welcome.Shortcut = arena.alloc(ui_welcome.Shortcut, rows.len) catch &.{};
        for (out, rows[0..out.len]) |*o, r| o.* = .{ .chord = r.chord, .label = r.label };
        return ui_welcome.draw(ui, area, .{
            .workspace = workspace,
            .branch = app.git.headLabel(),
            .changed = changedFiles(app),
            .shortcuts = out,
            .version = update.current,
        });
    }
    // The SESSIONS rows are the section's scan, which runs on its first
    // frame; this is the list's first frame. (Not under `zig build
    // unit`: a test App's environment is the developer's own, and the
    // scan would read their real transcripts.)
    const st = &app.sessions;
    if (!builtin.is_test and !st.scanned_once and !st.scanning) sessions.refresh(app) catch {};
    ui_welcome.drawStart(&app.welcome, ui, area, .{
        .workspace = workspace,
        .branch = app.git.headLabel(),
        .changed = changedFiles(app),
        .workspaces = entries(app, ui, .workspaces) catch &.{},
        .recent = entries(app, ui, .recent) catch &.{},
        .sessions = entries(app, ui, .sessions) catch &.{},
        .shortcuts = entries(app, ui, .shortcuts) catch &.{},
        .version = update.current,
        .focused = app.focus == .welcome,
    });
}

// ─── acting ─────────────────────────────────────────────────────────────

fn runCmd(app: *App, id: command.CommandId) Allocator.Error!void {
    command.run(app, .{ .static = id }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

/// What a row does — Enter on it, or a click.
pub fn act(app: *App, row: hit.WelcomeRow) Allocator.Error!void {
    const arena = app.frame.allocator();
    switch (row.kind) {
        .workspace => {
            const rows = try tree_mod.workspaceRows(app, arena);
            if (row.idx < rows.len) try app.tree.switchTo(app, row.idx);
        },
        .recent => {
            const paths = try cmd_picker.recentFiles(app, arena);
            if (row.idx >= paths.len) return;
            const copy = try arena.dupe(u8, paths[row.idx]);
            _ = app.openPath(copy) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        },
        .session => {
            const items = try sessions.resumable(app, arena);
            if (row.idx >= items.len) return;
            sessions.resumeItem(app, items[row.idx]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        },
        .new_session => try runCmd(app, .@"ai.claude_code_new"),
        .shortcut => {
            const rows = try shortcuts(app, arena);
            if (row.idx < rows.len) try runCmd(app, rows[row.idx].command);
        },
    }
    app.needs_render = true;
}

/// The row the cursor is on in the active list; null on an empty list.
pub fn currentRow(app: *App) ?hit.WelcomeRow {
    const st = &app.welcome;
    const p = st.panel(st.active);
    if (st.active == .sessions and p.on_new) return .{ .kind = .new_session, .idx = 0 };
    if (p.total == 0) return null;
    const idx: u16 = @intCast(@min(p.cursor, std.math.maxInt(u16)));
    return .{ .kind = switch (st.active) {
        .workspaces => .workspace,
        .recent => .recent,
        .sessions => .session,
        .shortcuts => .shortcut,
    }, .idx = idx };
}

/// Put the cursor on `row`, in its list, and make that list the active one.
fn select(app: *App, row: hit.WelcomeRow) void {
    const st = &app.welcome;
    st.active = row.list();
    const p = st.panel(st.active);
    if (row.kind == .new_session) {
        p.on_new = true;
    } else {
        p.on_new = false;
        p.cursor = row.idx;
    }
}

/// Tab / Shift+Tab: the next / previous list on screen, round.
fn step(app: *App, dir: i8) void {
    const st = &app.welcome;
    const n = ui_welcome.lists.len;
    var i: usize = @intFromEnum(st.active);
    var k: usize = 0;
    while (k < n) : (k += 1) {
        i = if (dir > 0) (i + 1) % n else (i + n - 1) % n;
        if (st.shown[i]) {
            st.active = @enumFromInt(i);
            break;
        }
    }
    keepOnNew(st);
}

/// SESSIONS with nothing to resume still has its New row: the cursor
/// sits there rather than on no row at all.
fn keepOnNew(st: *State) void {
    const p = st.panel(.sessions);
    if (st.active == .sessions and p.total == 0) p.on_new = true;
}

pub fn handleKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.welcome;
    const m = k.mods;
    const plain = !m.ctrl and !m.alt and !m.super;
    switch (k.code) {
        // Shift+Tab can arrive either way (`Key.canonical`).
        .tab => {
            if (!plain) return false;
            step(app, if (m.shift) -1 else 1);
        },
        .backtab => step(app, -1),
        .enter => {
            if (!plain) return false;
            const row = currentRow(app) orelse return true;
            try act(app, row);
            return true;
        },
        .esc => {
            if (!app.tree.visible) return false;
            app.focus = .tree;
        },
        .up, .down, .home, .end, .page_up, .page_down => {
            if (!plain) return false;
            _ = try ui_welcome.Panel.handleKey(st.panel(st.active), app.gpa, k);
            keepOnNew(st);
        },
        .char => |c| {
            if (!plain) return false;
            switch (c) {
                '?' => {
                    try runCmd(app, .@"view.cheatsheet");
                    return true;
                },
                'j', 'k', 'g', 'G' => {
                    _ = try ui_welcome.Panel.handleKey(st.panel(st.active), app.gpa, k);
                    keepOnNew(st);
                },
                else => return false,
            }
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

// ─── the pointer ────────────────────────────────────────────────────────

/// A press on a row: the left button acts on it (and, on the start
/// surface, puts the keys and the cursor there); the right one opens a
/// recent file's menu.
pub fn mouse(app: *App, row: hit.WelcomeRow, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    if (m.button == .right) {
        if (row.kind != .recent) return;
        const paths = try cmd_picker.recentFiles(app, app.frame.allocator());
        if (row.idx < paths.len) try context_menus.openWelcomeRecentMenu(app, paths[row.idx], m.x, m.y);
        return;
    }
    if (m.button != .left) return;
    if (full(app)) {
        select(app, row);
        focus(app);
    }
    try act(app, row);
}

/// The wheel over a list: its cursor moves `rows`, and the window with it.
pub fn wheel(app: *App, l: List, down: bool, rows: usize) void {
    const p = app.welcome.panel(l);
    if (p.total == 0) return;
    p.on_new = false;
    p.cursor = if (down) @min(p.cursor + rows, p.total - 1) else p.cursor -| rows;
    app.needs_render = true;
}

/// A press or drag on a list's bar lands its cursor at the pointer's
/// fraction of the track.
pub fn scrollbarMouse(app: *App, l: List, track: Rect, m: Mouse) void {
    const p = app.welcome.panel(l);
    if (p.total == 0 or track.h == 0) return;
    switch (m.kind) {
        .press, .drag => {
            const off: usize = m.y -| track.y;
            p.on_new = false;
            p.cursor = @min(off * p.total / track.h, p.total - 1);
            app.welcome.active = l;
            app.needs_render = true;
        },
        else => {},
    }
}

/// `view.context_menu_at_focus` on the start surface: a recent file's
/// row menu, where the row was painted.
pub fn menuAtFocus(app: *App) command.CommandError!void {
    const arena = app.frame.allocator();
    const row = currentRow(app) orelse return app.diag.fail(arena, "no row under the cursor", .{});
    if (row.kind != .recent) return app.diag.fail(arena, "this row has no menu", .{});
    const paths = try cmd_picker.recentFiles(app, arena);
    if (row.idx >= paths.len) return app.diag.fail(arena, "no row under the cursor", .{});
    var x: u16 = 0;
    var y: u16 = 1;
    for (app.hits.items.items) |e| if (e.target == .welcome and std.meta.eql(e.target.welcome, row)) {
        x = e.rect.x;
        y = e.rect.y;
    };
    try context_menus.openWelcomeRecentMenu(app, paths[row.idx], x, y);
}

// ── tests ──

const t = std.testing;
const screen_mod = @import("../ipc/screen.zig");
const dispatch = @import("dispatch.zig");

fn screenText(app: *App) ![]u8 {
    try app.render();
    return screen_mod.toTestText(t.allocator, &app.screen);
}

const Tmp = struct {
    dir: std.testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",

    /// In place: `root` is a slice of the struct's own buffer.
    fn init(self: *Tmp) !void {
        self.* = .{ .dir = std.testing.tmpDir(.{}) };
        const n = try self.dir.dir.realPath(t.io, &self.buf);
        self.root = self.buf[0..n];
    }
};

/// Every start-surface hit is inside the editor area (right of the
/// sidebar, under the tab strip, above the statusline), and no two of
/// them share a cell — the rect gate at one screen size.
fn expectHitsSound(app: *App) !void {
    const body = app.panes_area;
    var n: usize = 0;
    const items = app.hits.items.items;
    for (items, 0..) |e, i| {
        if (e.target != .welcome) continue;
        n += 1;
        const r = e.rect;
        if (r.x < body.x or r.right() > body.right() or r.y < body.y or r.bottom() > body.bottom()) {
            std.debug.print("welcome hit {any} outside the editor area {any}\n", .{ r, body });
            return error.TestUnexpectedResult;
        }
        for (items[i + 1 ..]) |o| {
            if (o.target != .welcome) continue;
            const ov = r.x < o.rect.right() and o.rect.x < r.right() and r.y < o.rect.bottom() and o.rect.y < r.bottom();
            try t.expect(!ov);
        }
    }
    try t.expect(n > 0);
}

test "welcome: the start surface lays out at 80x24, 120x40 and 200x60 inside the editor area, no hit overlapping another" {
    var tmp: Tmp = undefined;
    try tmp.init();
    defer tmp.dir.cleanup();
    try tmp.dir.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "a\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = tmp.root, .cols = 80, .rows = 24 });
    defer app.deinit();
    const a = try std.fs.path.join(t.allocator, &.{ tmp.root, "a.txt" });
    defer t.allocator.free(a);
    try app.noteRecent(a);
    for ([_][2]u16{ .{ 80, 24 }, .{ 120, 40 }, .{ 200, 60 } }) |size| {
        try app.resize(size[0], size[1]);
        const txt = try screenText(&app);
        defer t.allocator.free(txt);
        try expectHitsSound(&app);
        try t.expect(std.mem.indexOf(u8, txt, "RECENT FILES") != null);
        try t.expect(std.mem.indexOf(u8, txt, "SESSIONS") != null);
        try t.expect(std.mem.indexOf(u8, txt, ui_welcome.new_session_label) != null);
        // The mark needs rows 80x24 does not have. SHORTCUTS needs width:
        // at 80 columns the tree auto-hides (`ui.sidebar_auto_below`), so
        // the surface has the whole width and the list fits at every size.
        const small = size[1] == 24;
        try t.expectEqual(!small, std.mem.indexOf(u8, txt, ui_welcome.mark[1]) != null);
        try t.expect(std.mem.indexOf(u8, txt, "SHORTCUTS") != null);
    }
}

test "welcome: SHORTCUTS reads each profile's chords off the spec table — Space f f under vim, Ctrl+P under standard" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var std_app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer std_app.deinit();
    var cfg: app_mod.Config = .{};
    cfg.editor.input_style = .vim;
    var vim_app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer vim_app.deinit();
    const Want = struct { id: command.CommandId, vim: ?[]const u8, standard: ?[]const u8 };
    const want = [_]Want{
        .{ .id = .@"picker.files", .vim = "Space f f", .standard = "Ctrl+P" },
        .{ .id = .@"picker.recent", .vim = "Space f o", .standard = "Ctrl+R" },
        .{ .id = .@"view.focus_tree", .vim = "Space e", .standard = "Ctrl+Shift+E" },
        .{ .id = .@"view.toggle_tree", .vim = "Ctrl+N", .standard = "Ctrl+B" },
        .{ .id = .@"whichkey.leader", .vim = "Space", .standard = "Ctrl+K" },
        .{ .id = .@"view.cheatsheet", .vim = "Space c h", .standard = null },
        .{ .id = .@"file.new", .vim = null, .standard = "Ctrl+N" },
        .{ .id = .@"app.quit", .vim = "Ctrl+Q", .standard = "Ctrl+Q" },
    };
    const std_rows = try shortcuts(&std_app, a);
    const vim_rows = try shortcuts(&vim_app, a);
    for (want) |w| {
        inline for (.{ "vim", "standard" }) |which| {
            const rows = if (comptime std.mem.eql(u8, which, "vim")) vim_rows else std_rows;
            const expected = @field(w, which);
            var found: ?[]const u8 = null;
            for (rows) |r| if (r.command == w.id) {
                found = r.chord;
            };
            if (expected) |e| {
                try t.expectEqualStrings(e, found orelse return error.TestUnexpectedResult);
            } else try t.expect(found == null);
        }
    }
    // The frame paints vim's column.
    const txt = try screenText(&vim_app);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "Space f f") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Space c h") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Ctrl+P") == null);
}

test "welcome: the keys — view.focus_pane hands them over, j walks RECENT FILES, Tab steps lists, Enter opens the file" {
    var tmp: Tmp = undefined;
    try tmp.init();
    defer tmp.dir.cleanup();
    try tmp.dir.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "alpha text\n" });
    try tmp.dir.dir.writeFile(t.io, .{ .sub_path = "b.txt", .data = "beta text\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = tmp.root, .cols = 120, .rows = 40 });
    defer app.deinit();
    for ([_][]const u8{ "a.txt", "b.txt" }) |name| {
        const p = try std.fs.path.join(t.allocator, &.{ tmp.root, name });
        defer t.allocator.free(p);
        try app.noteRecent(p);
    }
    const before = try screenText(&app);
    defer t.allocator.free(before);
    try t.expect(app.focus == .tree);
    try command.run(&app, .{ .static = .@"view.focus_pane" });
    try t.expect(app.focus == .welcome);
    try t.expectEqual(List.recent, app.welcome.active);
    // b.txt was opened last: it heads the list; j is a.txt.
    try dispatch.key(&app, Key.char('j'));
    try t.expectEqual(@as(usize, 1), app.welcome.panel(.recent).cursor);
    // Tab: SESSIONS, whose one row is New; Shift+Tab back; Tab twice more is SHORTCUTS.
    try dispatch.key(&app, Key.named(.tab));
    try t.expectEqual(List.sessions, app.welcome.active);
    try t.expect(app.welcome.panel(.sessions).on_new);
    try t.expectEqual(hit.WelcomeRow{ .kind = .new_session, .idx = 0 }, currentRow(&app).?);
    try dispatch.key(&app, Key.named(.tab));
    try t.expectEqual(List.shortcuts, app.welcome.active);
    try dispatch.key(&app, Key.named(.tab));
    try t.expectEqual(List.workspaces, app.welcome.active);
    try dispatch.key(&app, Key.named(.backtab));
    try dispatch.key(&app, Key.named(.backtab));
    try dispatch.key(&app, Key.named(.backtab));
    try t.expectEqual(List.recent, app.welcome.active);
    const mid = try screenText(&app);
    defer t.allocator.free(mid);
    try t.expect(std.mem.indexOf(u8, mid, "START") != null);
    try dispatch.key(&app, Key.named(.enter));
    const e = app.activeEditor() orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.endsWith(u8, e.buf.doc.path.?, "a.txt"));
    const after = try screenText(&app);
    defer t.allocator.free(after);
    try t.expect(std.mem.indexOf(u8, after, "alpha text") != null);
    try t.expect(std.mem.indexOf(u8, after, "RECENT FILES") == null);
    try t.expect(app.focus == .pane);
}

test "welcome: a click on a row acts and puts the keys and the cursor there; the wheel walks a list" {
    var tmp: Tmp = undefined;
    try tmp.init();
    defer tmp.dir.cleanup();
    try tmp.dir.dir.writeFile(t.io, .{ .sub_path = "r.txt", .data = "recent text\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = tmp.root, .cols = 120, .rows = 40 });
    defer app.deinit();
    const r = try std.fs.path.join(t.allocator, &.{ tmp.root, "r.txt" });
    defer t.allocator.free(r);
    try app.noteRecent(r);
    const before = try screenText(&app);
    defer t.allocator.free(before);
    var toggle: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .welcome) {
        const w = h.target.welcome;
        if (w.kind == .shortcut) {
            const rows = try shortcuts(&app, app.frame.allocator());
            if (rows[w.idx].command == .@"view.toggle_tree") toggle = h.rect;
        }
    };
    // A press on the toggle-the-tree row runs it — and the keys stay here.
    try t.expect(app.tree.visible);
    try dispatch.mouse(&app, .{ .x = toggle.?.x + 3, .y = toggle.?.y, .kind = .press, .button = .left }, 1);
    try t.expect(!app.tree.visible);
    try t.expect(app.focus == .welcome);
    try t.expectEqual(List.shortcuts, app.welcome.active);
    // The wheel over SHORTCUTS walks its cursor.
    const txt = try screenText(&app);
    defer t.allocator.free(txt);
    var sc: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .welcome and h.target.welcome.kind == .shortcut and h.target.welcome.idx == 0) {
        sc = h.rect;
    };
    const c0 = app.welcome.panel(.shortcuts).cursor;
    try dispatch.mouse(&app, .{ .x = sc.?.x + 2, .y = sc.?.y, .kind = .scroll_down }, 1);
    try t.expect(app.welcome.panel(.shortcuts).cursor > c0);
    // The pane spans the screen now: the recent row moved; a press opens it.
    var moved: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .welcome and h.target.welcome.kind == .recent) {
        moved = h.rect;
    };
    try dispatch.mouse(&app, .{ .x = moved.?.x + 2, .y = moved.?.y, .kind = .press, .button = .left }, 1);
    const e = app.activeEditor() orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.endsWith(u8, e.buf.doc.path.?, "r.txt"));
}

test "welcome: SESSIONS lists this workspace's resumable sessions, newest first, and none a process still holds" {
    var tmp: Tmp = undefined;
    try tmp.init();
    defer tmp.dir.cleanup();
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = tmp.root, .cols = 120, .rows = 40 });
    defer app.deinit();
    const ws = std.fs.path.basename(tmp.root);
    var rows = [_]sessions.Item{
        sessions.testItem("e2e00000-0000-4000-8000-00000000000a", .idle, 1_000, ws, "older prompt"),
        sessions.testItem("e2e00000-0000-4000-8000-00000000000b", .idle, 2_000, ws, "newer prompt"),
        sessions.testItem("e2e00000-0000-4000-8000-00000000000c", .idle, 3_000, "elsewhere", "another workspace"),
        sessions.testItem("e2e00000-0000-4000-8000-00000000000d", .streaming, 4_000, ws, "still running"),
    };
    rows[3].pid = 4242;
    app.sessions.items = &rows;
    app.sessions.scanned_once = true;
    const got = try sessions.resumable(&app, app.frame.allocator());
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("newer prompt", got[0].last_user_msg.?);
    const txt = try screenText(&app);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "newer prompt") != null);
    try t.expect(std.mem.indexOf(u8, txt, "older prompt") != null);
    try t.expect(std.mem.indexOf(u8, txt, "another workspace") == null);
    try t.expect(std.mem.indexOf(u8, txt, "still running") == null);
    var n: usize = 0;
    for (app.hits.items.items) |h| if (h.target == .welcome and h.target.welcome.kind == .session) {
        n += 1;
    };
    try t.expectEqual(@as(usize, 2), n);
    app.sessions.items = &.{};
}

test "welcome: ui.welcome = minimal is the logo and today's shortcut list; off is the bare ground" {
    var cfg: app_mod.Config = .{};
    cfg.ui.welcome = .minimal;
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    const txt = try screenText(&app);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "^P     find file") != null);
    try t.expect(std.mem.indexOf(u8, txt, ui_welcome.logo[2]) != null);
    try t.expect(std.mem.indexOf(u8, txt, "RECENT FILES") == null);
    // No lists, so the keys stay where they were.
    try t.expect(!takesKeys(&app));
    app.cfg.ui.welcome = .off;
    const off = try screenText(&app);
    defer t.allocator.free(off);
    try t.expect(std.mem.indexOf(u8, off, "find file") == null);
    try t.expect(std.mem.indexOf(u8, off, "workspace · ") == null);
    try t.expect(!shown(&app));
}
