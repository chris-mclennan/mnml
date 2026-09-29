//! The hover-help dictionary — what the info view says about a thing
//! the pointer rests on, curated (Rust `ui/info_view_copy.rs`).
//!
//! An `Entry` is data: a title, a body of two to four sentences that
//! say what THIS control is in THIS state, what a click and the keys
//! do, and the one caveat a user hits — never the label restated. Its
//! `keys` name commands, not chords: the chord is read off the keymap
//! under the active profile when the entry is shown, so a rebind moves
//! the copy with it and a shortcut can never name a binding that is
//! not there. Its `links` are typed — a `CommandId` (a wrong id is a
//! compile error), a Settings row by its config path (a wrong path is
//! a compile error, `settingsRow`), a web page, or `Ask about this`,
//! which sends a prompt carrying the target's state to the AI session.
//!
//! The dictionary is split by area under `info_view_copy/`; `lookup`
//! is the one switch that maps a `HitTarget` to an area. The ladder
//! (`app/info_view.zig`) reads `lookup` BEFORE `discovery.describe`,
//! and marks a fallback on screen, so a control without an entry is
//! visible in the app and not only in `zig build hover-audit`
//! (`app/info_view_audit.zig`), which enumerates every target the app
//! can produce and fails on a new one without an entry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandId = command.CommandId;
const hit_mod = @import("../ui/hit.zig");
const HitTarget = hit_mod.HitTarget;
const view = @import("../ui/info_view.zig");
const settings = @import("settings.zig");
const ai_app = @import("ai.zig");
const docs = @import("docs.zig");
const Config = @import("../config/root.zig").Config;

pub const statusline = @import("info_view_copy/statusline.zig");
pub const rail = @import("info_view_copy/rail.zig");
pub const chrome = @import("info_view_copy/chrome.zig");
pub const dock = @import("info_view_copy/dock.zig");
pub const settings_copy = @import("info_view_copy/settings.zig");
pub const menus = @import("info_view_copy/menus.zig");
pub const overlays = @import("info_view_copy/overlays.zig");
pub const panels = @import("info_view_copy/panels.zig");
pub const editor = @import("info_view_copy/editor.zig");
pub const git_graph = @import("info_view_copy/git_graph.zig");
pub const tree = @import("info_view_copy/tree.zig");

// ─── the shape of an entry ──────────────────────────────────────────────

/// A shortcut row. `command` is the normal form — the chord shown is
/// the active profile's binding, and an unbound command's row is
/// dropped rather than lie. `chord` is for keys that are not commands
/// (a list's Enter, an overlay's Esc): the lint keeps those to the
/// small set `literal_chords` names.
pub const Key = struct {
    command: ?CommandId = null,
    chord: []const u8 = "",
    label: []const u8,
};

/// The literal chords an entry may spell without a command behind
/// them — the keys lists and overlays answer themselves.
pub const literal_chords = [_][]const u8{ "Enter", "Esc", "Space", "Tab", "→ / ←", "↑ / ↓", "←→", "↑↓", "j / k", "h / l", "j k", "h l", "r", "R", "/", "Ctrl+Enter", "Shift+Enter", "Ctrl+F", "Ctrl+R", "Alt+click", "Double-click", "Middle-click", "Drag", "Wheel", "Right-click", "q", "y", "n", "N", "s", "d", "c", "a", "?" };

pub const Link = union(enum) {
    command: struct { id: CommandId, label: []const u8 },
    /// An index into `settings.rows` — build it with `settingsRow`.
    settings: struct { row: u16, label: []const u8 },
    url: struct { url: []const u8, label: []const u8 },
    /// The label; the prompt is built from the target when clicked
    /// (`askPrompt`), so it carries the state of that moment.
    ask: []const u8,
    /// A section of the embedded manual (`app/docs.zig`), opened as a
    /// markdown preview — build it with `docsSection`.
    docs: struct { doc: docs.Doc, section: []const u8, label: []const u8 },
};

pub const Entry = struct {
    title: []const u8,
    body: []const u8 = "",
    aside: ?[]const u8 = null,
    keys: []const Key = &.{},
    links: []const Link = &.{},
};

/// The row index of a Settings row by its config path — a path the
/// table does not have is a compile error, so a link cannot rot.
pub fn settingsRow(comptime path: []const u8) u16 {
    return comptime blk: {
        @setEvalBranchQuota(20_000);
        for (settings.rows, 0..) |r, i| if (std.mem.eql(u8, r.path, path)) break :blk @as(u16, @intCast(i));
        @compileError("info_view_copy: no Settings row for `" ++ path ++ "`");
    };
}

/// A section of the embedded manual — `docsSection("The launcher
/// dock")` names it by its heading; the lint reports a heading the
/// manual does not have.
pub fn docsSection(comptime name: []const u8) Link {
    return .{ .docs = .{ .doc = .config, .section = name, .label = "The manual: " ++ name } };
}

/// `Ask about this`, the way most entries spell it.
pub const ask_link: Link = .{ .ask = "Ask Claude about this" };

// ─── the lookup ─────────────────────────────────────────────────────────

/// The curated entry for `target`, or null when the dictionary has
/// nothing — the ladder then falls to `discovery.describe`.
pub fn lookup(app: *App, arena: Allocator, target: HitTarget) Allocator.Error!?Entry {
    return switch (target) {
        .statusline_seg => |seg| try statusline.entry(app, arena, seg),
        .tip_row => |r| try statusline.entry(app, arena, r.seg),
        .rail => |part| try rail.entry(app, arena, part),
        .button => |id| try chrome.button(app, arena, id),
        .tab => |tb| try chrome.tab(app, arena, tb),
        .tab_close => chrome.tabClose(),
        .breadcrumb => |bc| try chrome.breadcrumb(app, arena, bc.pane, bc.idx),
        .divider => |id| chrome.divider(id),
        .scrollbar => |s| chrome.scrollbar(s),
        .hover_popup => chrome.hoverPopup(),
        .pane => |id| try chrome.pane(app, arena, id),
        .launcher_dock => |part| try dock.launcher(app, arena, part),
        .dock => |d| try dock.widget(app, arena, d.id, d.part),
        .overlay_item => |id| try overlays.entry(app, arena, id),
        .menu_item => |mi| try menus.entry(app, arena, mi.menu, mi.idx),
        .chip => |c| panels.chip(c.panel, c.kind),
        .row => |r| try panels.row(app, arena, r),
        .kebab => |r| panels.kebab(r),
        .filter_input => |p| panels.filter(p),
        .search_chip => |f| panels.searchChip(f),
        .http => |part| panels.http(part),
        .git_palette => |part| panels.gitPalette(part),
        .font_update => panels.fontUpdate(),
        .ai_placeholder => panels.aiPlaceholder(),
        .session_changes => panels.sessionChangesChip(),
        .welcome => |w| panels.welcome(w),
        .script_hit => |sh| try panels.scriptHit(app, arena, sh.pane, sh.id),
        .link => |l| try panels.link(arena, l.url),
        .info_view => |part| panels.infoView(part),
        .tree_root => |r| try tree.root(app, arena, r),
        .tree_empty => tree.empty(),
        .tree_chip => |c| tree.chip(c),
        .tree_node => |idx| try tree.node(app, arena, idx),
        .editor_cell => |cell| try editor.cell(app, arena, cell.pane, cell.line, cell.col),
        .gutter => |g| try editor.gutter(app, arena, g),
        .fold_arrow => |g| try editor.foldArrow(app, arena, g),
    };
}

// ─── materializing an entry for the painter ─────────────────────────────

/// What a link row does — kept by the app by position, so a press on
/// row `i` can act after the frame that painted it is gone. Every
/// slice here is a comptime literal from the dictionary (a URL); the
/// `ask` prompt is built at press time from the target, never stored.
pub const LinkAction = union(enum) {
    command: CommandId,
    settings: u16,
    url: []const u8,
    ask,
    docs: struct { doc: docs.Doc, section: []const u8 },
};

pub const max_links = 3;
/// The shortcut rows whose command the keyboard can run (`help.focus`'s
/// Enter); a row past these is shown and walked but runs nothing.
pub const max_keys = 8;

pub const Materialized = struct {
    copy: view.Copy,
    actions: [max_links]?LinkAction,
    /// The command behind each `[chord] label` row, by position; null
    /// for a gesture row (`Wheel`, `Drag`) that names no command.
    keys: [max_keys]?CommandId = @splat(null),
};

/// The painter's `Copy` for `entry` under the active profile: every
/// command-backed key with a binding becomes a `[chord] label` row, an
/// unbound one is dropped; the links become `→` rows, the `ask` link
/// gated on the AI route — when Claude is routed off the row becomes a
/// Settings link to the backend row, so it says why instead of failing
/// on the click.
pub fn materialize(app: *App, arena: Allocator, entry: Entry) Allocator.Error!Materialized {
    var out: Materialized = .{ .copy = .{ .title = entry.title, .body = entry.body, .aside = entry.aside }, .actions = @splat(null) };
    var shortcuts: std.ArrayListUnmanaged(view.Shortcut) = .empty;
    for (entry.keys) |k| {
        if (k.command) |id| {
            const chord = (try chordOf(app, arena, id)) orelse continue;
            if (shortcuts.items.len < max_keys) out.keys[shortcuts.items.len] = id;
            try shortcuts.append(arena, .{ .chord = chord, .label = k.label });
        } else if (k.chord.len > 0) {
            try shortcuts.append(arena, .{ .chord = k.chord, .label = k.label });
        }
    }
    out.copy.shortcuts = shortcuts.items;
    var links: std.ArrayListUnmanaged(view.Link) = .empty;
    for (entry.links) |l| {
        if (links.items.len == max_links) break;
        const i = links.items.len;
        switch (l) {
            .command => |c| {
                out.actions[i] = .{ .command = c.id };
                try links.append(arena, .{ .label = c.label, .kind = .command });
            },
            .settings => |s| {
                out.actions[i] = .{ .settings = s.row };
                try links.append(arena, .{ .label = s.label, .kind = .settings });
            },
            .url => |u| {
                out.actions[i] = .{ .url = u.url };
                try links.append(arena, .{ .label = u.label, .kind = .url });
            },
            .docs => |d| {
                out.actions[i] = .{ .docs = .{ .doc = d.doc, .section = d.section } };
                try links.append(arena, .{ .label = d.label, .kind = .docs });
            },
            .ask => |label| if (ai_app.route(app, .claude) == .off) {
                out.actions[i] = .{ .settings = settingsRow("ai.routing.claude.backend") };
                try links.append(arena, .{ .label = "Ask about this — AI is off; turn it on", .kind = .settings });
            } else {
                out.actions[i] = .ask;
                try links.append(arena, .{ .label = label, .kind = .ask });
            },
        }
    }
    out.copy.try_it = links.items;
    return out;
}

/// The chord the copy shows for `id` under the active profile, spelled
/// for prose: `g d` → `gd`, `f12` → `F12`, `ctrl+k ctrl+i` → `Ctrl+K
/// Ctrl+I`. The vim profile's own chords come before the shared ones
/// (`gd` over `F12`, the idiom a vim user knows); the standard profile
/// reads the shared ones first (`Ctrl+P` over its own `Ctrl+O`), but a
/// which-key row (`space l h`) only when the command has no chord of
/// its own — VS Code's `Ctrl+K Ctrl+I`, not the popup's path.
pub fn chordOf(app: *const App, arena: Allocator, id: CommandId) Allocator.Error!?[]const u8 {
    const keys = command.spec(id).keys;
    const lists: [3][]const []const u8 = switch (App.profileOf(app.input_style)) {
        .vim => .{ keys.vim, keys.both, keys.vim_handler },
        .standard => .{ keys.both, keys.standard, &.{} },
    };
    const standard = App.profileOf(app.input_style) == .standard;
    for (lists) |list| for (list) |spec| {
        if (standard and isLeaderChord(spec)) continue;
        return try chordDisplay(arena, spec);
    };
    for (lists) |list| if (list.len > 0) return try chordDisplay(arena, list[0]);
    return null;
}

/// `space …`: a which-key row, not a chord of its own.
fn isLeaderChord(spec: []const u8) bool {
    return std.mem.startsWith(u8, spec, "space ");
}

/// A key spec in the copy's spelling.
pub fn chordDisplay(arena: Allocator, spec: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    // A run of bare keys (`g d`) reads as one word; anything with a
    // modifier keeps a space between chords.
    var bare_run = true;
    var probe = std.mem.splitScalar(u8, spec, ' ');
    while (probe.next()) |c| if (c.len != 1) {
        bare_run = false;
    };
    var it = std.mem.splitScalar(u8, spec, ' ');
    var first = true;
    while (it.next()) |chord| {
        if (chord.len == 0) continue;
        if (!first and !bare_run) try out.append(arena, ' ');
        first = false;
        var parts = std.mem.splitScalar(u8, chord, '+');
        var first_part = true;
        var modified = false;
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            if (!first_part) try out.append(arena, '+');
            first_part = false;
            const is_mod = std.mem.eql(u8, part, "ctrl") or std.mem.eql(u8, part, "shift") or std.mem.eql(u8, part, "alt") or std.mem.eql(u8, part, "super");
            if (is_mod) modified = true;
            const named = is_mod or (part.len > 1 and (part[0] == 'f' and std.ascii.isDigit(part[1]))) or std.mem.eql(u8, part, "space") or std.mem.eql(u8, part, "enter") or std.mem.eql(u8, part, "esc") or std.mem.eql(u8, part, "tab");
            if (named) {
                try out.append(arena, std.ascii.toUpper(part[0]));
                try out.appendSlice(arena, part[1..]);
            } else if (part.len == 1 and modified) {
                try out.append(arena, std.ascii.toUpper(part[0]));
            } else try out.appendSlice(arena, part);
        }
    }
    return out.items;
}

/// `[chord] label · [chord] label …` — each command's chord under the
/// active profile in the copy's spelling; a command the profile leaves
/// unbound contributes its label alone.
pub fn chordLine(app: *const App, arena: Allocator, rows: []const Key) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (rows, 0..) |row, i| {
        if (i > 0) try out.appendSlice(arena, " \u{00B7} ");
        if (row.command) |id| if (try chordOf(app, arena, id)) |c| {
            try out.append(arena, '[');
            try out.appendSlice(arena, c);
            try out.appendSlice(arena, "] ");
        };
        try out.appendSlice(arena, row.label);
    }
    return out.items;
}

// ─── Ask about this ─────────────────────────────────────────────────────

/// The prompt an `ask` link sends: the entry's own words as the
/// framing, then the target's state — the diagnostics, the branch and
/// its dirty files, the unread messages, the config key and its
/// value, the command and its binding — so the answer is about the
/// user's situation, not a definition. Each area contributes its
/// `askContext`; a target with none gets the framing alone.
pub fn askPrompt(app: *App, arena: Allocator, target: HitTarget, entry: Entry) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.print(arena, "I am using the mnml editor (Zig build) and hovering \"{s}\" in its UI. The editor's own help for it says:\n\n{s}\n", .{ entry.title, entry.body });
    if (entry.aside) |a| try out.print(arena, "{s}\n", .{a});
    const ctx: ?[]const u8 = switch (target) {
        .statusline_seg => |seg| try statusline.askContext(app, arena, seg),
        .tip_row => |r| try statusline.askContext(app, arena, r.seg),
        .overlay_item => |id| try overlays.askContext(app, arena, id),
        .menu_item => |mi| try menus.askContext(app, arena, mi.menu, mi.idx),
        .button => |id| try chrome.askContext(app, arena, id),
        .launcher_dock => |part| try dock.askContext(app, arena, part),
        .editor_cell, .gutter, .fold_arrow => try editor.askContext(app, arena, target),
        .row => |r| try panels.askContext(app, arena, r),
        .rail => |part| try rail.askContext(app, arena, part),
        else => null,
    };
    if (ctx) |c| try out.print(arena, "\nThe current state:\n{s}\n", .{c});
    try out.appendSlice(arena, "\nExplain what this means for me right now and what I should do next. Be concrete and short; if something is wrong, say how to fix it.");
    return out.items;
}

/// Send the prompt for `target` to a Claude session (`ai.ask`). The
/// route is checked by `materialize`, so a press here has a backend;
/// what can still fail (no binary, no key) toasts through `ai.ask`.
pub fn ask(app: *App, arena: Allocator, target: HitTarget, entry: Entry) Allocator.Error!void {
    const prompt = try askPrompt(app, arena, target, entry);
    const title = try std.fmt.allocPrint(arena, "ai: {s}", .{entry.title});
    _ = ai_app.ask(app, title, prompt, .ask, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

// ─── the lint ───────────────────────────────────────────────────────────

pub const Problem = struct {
    entry: []const u8,
    what: []const u8,
};

/// What is wrong with `entry`: a command-backed key whose command has
/// no binding in either profile (the row would never paint — the
/// copy names a chord that does not exist), a literal chord outside
/// `literal_chords`, an empty body, a title that is a bare restatement
/// of nothing, a docs link to a heading the manual does not have.
/// Command and Settings links are checked by the compiler.
pub fn lint(arena: Allocator, entry: Entry, out: *std.ArrayListUnmanaged(Problem)) Allocator.Error!void {
    if (entry.title.len == 0) try out.append(arena, .{ .entry = "?", .what = "empty title" });
    if (entry.body.len < 40) try out.append(arena, .{ .entry = entry.title, .what = "body under 40 characters — say what it is, what a click does, the caveat" });
    for (entry.keys) |k| {
        if (k.command) |id| {
            const keys = command.spec(id).keys;
            if (keys.vim.len + keys.standard.len + keys.both.len + keys.vim_handler.len == 0) try out.append(arena, .{ .entry = entry.title, .what = try std.fmt.allocPrint(arena, "key names `{s}`, which no profile binds", .{command.name(id)}) });
        } else {
            const ok = for (literal_chords) |c| {
                if (std.mem.eql(u8, c, k.chord)) break true;
            } else false;
            if (!ok) try out.append(arena, .{ .entry = entry.title, .what = try std.fmt.allocPrint(arena, "literal chord `{s}` is not in literal_chords — name the command instead", .{k.chord}) });
        }
    }
    for ([_][]const u8{ entry.body, entry.aside orelse "" }) |prose| try lintProse(arena, entry.title, prose, out);
    if (entry.links.len > max_links) try out.append(arena, .{ .entry = entry.title, .what = "more links than the box shows" });
    for (entry.links) |l| if (l == .docs) if (docs.section(l.docs.doc, l.docs.section) == null) try out.append(arena, .{ .entry = entry.title, .what = try std.fmt.allocPrint(arena, "docs link names `{s}`, which {s} has no heading for", .{ l.docs.section, l.docs.doc.file() }) });
}

/// The prose half of the lint: a backticked dotted name in the body or
/// the aside (`view.toggle_wrap`, `ui.wheel_lines`) whose first word is
/// a command group or a config section must resolve — as a command id
/// or a config path (a Settings row counts). Prose is where a rename goes unnoticed: the typed
/// `keys` and `links` are checked by the compiler, a sentence is not.
fn lintProse(arena: Allocator, title: []const u8, prose: []const u8, out: *std.ArrayListUnmanaged(Problem)) Allocator.Error!void {
    var it = std.mem.splitScalar(u8, prose, '`');
    _ = it.next();
    while (it.next()) |span| {
        defer _ = it.next(); // the text after the closing backtick
        if (!dottedName(span)) continue;
        const head = span[0..std.mem.indexOfScalar(u8, span, '.').?];
        if (!isCommandGroup(head) and !configHas(Config, head)) continue;
        if (command.by_name.get(span) != null or configHas(Config, span) or isSettingsPath(span)) continue;
        try out.append(arena, .{ .entry = title, .what = try std.fmt.allocPrint(arena, "prose names `{s}`, which is neither a command id nor a config path", .{span}) });
    }
}

/// `word.word[.word…]` of lower-case letters, digits and `_` — the shape
/// of a command id and a config path, and not of a file (`req-N.http`,
/// `.mnml/…`) or an expression.
fn dottedName(span: []const u8) bool {
    if (span.len < 3 or span[0] == '.' or span[span.len - 1] == '.') return false;
    var dots: usize = 0;
    for (span) |c| switch (c) {
        'a'...'z', '0'...'9', '_' => {},
        '.' => dots += 1,
        else => return false,
    };
    return dots > 0 and std.mem.indexOf(u8, span, "..") == null;
}

/// A Settings row's path — `ai.suggest_backend` is one without a typed
/// field behind it (it lives in `ai.extra`).
fn isSettingsPath(path: []const u8) bool {
    for (settings.rows) |r| if (std.mem.eql(u8, r.path, path)) return true;
    return false;
}

fn isCommandGroup(head: []const u8) bool {
    for (std.enums.values(CommandId)) |id| if (std.mem.eql(u8, command.group(id), head)) return true;
    return false;
}

/// Whether the dotted `path` names a field of `T`. A keyed table (a
/// `Map`, the `Dynamic` blocks) takes any key under it.
fn configHas(comptime T: type, path: []const u8) bool {
    const head = path[0 .. std.mem.indexOfScalar(u8, path, '.') orelse path.len];
    const rest: ?[]const u8 = if (head.len == path.len) null else path[head.len + 1 ..];
    switch (@typeInfo(T)) {
        .optional => |o| return configHas(o.child, path),
        .@"struct" => |st| {
            if (@hasDecl(T, "get") and @hasDecl(T, "put")) return true;
            inline for (st.fields) |f| if (std.mem.eql(u8, f.name, head)) {
                const r = rest orelse return true;
                return configHas(f.type, r);
            };
            return false;
        },
        .@"union" => return @hasDecl(T, "get"),
        else => return false,
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "settingsRow resolves a path at comptime" {
    try t.expectEqual(@as(u16, 0), settingsRow("ui.line_numbers"));
    try t.expect(settingsRow("ui.hover_help") > 0);
}

test "the lint can fail: a key on an unbound command, a chord outside the literal set, a thin body" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    // A deliberately bad entry: `app.restart` has no chord in any
    // profile, `Ctrl+Shift+Alt+Q` is not a literal the lint allows,
    // and the body is a label restated.
    const bad: Entry = .{
        .title = "Bad entry",
        .body = "Opens more rows.",
        .keys = &.{ .{ .command = .@"app.restart", .label = "Restart" }, .{ .chord = "Ctrl+Shift+Alt+Q", .label = "Nope" } },
    };
    try lint(a, bad, &problems);
    try t.expectEqual(@as(usize, 3), problems.items.len);
    try t.expect(std.mem.indexOf(u8, problems.items[0].what, "under 40") != null);
    try t.expect(std.mem.indexOf(u8, problems.items[1].what, "app.restart") != null);
    try t.expect(std.mem.indexOf(u8, problems.items[2].what, "Ctrl+Shift+Alt+Q") != null);
    // A docs link to a heading the manual does not have.
    problems.clearRetainingCapacity();
    try lint(a, .{ .title = "Bad docs link", .body = "A body long enough for the lint to be quiet about it, which is forty characters.", .links = &.{comptime docsSection("No such heading")} }, &problems);
    try t.expectEqual(@as(usize, 1), problems.items.len);
    try t.expect(std.mem.indexOf(u8, problems.items[0].what, "No such heading") != null);
    try t.expect(std.mem.indexOf(u8, problems.items[0].what, "CONFIG.md") != null);
    // Prose naming a command id or a config path that does not exist;
    // a file name, a real id and a real path in the same prose are quiet.
    problems.clearRetainingCapacity();
    try lint(a, .{ .title = "Bad prose", .body = "Runs `view.no_such_command`; `ui.no_such_setting` sets it. `req-N.http`, `view.toggle_wrap` and `ui.wheel_lines` are fine.", .aside = "`editor.gone_away` too" }, &problems);
    try t.expectEqual(@as(usize, 3), problems.items.len);
    try t.expect(std.mem.indexOf(u8, problems.items[0].what, "view.no_such_command") != null);
    try t.expect(std.mem.indexOf(u8, problems.items[1].what, "ui.no_such_setting") != null);
    try t.expect(std.mem.indexOf(u8, problems.items[2].what, "editor.gone_away") != null);
    // A good one passes clean.
    problems.clearRetainingCapacity();
    const good: Entry = .{
        .title = "Good entry",
        .body = "A body that says what the control is, what a click does and the one caveat a user hits.",
        .keys = &.{ .{ .command = .@"app.quit", .label = "Quit" }, .{ .chord = "Enter", .label = "Open" } },
        .links = &.{ .{ .command = .{ .id = .@"app.quit", .label = "Quit" } }, ask_link, comptime docsSection("The launcher dock") },
    };
    try lint(a, good, &problems);
    try t.expectEqual(@as(usize, 0), problems.items.len);
}

test "materialize: a command key becomes the profile's chord, an unbound one is dropped, the links keep their kinds and actions" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 30 });
    defer app.deinit();
    const a = app.frame.allocator();
    const e: Entry = .{
        .title = "T",
        .body = "A body long enough for the lint to be quiet about it, which is forty characters.",
        .keys = &.{ .{ .command = .@"picker.files", .label = "Files" }, .{ .command = .@"app.restart", .label = "Restart" }, .{ .chord = "Enter", .label = "Open" } },
        .links = &.{ .{ .command = .{ .id = .@"app.quit", .label = "Quit" } }, .{ .settings = .{ .row = settingsRow("ui.hover_help"), .label = "Hover help" } }, .{ .url = .{ .url = "https://mnml.sh/", .label = "Manual" } } },
    };
    const m = try materialize(&app, a, e);
    try t.expectEqual(@as(usize, 2), m.copy.shortcuts.len);
    try t.expectEqualStrings("Ctrl+P", m.copy.shortcuts[0].chord);
    try t.expectEqualStrings("Enter", m.copy.shortcuts[1].chord);
    try t.expectEqual(@as(usize, 3), m.copy.try_it.len);
    try t.expectEqual(view.LinkKind.command, m.copy.try_it[0].kind);
    try t.expectEqual(view.LinkKind.settings, m.copy.try_it[1].kind);
    try t.expectEqual(view.LinkKind.url, m.copy.try_it[2].kind);
    try t.expectEqual(CommandId.@"app.quit", m.actions[0].?.command);
    try t.expectEqual(settingsRow("ui.hover_help"), m.actions[1].?.settings);
    try t.expectEqualStrings("https://mnml.sh/", m.actions[2].?.url);
    // The ask link: an `ask` action when Claude is routed, a Settings
    // link that says why when it is off.
    const asked = try materialize(&app, a, .{ .title = "T", .links = &.{ask_link} });
    try t.expect(asked.actions[0].? == .ask);
    try t.expectEqual(view.LinkKind.ask, asked.copy.try_it[0].kind);
    app.cfg.ai.backend = .off;
    const off = try materialize(&app, a, .{ .title = "T", .links = &.{ask_link} });
    try t.expect(off.actions[0].? == .settings);
    try t.expect(std.mem.indexOf(u8, off.copy.try_it[0].label, "AI is off") != null);
    // A docs link: the section by name, the `§` kind.
    const manual = try materialize(&app, a, .{ .title = "T", .links = &.{comptime docsSection("Workspace trust")} });
    try t.expectEqual(view.LinkKind.docs, manual.copy.try_it[0].kind);
    try t.expectEqualStrings("The manual: Workspace trust", manual.copy.try_it[0].label);
    try t.expectEqualStrings("Workspace trust", manual.actions[0].?.docs.section);
}

test "chordDisplay spells a spec for prose; chordOf reads the active profile" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqualStrings("gd", try chordDisplay(a, "g d"));
    try t.expectEqualStrings("K", try chordDisplay(a, "K"));
    try t.expectEqualStrings("F12", try chordDisplay(a, "f12"));
    try t.expectEqualStrings("Shift+F12", try chordDisplay(a, "shift+f12"));
    try t.expectEqualStrings("Ctrl+K Ctrl+I", try chordDisplay(a, "ctrl+k ctrl+i"));
    try t.expectEqualStrings("Ctrl+.", try chordDisplay(a, "ctrl+."));
    try t.expectEqualStrings("Space f f", try chordDisplay(a, "space f f"));
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 80, .rows = 24 });
    defer app.deinit();
    try t.expectEqualStrings("F12", (try chordOf(&app, a, .@"lsp.goto_definition")).?);
    try t.expectEqualStrings("Ctrl+K Ctrl+I", (try chordOf(&app, a, .@"lsp.hover")).?);
    try t.expectEqualStrings("Ctrl+P", (try chordOf(&app, a, .@"picker.files")).?);
    try app.setInputStyle(.vim);
    try t.expectEqualStrings("gd", (try chordOf(&app, a, .@"lsp.goto_definition")).?);
    try t.expectEqualStrings("K", (try chordOf(&app, a, .@"lsp.hover")).?);
    try t.expectEqualStrings("Ctrl+P", (try chordOf(&app, a, .@"picker.files")).?);
}

test "askPrompt carries the entry's words and the target's state" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 30 });
    defer app.deinit();
    const a = app.frame.allocator();
    const e: Entry = .{ .title = "Messages", .body = "The bell counts unread warnings and errors." };
    try app.messages.record(app.gpa, "boom went the thing", .err, app.now_ms);
    const p = try askPrompt(&app, a, .{ .statusline_seg = @import("statusline.zig").SegId.bell.raw() }, e);
    try t.expect(std.mem.indexOf(u8, p, "hovering \"Messages\"") != null);
    try t.expect(std.mem.indexOf(u8, p, "The bell counts") != null);
    try t.expect(std.mem.indexOf(u8, p, "boom went the thing") != null);
    try t.expect(std.mem.indexOf(u8, p, "what I should do next") != null);
}
