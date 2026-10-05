//! Which side of the screen each activity section lives on. The frame
//! has two columns — left, with the rail down its edge, and right —
//! and a dock under the editor area, and every section that owns a
//! column surface (the tree, git mode's palette, a list panel) sits in
//! one of the three. A host shows one section at a time; the explorer
//! on the left, TODOS on the right and the diagnostics in the dock are
//! all on screen at once, which is the point.
//!
//! // changed (bottom-dock): the dock is the third host — Rust's
//! bottom panel (`App::bottom_panel_visible` / `_height`), where its
//! diagnostics live. It is sized in rows, not columns, so `size` /
//! `setSize` read `tree.width`, `side.right_width` or
//! `side.bottom_height` by side; it hosts a pane as well as a section
//! (`app/bottom.zig`).
//!
//! Rust has one sidebar (`active_section` swaps its content) and a
//! separate tabbed right panel. Here the two are one idea: a section
//! has a `Side`, and `view.move_section_left` / `_right` move it. The
//! Rust look is the default — TODOS / NOTES / FINDINGS are sidebar
//! sections there, so they start on the left; the outline was a
//! right-panel pane, so it starts in the other column, and the
//! diagnostics start in the dock.
//!
//! State: `App.side` (`State`). The explorer's own open flag stays
//! `tree.visible` (Rust's `tree_visible`, read all over); `open` is the
//! truth for the rest, and `shown` reconciles the two. Every write goes
//! through `place` / `remove` so the two cannot drift.
//!
//! // changed (section-side): replaces `App.right_panel` (one `PanelId`
//! slot) and the sidebar-or-right-panel split in `render.frameRects`.

const std = @import("std");
const app_mod = @import("../app.zig");
const compat = @import("mnml_sdk").zig_compat;
const App = app_mod.App;
const PanelId = app_mod.PanelId;
const FocusId = app_mod.FocusId;
const Config = @import("../config/Config.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const Key = @import("../core/key.zig").Key;
const rail = @import("../ui/activity_bar.zig");
const git_palette = @import("git_palette.zig");
const sidebar_auto = @import("sidebar_auto.zig");

pub const Section = rail.Section;
pub const Side = Config.Side;

pub const table = .{
    .@"view.move_section_left" = &moveLeftCmd,
    .@"view.move_section_right" = &moveRightCmd,
};

/// What a section paints in its column. Null: the section opens a
/// pane (search, debug, …) and has no side.
pub const Surface = union(enum) { tree, panel: PanelId };

/// Whether the right column paints its strip row (title, `+`, `×`) over
/// the section: only the pane-backed ones Rust's right panel tabbed.
pub fn hasStrip(s: Section) bool {
    return s == .outline or s == .diagnostics;
}

pub fn surface(s: Section) ?Surface {
    return switch (s) {
        .explorer => .tree,
        .git => .{ .panel = .git },
        .sessions => .{ .panel = .sessions },
        .http => .{ .panel = .http },
        .notes => .{ .panel = .notes },
        .todos => .{ .panel = .todos },
        .findings => .{ .panel = .findings },
        .diagnostics => .{ .panel = .diagnostics },
        .outline => .{ .panel = .outline },
        // // changed (debug-ui): the DEBUG section is a column surface.
        .debug => .{ .panel = .debug },
        // The INTEGRATIONS section is a column too (Rust's sidebar).
        .integrations => .{ .panel = .integrations },
        // // changed (lua-track): the SCRIPTS section is a column too.
        .scripts => .{ .panel = .scripts },
        // // changed (search-section): SEARCH is Rust's sidebar section
        // again — a column; the grep pane is its *Open as pane* door.
        .search => .{ .panel = .search },
        // // changed (lua-plumbing): a script's rail section.
        .script => .{ .panel = .script },
    };
}

pub fn sectionOfPanel(p: PanelId) Section {
    return switch (p) {
        .todos => .todos,
        .notes => .notes,
        .findings => .findings,
        .sessions => .sessions,
        .git => .git,
        .diagnostics => .diagnostics,
        .http => .http,
        .outline => .outline,
        .debug => .debug,
        .integrations => .integrations,
        .scripts => .scripts,
        .search => .search,
        .script => .script,
        // Never a focus: the JOBS list is an overlay's, and an overlay
        // holds `.overlay`. Named for the switch, not for a column.
        .jobs => .explorer,
    };
}

/// The focus a shown section holds.
pub fn focusOf(s: Section) ?FocusId {
    const sf = surface(s) orelse return null;
    return switch (sf) {
        .tree => .tree,
        .panel => |p| .{ .panel = p },
    };
}

pub const State = struct {
    /// Where each section lives.
    of: std.EnumArray(Section, Side),
    /// The section each column shows; null is a closed column. The
    /// explorer is shown only while `tree.visible` too (`shown`).
    open: std.EnumArray(Side, ?Section) = .initFill(null),
    /// The section a column showed last — what a toggle brings back.
    last: std.EnumArray(Side, ?Section) = .initFill(null),
    /// The section a column showed before the current one — what the
    /// column falls back to when the current one moves away.
    prev: std.EnumArray(Side, ?Section) = .initFill(null),
    /// // changed (bottom-dock): the side each section was on before
    /// its last move — what `Ctrl-W K` brings a docked section back to.
    came_from: std.EnumArray(Section, ?Side) = .initFill(null),
    /// The right column's width (`ui.right_panel_width`); the left's
    /// is `tree.width` (`ui.tree_width`, resolved by `treeWidth`).
    right_width: u16 = 32,
    /// The left column's live width was set by hand — a divider drag,
    /// *Set width…*, a restored session that had one — and no longer
    /// follows the config or a resize. *Reset width* clears it.
    tree_pinned: bool = false,
    /// // changed (bottom-dock): the dock's height in rows
    /// (`ui.bottom_panel_height`; Rust's `bottom_panel_height`).
    bottom_height: u16 = 12,
    /// vim: a `Ctrl-W` arrived with a panel focused; the next key names
    /// the window move (`ctrlW`).
    ctrl_w_pending: bool = false,

    pub fn init(cfg: *const Config) State {
        var st: State = .{ .of = .initFill(.left) };
        for (Section.all) |s| st.of.set(s, configuredSide(cfg, s));
        st.right_width = @max(cfg.ui.right_panel_width, 8);
        st.bottom_height = @max(cfg.ui.bottom_panel_height, Config.bottom_panel_height_min);
        return st;
    }
};

/// The other column. The dock is never an `opposite`: it is somewhere
/// a section is put, not a side a default flips onto.
pub fn opposite(s: Config.ColumnSide) Side {
    return if (s == .left) .right else .left;
}

/// The config's answer for a section: its `ui.section_side` entry,
/// else `ui.sidebar_side` — the Rust right-panel panes take the other
/// side of that, and the diagnostics the dock, which is where Rust
/// puts them (`lsp.diagnostics` opens a pane under the editor).
pub fn configuredSide(cfg: *const Config, s: Section) Side {
    if (overrideOf(&cfg.ui.section_side, s)) |o| return o;
    return switch (s) {
        // // changed (bottom-dock): was `.right` with the outline.
        .diagnostics => .bottom,
        .outline => opposite(cfg.ui.sidebar_side),
        else => column(cfg.ui.sidebar_side),
    };
}

/// A column as a `Side`.
pub fn column(c: Config.ColumnSide) Side {
    return switch (c) {
        .left => .left,
        .right => .right,
    };
}

pub fn overrideOf(ss: *const Config.SectionSide, s: Section) ?Side {
    inline for (compat.structFields(Config.SectionSide)) |f| {
        if (std.mem.eql(u8, f.name, @tagName(s))) return @field(ss, f.name);
    }
    return null;
}

pub fn sideOf(app: *const App, s: Section) Side {
    return app.side.of.get(s);
}

/// The section `side` shows, or null when the column is closed.
pub fn shown(app: *const App, side: Side) ?Section {
    const s = app.side.open.get(side) orelse return null;
    if (s == .explorer and !app.tree.visible) return null;
    return s;
}

pub fn isShown(app: *const App, s: Section) bool {
    return shown(app, sideOf(app, s)) == s;
}

/// The left column's width by the config at `cols` wide — the one
/// answer every reader of `ui.tree_width` asks: the number when it names
/// one, else `tree_width_share_pct` of the window clamped to
/// `tree_width_auto_min..max` (30 at 80 and 120 columns, 32 at 160, 40
/// at 200). A hand-set width (`tree_pinned`) is not this; `resolvedTreeWidth`
/// is what the live column falls back to.
pub fn treeWidth(cfg: *const Config, cols: u16) u16 {
    if (cfg.ui.tree_width != 0) return std.math.clamp(cfg.ui.tree_width, Config.tree_width_min, Config.tree_width_max);
    const share: u16 = @intCast(@as(u32, cols) * Config.tree_width_share_pct / 100);
    return std.math.clamp(share, Config.tree_width_auto_min, Config.tree_width_auto_max);
}

/// `treeWidth` for the app's own window.
pub fn defaultTreeWidth(app: *const App) u16 {
    return treeWidth(&app.cfg, app.screen.width);
}

/// Put the left column back on the config's width when nothing pinned
/// it — at start, on a resize, on a config reload. Under git mode's
/// snap the width the mode gives back is the one that moves.
/// // changed (hunt5): and the snap itself follows too — git mode's
/// column is "a fifth of the screen", so a resize re-snaps it, pinned
/// or not; only the width given back on leaving keeps a pin.
pub fn syncTreeWidth(app: *App) void {
    if (app.git_palette.active) if (app.git_palette.pre_size) |*ps| if (isSidebarColumn(app, ps.side)) {
        if (!app.side.tree_pinned) ps.n = defaultTreeWidth(app);
        snapGit(app);
        return;
    };
    if (app.side.tree_pinned) return;
    app.tree.width = defaultTreeWidth(app);
}

/// A width set by hand: the live column takes it and keeps it through
/// a resize until *Reset width*.
pub fn pinTreeWidth(app: *App, n: u16) void {
    app.side.tree_pinned = true;
    app.tree.width = n;
    app.needs_render = true;
}

/// *Reset width* / `view.reset_tree_width`: drop a hand-set width and
/// go back to the config's — its number, or the window share.
pub fn resetTreeWidth(app: *App) void {
    app.side.tree_pinned = false;
    syncTreeWidth(app);
    app.needs_render = true;
}

/// A host's own measure: the columns in cells across, the dock in rows
/// down. // changed (bottom-dock): was `width` / `setWidth`.
/// // changed (sidebar-side-width): the SIDEBAR's width (`tree.width`,
/// `ui.tree_width`, the divider's pin) belongs to whichever column
/// `ui.sidebar_side` puts the sidebar in, and `right_width` to the other
/// one — so moving the sidebar keeps its width instead of trading it for
/// the right column's.
pub fn size(app: *const App, side: Side) u16 {
    return switch (side) {
        .left, .right => if (isSidebarColumn(app, side)) app.tree.width else app.side.right_width,
        .bottom => app.side.bottom_height,
    };
}

pub fn setSize(app: *App, side: Side, n: u16) void {
    switch (side) {
        .left, .right => if (isSidebarColumn(app, side)) {
            app.tree.width = n;
        } else {
            app.side.right_width = n;
        },
        .bottom => app.side.bottom_height = std.math.clamp(n, Config.bottom_panel_height_min, Config.bottom_panel_height_max),
    }
}

/// // changed (sidebar-side-width): whether `side` is the sidebar's
/// column — the one `ui.sidebar_side` names, which carries the rail,
/// the sidebar's width and its divider's menu.
pub fn isSidebarColumn(app: *const App, side: Side) bool {
    return side == column(app.cfg.ui.sidebar_side);
}

/// A divider drag on `side`'s column: the sidebar's column pins its
/// width (as *Set width…* does), the other column just takes it.
pub fn dragColumn(app: *App, side: Side, n: u16) void {
    if (isSidebarColumn(app, side)) return pinTreeWidth(app, n);
    app.side.right_width = n;
    app.needs_render = true;
}

/// How a side reads in a toast: the dock is a dock, not a "bottom side".
pub fn sideLabel(s: Side) []const u8 {
    return switch (s) {
        .left => "left side",
        .right => "right side",
        .bottom => "bottom dock",
    };
}

/// The section the keyboard is in, if it is in a column.
pub fn sectionOfFocus(app: *const App) ?Section {
    return switch (app.focus) {
        .tree => .explorer,
        .panel => |p| sectionOfPanel(p),
        .pane, .overlay, .welcome, .info_view => null,
    };
}

/// The section's column-relative label for toasts and menus.
pub fn label(s: Section) []const u8 {
    return s.meta().label;
}

/// Put `s` in its column — closing what the column showed — and, with
/// `focus`, hand it the keys. Git mode ends when its palette is the
/// thing being replaced, so the layout it stashed comes back.
pub fn place(app: *App, s: Section, focus: bool) void {
    std.debug.assert(surface(s) != null);
    const side = sideOf(app, s);
    const prev = shown(app, side);
    if (prev != null and prev.? == .git and s != .git and app.git_palette.active) git_palette.leave(app);
    if (prev != null and prev.? != s) app.side.prev.set(side, prev);
    app.side.open.set(side, s);
    app.side.last.set(side, s);
    if (sideOf(app, .explorer) == side) app.tree.visible = s == .explorer;
    if (focus) focusSection(app, s);
    app.needs_render = true;
}

pub fn focusSection(app: *App, s: Section) void {
    const f = focusOf(s) orelse return;
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = f;
    // // changed (sidebar-autohide): handing a section the keys is what
    // every command that targets a column ends in — `view.activity_*`,
    // `view.focus_tree`, `space e`, a rail chord — so it is the one
    // place the overlay needs to know about them. (`place(…, false)`
    // does NOT come through here, which is what keeps a `.auto` launch
    // from starting with the panel up.) Docked, this is a no-op.
    const side = sideOf(app, s);
    if (side != .bottom) _ = sidebar_auto.keyboardReach(app, if (side == .left) .left else .right, false);
    app.needs_render = true;
}

/// Close `s` if its column shows it (the column's own bookkeeping —
/// git mode is left to `hide`). The keys fall back to the active pane.
pub fn remove(app: *App, s: Section) void {
    const side = sideOf(app, s);
    if (app.side.open.get(side) == s) app.side.open.set(side, null);
    if (s == .explorer) app.tree.visible = false;
    if (focusOf(s)) |f| if (std.meta.eql(app.focus, f)) dropFocus(app);
    app.needs_render = true;
}

fn dropFocus(app: *App) void {
    if (app.active) |a| {
        app.focus = .{ .pane = a };
        return;
    }
    for ([_]Side{ .left, .right, .bottom }) |side| if (shown(app, side)) |s| if (focusOf(s)) |f| {
        app.focus = f;
        return;
    };
    app.focus = .tree;
}

/// Close `s`: git mode ends with its palette.
pub fn hide(app: *App, s: Section) void {
    if (s == .git and app.git_palette.active) return git_palette.leave(app);
    remove(app, s);
}

pub fn hideColumn(app: *App, side: Side) void {
    if (shown(app, side)) |s| hide(app, s);
}

/// The sections that live on `side` and own a surface, in rail order.
pub fn sectionsOn(app: *const App, side: Side, buf: *[Section.all.len]Section) []const Section {
    var n: usize = 0;
    for (Section.all) |s| if (surface(s) != null and sideOf(app, s) == side) {
        buf[n] = s;
        n += 1;
    };
    return buf[0..n];
}

/// Open `s` the way its rail command does (git enters its mode, the
/// keys go to the section).
pub fn show(app: *App, s: Section) CommandError!void {
    const activity_bar = @import("activity_bar.zig");
    // `outline.show` splits while the column is closed (Rust's rule);
    // the column's own walk always wants the column.
    if (s == .outline) return @import("outline.zig").showInColumn(app, true);
    if (activity_bar.commandOf(s)) |id| return command.run(app, .{ .static = id });
    @import("script_section.zig").show(app, app.script_sections.active, true);
}

/// Open `s` in its column without taking the keys unless `focus` —
/// a toggle or a tab walk leaves the editor where it is, as Rust's
/// right panel does. Git always enters its mode.
pub fn open(app: *App, s: Section, focus: bool) CommandError!void {
    if (s == .git) return show(app, s);
    if (s == .outline) return @import("outline.zig").showInColumn(app, focus);
    place(app, s, focus);
}

/// `view.toggle_right_panel` / `view.toggle_tree`: close the column, or
/// bring back what it showed last (else the first section on that side).
pub fn toggleColumn(app: *App, side: Side) CommandError!void {
    if (shown(app, side) != null) return hideColumn(app, side);
    var buf: [Section.all.len]Section = undefined;
    const here = sectionsOn(app, side, &buf);
    const s = app.side.last.get(side) orelse (if (here.len > 0) here[0] else null) orelse
        return app.diag.fail(app.frame.allocator(), "nothing lives on the {s} — right-click a rail icon: Move to {s}", .{ sideLabel(side), sideLabel(side) });
    try open(app, s, false);
    // // changed (sidebar-autohide): auto-hidden, the column that just
    // opened has nowhere docked to appear — `render.chrome` carves no
    // column at all under `ui.sidebar = .auto` / `.hidden` — so the
    // toggle has to bring up the overlay that carries it. `open` alone
    // does not: it goes through `place(…, false)`, which never reveals,
    // and that is what keeps a `.auto` launch from starting with the
    // panel up. Docked, this is a no-op.
    if (side != .bottom) _ = sidebar_auto.keyboardReach(app, if (side == .left) .left else .right, false);
}

/// The next / previous section along `side`'s list, opened; the keys
/// follow when they were in that column.
pub fn step(app: *App, side: Side, by: isize) CommandError!void {
    var buf: [Section.all.len]Section = undefined;
    const here = sectionsOn(app, side, &buf);
    if (here.len == 0) return app.diag.fail(app.frame.allocator(), "nothing lives on the {s}", .{sideLabel(side)});
    const cur = shown(app, side) orelse return open(app, here[0], false);
    const had_focus = if (focusOf(cur)) |f| std.meta.eql(app.focus, f) else false;
    var idx: usize = 0;
    for (here, 0..) |s, i| if (s == cur) {
        idx = i;
    };
    const n: isize = @intCast(here.len);
    const next: usize = @intCast(@mod(@as(isize, @intCast(idx)) + by, n));
    try open(app, here[next], had_focus);
}

/// Move `s` to `dest`: closed on one side, open on the other, the keys
/// staying with it.
pub fn move(app: *App, s: Section, dest: Side) CommandError!void {
    const arena = app.frame.allocator();
    if (surface(s) == null) return app.diag.fail(arena, "{s} opens as a pane; it has no side", .{label(s)});
    const from = sideOf(app, s);
    if (from == dest) {
        app.toast("{s} is already on the {s}", .{ label(s), sideLabel(dest) });
        return;
    }
    const was_shown = isShown(app, s);
    const had_focus = if (focusOf(s)) |f| std.meta.eql(app.focus, f) else false;
    if (was_shown) remove(app, s);
    app.side.came_from.set(s, from);
    app.side.of.set(s, dest);
    if (was_shown) place(app, s, had_focus);
    // The vacated column shows what it showed before (the explorer, as
    // a rule) — TODOS on the right beside the tree, not beside a gap.
    if (was_shown and shown(app, from) == null) if (fallbackFor(app, from, s)) |back| place(app, back, false);
    app.toast("{s} → {s}", .{ label(s), sideLabel(dest) });
    app.needs_render = true;
}

/// What a column shows once `gone` has left it: the section it showed
/// before, else the explorer when it lives there. Git is not brought
/// back (its palette is a mode, entered through its command).
fn fallbackFor(app: *const App, side: Side, gone: Section) ?Section {
    if (app.side.prev.get(side)) |p| if (p != gone and p != .git and surface(p) != null and sideOf(app, p) == side) return p;
    if (sideOf(app, .explorer) == side and gone != .explorer) return .explorer;
    return null;
}

/// Re-read the sections' sides after `ui.sidebar_side` flipped away
/// from `before`: a section still where the old default put it follows
/// the new one (moving, if shown); one moved by hand (*Move to right
/// side*, `Ctrl-W L`) keeps its column.
pub fn reseedFrom(app: *App, before: Config.ColumnSide) void {
    var old = app.cfg;
    old.ui.sidebar_side = before;
    for (Section.all) |s| {
        if (sideOf(app, s) != configuredSide(&old, s)) continue;
        const want = configuredSide(&app.cfg, s);
        if (want == sideOf(app, s)) continue;
        const was_shown = isShown(app, s);
        const had_focus = if (focusOf(s)) |f| std.meta.eql(app.focus, f) else false;
        if (was_shown) remove(app, s);
        app.side.of.set(s, want);
        if (was_shown) place(app, s, had_focus);
    }
    app.needs_render = true;
}

/// The section the move commands act on: the focused one, else the
/// rail's mark.
pub fn targetSection(app: *App) Section {
    return target(app);
}

fn target(app: *App) Section {
    const activity_bar = @import("activity_bar.zig");
    return sectionOfFocus(app) orelse activity_bar.active(app);
}

fn moveLeftCmd(app: *App) CommandError!void {
    return move(app, target(app), .left);
}

fn moveRightCmd(app: *App) CommandError!void {
    return move(app, target(app), .right);
}

/// Git mode's snap: the palette's column takes a fifth of the screen
/// when that is at least eight cells (Rust `open_git_graph`).
pub fn snapGit(app: *App) void {
    const side = sideOf(app, .git);
    // The dock is sized in rows; the snap is a column rule.
    if (side == .bottom) return;
    const fifth: u16 = @intCast(@as(u32, app.screen.width) * 20 / 100);
    if (fifth >= 8) setSize(app, side, fifth);
}

/// // changed (bottom-dock): Neovim's `Ctrl-W J` / `K` from a column —
/// the section goes down into the dock, or back up to the column it
/// came from (its configured column when it has never moved). They are
/// not command ids: the two Rust ids for the dock are `toggle` and
/// `host_active`, and the spec count is pinned. Null: not a move.
pub fn ctrlWSectionSide(app: *const App, k: Key, s: Section) ?Side {
    if (k.code != .char) return null;
    return switch (k.code.char) {
        'J' => .bottom,
        'K' => if (sideOf(app, s) != .bottom) null else blk: {
            if (app.side.came_from.get(s)) |c| if (c != .bottom) break :blk c;
            const cfg_side = configuredSide(&app.cfg, s);
            break :blk if (cfg_side != .bottom) cfg_side else column(app.cfg.ui.sidebar_side);
        },
        else => null,
    };
}

/// vim's `Ctrl-W` family from a column: `w` / `p` / `h` / `j` / `k` /
/// `l` (and the arrows) move on from it the way `Ctrl-L` does; `H` and
/// `L` are Neovim's window moves — the section goes to that edge.
pub fn ctrlWCommand(k: Key) ?command.CommandId {
    return switch (k.code) {
        .char => |c| switch (if (k.mods.ctrl and c < 0x80) @as(u21, std.ascii.toLower(@intCast(c))) else c) {
            'w' => .@"view.focus_next_split",
            'W' => .@"view.focus_prev_split",
            'p' => .@"view.focus_previous",
            't' => .@"view.focus_top",
            'b' => .@"view.focus_bottom",
            'l' => .@"view.focus_right",
            'h' => .@"view.focus_left",
            'j' => .@"view.focus_down",
            'k' => .@"view.focus_up",
            'D' => .@"view.focus_dock",
            'H' => .@"view.move_section_left",
            'L' => .@"view.move_section_right",
            else => null,
        },
        .right => .@"view.focus_right",
        .left => .@"view.focus_left",
        .down => .@"view.focus_down",
        .up => .@"view.focus_up",
        else => null,
    };
}

/// A bare `Ctrl-W` under the vim profile.
pub fn isCtrlW(app: *const App, k: Key) bool {
    return app.input_style == .vim and k.mods.ctrl and !k.mods.shift and !k.mods.alt and !k.mods.super and k.code == .char and std.ascii.toLower(@intCast(@min(k.code.char, 0x7F))) == 'w';
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const render = @import("render.zig");
const bottom_mod = @import("bottom.zig");
const Rect = @import("../ui/rect.zig");

fn rects(app: *App) render.FrameRects {
    return render.frameRects(Rect.init(0, 0, app.screen.width, app.screen.height), render.chrome(app));
}

test "defaults: every section is on the left but the outline (right) and the diagnostics (the dock); the explorer is open on the left, the right column and the dock closed" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    for (Section.all) |s| try t.expectEqual(switch (s) {
        .outline => Side.right,
        // // changed (bottom-dock): the diagnostics live in the dock.
        .diagnostics => Side.bottom,
        else => Side.left,
    }, sideOf(&app, s));
    try t.expectEqual(Section.explorer, shown(&app, .left).?);
    try t.expect(shown(&app, .right) == null);
    try t.expect(shown(&app, .bottom) == null);
    const fr = rects(&app);
    try t.expect(fr.sidebar.eql(Rect.init(4, 1, 26, 37)));
    try t.expect(fr.right.isEmpty() and fr.right_divider.isEmpty());
    try t.expect(fr.bottom.isEmpty() and fr.bottom_divider.isEmpty());
    try t.expect(fr.body.eql(Rect.init(31, 1, 89, 37)));
}

test "configuredSide: the overrides win, then sidebar_side, the outline on the other side of it, the diagnostics in the dock whichever side that is" {
    var cfg = Config{};
    try t.expectEqual(Side.left, configuredSide(&cfg, .todos));
    try t.expectEqual(Side.right, configuredSide(&cfg, .outline));
    try t.expectEqual(Side.bottom, configuredSide(&cfg, .diagnostics));
    cfg.ui.sidebar_side = .right;
    try t.expectEqual(Side.right, configuredSide(&cfg, .todos));
    try t.expectEqual(Side.left, configuredSide(&cfg, .outline));
    // The dock is not a side the sidebar default flips onto.
    try t.expectEqual(Side.bottom, configuredSide(&cfg, .diagnostics));
    // A user who wants the old placement says so.
    cfg.ui.section_side.diagnostics = .right;
    try t.expectEqual(Side.right, configuredSide(&cfg, .diagnostics));
    cfg.ui.section_side.todos = .left;
    cfg.ui.section_side.outline = .right;
    try t.expectEqual(Side.left, configuredSide(&cfg, .todos));
    try t.expectEqual(Side.right, configuredSide(&cfg, .outline));
    const st = State.init(&cfg);
    try t.expectEqual(Side.left, st.of.get(.todos));
    try t.expectEqual(Side.right, st.of.get(.notes));
    try t.expectEqual(@as(u16, 12), st.bottom_height);
}

test "move: a shown section closes on one side and opens on the other with the keys; the explorer stays; a pane section has no side; the same side is a no-op" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.activity_todos" });
    try t.expectEqual(Section.todos, shown(&app, .left).?);
    try t.expect(!app.tree.visible);
    try t.expect(app.focus == .panel and app.focus.panel == .todos);
    // Left → right: TODOS shows on the right with the keys, and the
    // explorer — what the left column showed before — is back beside it.
    try command.run(&app, .{ .static = .@"view.move_section_right" });
    try t.expectEqual(Side.right, sideOf(&app, .todos));
    try t.expectEqual(Section.explorer, shown(&app, .left).?);
    try t.expect(app.tree.visible);
    try t.expectEqual(Section.todos, shown(&app, .right).?);
    try t.expect(app.focus == .panel and app.focus.panel == .todos);
    var fr = rects(&app);
    try t.expect(fr.right.eql(Rect.init(88, 1, 32, 37)));
    try t.expect(fr.right_divider.eql(Rect.init(87, 1, 1, 37)));
    // Closing the left column leaves TODOS alone on the right.
    try command.run(&app, .{ .static = .@"view.toggle_tree" });
    try t.expect(shown(&app, .left) == null);
    fr = rects(&app);
    try t.expect(fr.sidebar.isEmpty());
    try t.expect(fr.body.eql(Rect.init(0, 1, 87, 37)));
    try command.run(&app, .{ .static = .@"view.activity_explorer" });
    try t.expectEqual(Section.explorer, shown(&app, .left).?);
    try t.expectEqual(Section.todos, shown(&app, .right).?);
    fr = rects(&app);
    try t.expect(fr.sidebar.eql(Rect.init(4, 1, 26, 37)));
    try t.expect(fr.right.eql(Rect.init(88, 1, 32, 37)));
    try t.expect(fr.body.eql(Rect.init(31, 1, 56, 37)));
    // Back left: TODOS takes the explorer's column; the right column
    // has nothing to fall back to and closes.
    app.focus = .{ .panel = .todos };
    try command.run(&app, .{ .static = .@"view.move_section_left" });
    try t.expectEqual(Section.todos, shown(&app, .left).?);
    try t.expect(shown(&app, .right) == null);
    try t.expect(!app.tree.visible);
    try command.run(&app, .{ .static = .@"view.move_section_left" });
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "already on the left") != null);
    // A closed section moves without opening.
    try command.run(&app, .{ .static = .@"view.activity_explorer" });
    try t.expect(!isShown(&app, .todos));
    app.focus = .tree;
    try t.expectEqual(Section.explorer, target(&app));
    try move(&app, .notes, .right);
    try t.expectEqual(Side.right, sideOf(&app, .notes));
    try t.expect(shown(&app, .right) == null);
    // // changed (search-section): SEARCH has a side like the rest.
    try move(&app, .search, .right);
    try t.expectEqual(Side.right, sideOf(&app, .search));
}

test "the right column: toggle brings back the last section shown there, else the first on that side; next / prev walk the side; focus opens it" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();
    // // changed (bottom-dock): the diagnostics moved to the dock, so
    // the outline is what lives on the right out of the box. Put the
    // diagnostics back beside it to walk a two-section column.
    try move(&app, .diagnostics, .right);
    try command.run(&app, .{ .static = .@"view.toggle_right_panel" });
    try t.expectEqual(Section.diagnostics, shown(&app, .right).?);
    // A toggle and a tab walk leave the keys in the editor (Rust's
    // right panel); the keys follow only when they were in the column.
    try t.expect(app.focus == .pane);
    try command.run(&app, .{ .static = .@"view.right_panel_next_tab" });
    try t.expectEqual(Section.outline, shown(&app, .right).?);
    try t.expect(app.outline_panel != null);
    try t.expect(app.focus == .pane);
    focusSection(&app, .outline);
    try command.run(&app, .{ .static = .@"view.right_panel_next_tab" });
    try t.expectEqual(Section.diagnostics, shown(&app, .right).?);
    try t.expect(app.focus == .panel and app.focus.panel == .diagnostics);
    try command.run(&app, .{ .static = .@"view.right_panel_prev_tab" });
    try t.expectEqual(Section.outline, shown(&app, .right).?);
    try t.expect(app.focus == .panel and app.focus.panel == .outline);
    try command.run(&app, .{ .static = .@"view.toggle_right_panel" });
    try t.expect(shown(&app, .right) == null);
    try t.expect(app.focus == .pane);
    try command.run(&app, .{ .static = .@"view.toggle_right_panel" });
    try t.expectEqual(Section.outline, shown(&app, .right).?);
    try command.run(&app, .{ .static = .@"view.right_panel_close_tab" });
    try t.expect(shown(&app, .right) == null);
    try command.run(&app, .{ .static = .@"view.focus_right_panel" });
    try t.expectEqual(Section.outline, shown(&app, .right).?);
    try t.expect(app.focus == .panel and app.focus.panel == .outline);
    // With TODOS moved right it joins the walk, in section order.
    try move(&app, .todos, .right);
    try command.run(&app, .{ .static = .@"view.right_panel_next_tab" });
    try t.expectEqual(Section.todos, shown(&app, .right).?);
    try command.run(&app, .{ .static = .@"view.right_panel_next_tab" });
    try t.expectEqual(Section.diagnostics, shown(&app, .right).?);
    try command.run(&app, .{ .static = .@"view.right_panel_prev_tab" });
    try t.expectEqual(Section.todos, shown(&app, .right).?);
}

test "layout: sections on one side, both sides, none; the right column keeps the panes 21 columns and floors at 8" {
    // None: the whole width is the body.
    const none = render.frameRects(Rect.init(0, 0, 120, 40), .{});
    try t.expect(none.sidebar.isEmpty() and none.right.isEmpty());
    try t.expect(none.body.eql(Rect.init(0, 1, 120, 37)));
    // Right only: no rail (it rides the left column), the divider at 79.
    const right = render.frameRects(Rect.init(0, 0, 120, 40), .{ .right = 40 });
    try t.expect(right.sidebar.isEmpty() and right.rail.isEmpty());
    try t.expect(right.right.eql(Rect.init(80, 1, 40, 37)));
    try t.expect(right.right_divider.eql(Rect.init(79, 1, 1, 37)));
    try t.expect(right.body.eql(Rect.init(0, 1, 79, 37)));
    // Both: 30 on the left (rail 3 + border + 26), 40 on the right.
    const both = render.frameRects(Rect.init(0, 0, 120, 40), .{ .sidebar = 30, .right = 40 });
    try t.expect(both.rail.eql(Rect.init(0, 1, 3, 37)));
    try t.expect(both.sidebar.eql(Rect.init(4, 1, 26, 37)));
    try t.expect(both.sidebar_divider.eql(Rect.init(30, 1, 1, 37)));
    try t.expect(both.right_divider.eql(Rect.init(79, 1, 1, 37)));
    try t.expect(both.right.eql(Rect.init(80, 1, 40, 37)));
    try t.expect(both.body.eql(Rect.init(31, 1, 48, 37)));
    // A wide right column is clamped so the panes keep 21 cells.
    // (Rust's clamp counts the divider inside the 21: the panes keep 20.)
    const wide = render.frameRects(Rect.init(0, 0, 120, 40), .{ .sidebar = 30, .right = 100 });
    try t.expect(wide.right.w == 89 - 21);
    try t.expect(wide.body.w == 20);
    // Too narrow for a right column: none is carved.
    const tiny = render.frameRects(Rect.init(0, 0, 60, 40), .{ .sidebar = 30, .right = 40 });
    try t.expect(tiny.right.isEmpty());
    try t.expect(tiny.body.eql(Rect.init(31, 1, 29, 37)));
}

test "layout (bottom-dock): the dock comes off `upper` before the columns — full width, a divider row above it, two thirds the cap, and nothing at all under six rows" {
    // 12 rows plus a divider: the columns and the body end above them.
    const d = render.frameRects(Rect.init(0, 0, 120, 40), .{ .sidebar = 30, .right = 40, .bottom = 12 });
    try t.expect(d.bottom.eql(Rect.init(0, 26, 120, 12)));
    try t.expect(d.bottom_divider.eql(Rect.init(0, 25, 120, 1)));
    try t.expect(d.upper.eql(Rect.init(0, 1, 120, 24)));
    // The columns keep their widths and lose the dock's rows.
    try t.expect(d.sidebar.eql(Rect.init(4, 1, 26, 24)));
    try t.expect(d.right.eql(Rect.init(80, 1, 40, 24)));
    try t.expect(d.body.eql(Rect.init(31, 1, 48, 24)));
    // The cap: two thirds of `upper`. At 40 rows `upper` is 37, so 24.
    const greedy = render.frameRects(Rect.init(0, 0, 120, 40), .{ .bottom = 60 });
    try t.expectEqual(@as(u16, 24), greedy.bottom.h);
    try t.expect(greedy.body.h == 12);
    // 80x24: `upper` is 21, the cap 14, the ask 12.
    const small = render.frameRects(Rect.init(0, 0, 80, 24), .{ .sidebar = 30, .bottom = 12 });
    try t.expect(small.bottom.eql(Rect.init(0, 10, 80, 12)));
    try t.expect(small.body.h == 8);
    try t.expect(small.sidebar.h == 8);
    // 200x60: `upper` is 57, the ask 12, so the editor keeps 44 rows.
    const big = render.frameRects(Rect.init(0, 0, 200, 60), .{ .sidebar = 30, .right = 40, .bottom = 12 });
    try t.expect(big.bottom.eql(Rect.init(0, 46, 200, 12)));
    try t.expect(big.body.eql(Rect.init(31, 1, 128, 44)));
    // Too short: `upper` under six rows carves no dock at all, and the
    // frame is exactly what it was without one.
    const squat = render.frameRects(Rect.init(0, 0, 120, 8), .{ .bottom = 12 });
    try t.expectEqual(@as(u16, 5), squat.upper.h);
    try t.expect(squat.bottom.isEmpty() and squat.bottom_divider.isEmpty());
    try t.expect(squat.body.eql(render.frameRects(Rect.init(0, 0, 120, 8), .{}).body));
    // Exactly six rows of `upper`: the floor of three plus the divider,
    // and the body still has two rows — the dock never takes the last.
    const six = render.frameRects(Rect.init(0, 0, 120, 9), .{ .bottom = 12 });
    try t.expectEqual(@as(u16, 6), six.upper.h + six.bottom.h + 1);
    try t.expectEqual(@as(u16, 3), six.bottom.h);
    try t.expectEqual(@as(u16, 2), six.body.h);
    // Seven: the two-thirds cap and the body floor both say four.
    const seven = render.frameRects(Rect.init(0, 0, 120, 10), .{ .bottom = 12 });
    try t.expectEqual(@as(u16, 4), seven.bottom.h);
    try t.expectEqual(@as(u16, 2), seven.body.h);
}

test "the dock: placing a section there, `view.toggle_bottom_panel` closing and reopening it, the height clamp, and a divider drag" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();
    // The diagnostics live in the dock; the toggle opens it there.
    try t.expectEqual(Side.bottom, sideOf(&app, .diagnostics));
    try t.expect(shown(&app, .bottom) == null);
    try command.run(&app, .{ .static = .@"view.toggle_bottom_panel" });
    try t.expectEqual(Section.diagnostics, shown(&app, .bottom).?);
    var fr = rects(&app);
    try t.expect(fr.bottom.eql(Rect.init(0, 26, 120, 12)));
    // A drag of the divider up to row 20 gives the dock the rows under it.
    bottom_mod.dragTo(&app, 20);
    try t.expectEqual(@as(u16, 17), size(&app, .bottom));
    fr = rects(&app);
    try t.expect(fr.bottom.eql(Rect.init(0, 21, 120, 17)));
    // Dragging past the floor and the ceiling clamps instead of wrapping.
    bottom_mod.dragTo(&app, 37);
    try t.expectEqual(Config.bottom_panel_height_min, size(&app, .bottom));
    setSize(&app, .bottom, 500);
    try t.expectEqual(Config.bottom_panel_height_max, size(&app, .bottom));
    setSize(&app, .bottom, 12);
    // The toggle closes it, and opens it again on what it showed last.
    try command.run(&app, .{ .static = .@"view.toggle_bottom_panel" });
    try t.expect(shown(&app, .bottom) == null);
    try t.expect(rects(&app).bottom.isEmpty());
    try command.run(&app, .{ .static = .@"view.toggle_bottom_panel" });
    try t.expectEqual(Section.diagnostics, shown(&app, .bottom).?);
}

test "the dock: a section moved down and back — `Ctrl-W J` docks TODOS, `Ctrl-W K` returns it to the column it came from" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try command.run(&app, .{ .static = .@"view.activity_todos" });
    try t.expectEqual(Section.todos, shown(&app, .left).?);
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('J') });
    try t.expectEqual(Side.bottom, sideOf(&app, .todos));
    try t.expectEqual(Section.todos, shown(&app, .bottom).?);
    try t.expect(app.focus == .panel and app.focus.panel == .todos);
    // The left column falls back to the explorer, as it does for a
    // section moved to the other column.
    try t.expectEqual(Section.explorer, shown(&app, .left).?);
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('K') });
    try t.expectEqual(Side.left, sideOf(&app, .todos));
    try t.expectEqual(Section.todos, shown(&app, .left).?);
    // `K` in a column is not a move — it is the focus step.
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('K') });
    try t.expectEqual(Side.left, sideOf(&app, .todos));
    // A section whose configured home is the dock comes back to the
    // sidebar side when it has never been anywhere else.
    try t.expect(ctrlWSectionSide(&app, Key.char('K'), .diagnostics).? == .left);
    try t.expect(ctrlWSectionSide(&app, Key.char('J'), .diagnostics).? == .bottom);
    try t.expect(ctrlWSectionSide(&app, Key.char('x'), .todos) == null);
}

test "the dock is a window: vim `Ctrl-W j` steps down into it from a pane, from the tree and from a column, and `Ctrl-W k` steps back up" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const ed = try app.openScratch();
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try command.run(&app, .{ .static = .@"view.toggle_bottom_panel" });
    try t.expectEqual(Section.diagnostics, shown(&app, .bottom).?);
    try t.expect(app.focus == .pane);
    // From the editor down into the dock's section, and back up.
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('j') });
    try t.expect(app.focus == .panel and app.focus.panel == .diagnostics);
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('k') });
    try t.expect(app.focus == .pane and app.active.? == ed);
    // From the tree: the dock runs under it too.
    try command.run(&app, .{ .static = .@"view.activity_explorer" });
    app.focus = .tree;
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('j') });
    try t.expect(app.focus == .panel and app.focus.panel == .diagnostics);
    // From a column section, the same step.
    try command.run(&app, .{ .static = .@"view.activity_todos" });
    try t.expect(app.focus == .panel and app.focus.panel == .todos);
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('j') });
    try t.expect(app.focus == .panel and app.focus.panel == .diagnostics);
    // A hosted pane is the dock's window instead, and `k` leaves it for
    // the pane that stayed in the splits.
    app.setActive(ed);
    try command.run(&app, .{ .static = .@"view.split_right" });
    const other = app.active.?;
    try t.expect(other != ed);
    app.setActive(ed);
    try command.run(&app, .{ .static = .@"view.host_active_in_bottom_panel" });
    try t.expectEqual(ed, bottom_mod.activePane(&app).?);
    try t.expect(bottom_mod.focused(&app));
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('k') });
    try t.expect(!bottom_mod.focused(&app));
    try t.expectEqual(other, app.active.?);
    // `j` steps back down into it.
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('j') });
    try t.expectEqual(ed, app.active.?);
    try t.expect(bottom_mod.focused(&app));
}

test "the dock hosts a pane: `view.host_active_in_bottom_panel` takes the active pane out of the splits and puts it back" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const a = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.split_right" });
    const b = app.active.?;
    try t.expect(a != b);
    try t.expect(app.layouts.current().leafOf(b) != null);
    // Docked: out of the split tree, into the dock, with the keys.
    try command.run(&app, .{ .static = .@"view.host_active_in_bottom_panel" });
    try t.expect(bottom_mod.hosts(&app, b));
    try t.expect(app.layouts.current().leafOf(b) == null);
    try t.expectEqual(b, bottom_mod.activePane(&app).?);
    try t.expectEqual(b, app.active.?);
    try t.expect(bottom_mod.open(&app));
    try t.expect(!rects(&app).bottom.isEmpty());
    // The split tree is back to one leaf holding the pane that stayed.
    try t.expectEqual(a, app.layouts.current().leaf(app.layouts.current().firstLeaf().?).?.active);
    // Run again on the docked pane: back out to the splits.
    try command.run(&app, .{ .static = .@"view.host_active_in_bottom_panel" });
    try t.expect(!bottom_mod.hosts(&app, b));
    try t.expect(app.layouts.current().leafOf(b) != null);
    try t.expect(!bottom_mod.open(&app));
    // Closing a docked pane forgets it (`App.forceClosePane`).
    try command.run(&app, .{ .static = .@"view.host_active_in_bottom_panel" });
    try t.expect(bottom_mod.hosts(&app, b));
    try app.closePane(b, true);
    try t.expect(!bottom_mod.hosts(&app, b));
    try t.expect(bottom_mod.activePane(&app) == null);
}

test "the dock: the toggle drains its hosted panes back to the splits, as Rust's does" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.split_right" });
    const b = app.active.?;
    try command.run(&app, .{ .static = .@"view.host_active_in_bottom_panel" });
    try t.expect(bottom_mod.hosts(&app, b));
    try command.run(&app, .{ .static = .@"view.toggle_bottom_panel" });
    try t.expect(!bottom_mod.hosts(&app, b));
    try t.expect(app.layouts.current().leafOf(b) != null);
    try t.expect(!bottom_mod.open(&app));
}

test "ctrlWCommand: the vim window family from a column, H / L the section moves" {
    try t.expectEqual(command.CommandId.@"view.focus_left", ctrlWCommand(Key.char('h')).?);
    try t.expectEqual(command.CommandId.@"view.move_section_left", ctrlWCommand(Key.char('H')).?);
    try t.expectEqual(command.CommandId.@"view.move_section_right", ctrlWCommand(Key.char('L')).?);
    try t.expectEqual(command.CommandId.@"view.focus_next_split", ctrlWCommand(Key.char('w')).?);
    try t.expectEqual(command.CommandId.@"view.focus_prev_split", ctrlWCommand(Key.char('W')).?);
    try t.expectEqual(command.CommandId.@"view.focus_up", ctrlWCommand(Key.named(.up)).?);
    try t.expect(ctrlWCommand(Key.char('x')) == null);
}

test "vim: ctrl+w L on a focused TODOS panel moves it to the right edge; ctrl+w H on the tree moves the explorer to the left (a no-op there); an editor keeps the split meaning" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try command.run(&app, .{ .static = .@"view.activity_todos" });
    try app.handle(.{ .key = Key.ctrl('w') });
    try t.expect(app.side.ctrl_w_pending);
    try app.handle(.{ .key = Key.char('L') });
    try t.expectEqual(Side.right, sideOf(&app, .todos));
    try t.expectEqual(Section.todos, shown(&app, .right).?);
    try t.expect(app.focus == .panel and app.focus.panel == .todos);
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('H') });
    try t.expectEqual(Side.left, sideOf(&app, .todos));
    try t.expectEqual(Section.todos, shown(&app, .left).?);
    // The tree: its own pending flag, the same table.
    try command.run(&app, .{ .static = .@"view.activity_explorer" });
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('L') });
    try t.expectEqual(Side.right, sideOf(&app, .explorer));
    try t.expectEqual(Section.explorer, shown(&app, .right).?);
    try t.expect(app.tree.visible);
    try t.expect(app.focus == .tree);
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('H') });
    try t.expectEqual(Side.left, sideOf(&app, .explorer));
    // An editor: `Ctrl-W L` is the split move, not a section move.
    app.focus = .{ .pane = app.active.? };
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('L') });
    try t.expectEqual(Side.left, sideOf(&app, .explorer));
    try t.expectEqual(Side.left, sideOf(&app, .todos));
}

test "git mode follows its section's side: on the right, entering snaps the right column to a fifth and the palette paints there; leaving puts the explorer back only on its own side" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    try move(&app, .git, .right);
    try command.run(&app, .{ .static = .@"view.activity_git" });
    try t.expect(app.git_palette.active);
    try t.expectEqual(Section.git, shown(&app, .right).?);
    try t.expectEqual(Section.explorer, shown(&app, .left).?);
    try t.expectEqual(@as(u16, 24), app.side.right_width);
    try t.expectEqual(@as(u16, 30), app.tree.width);
    const fr = rects(&app);
    try t.expect(fr.right.eql(Rect.init(96, 1, 24, 37)));
    try command.run(&app, .{ .static = .@"view.toggle_right_panel" });
    try t.expect(!app.git_palette.active);
    try t.expect(shown(&app, .right) == null);
    try t.expectEqual(Section.explorer, shown(&app, .left).?);
    // On the left (the default) the snap is the tree's width, as before.
    try move(&app, .git, .left);
    try command.run(&app, .{ .static = .@"view.activity_git" });
    try t.expectEqual(Section.git, shown(&app, .left).?);
    try t.expectEqual(@as(u16, 24), app.tree.width);
    try t.expect(!app.tree.visible);
    try command.run(&app, .{ .static = .@"view.activity_todos" });
    try t.expect(!app.git_palette.active);
    try t.expectEqual(Section.todos, shown(&app, .left).?);
}

test "git mode's snap is the mode's: the column it narrowed gets its width back when the mode ends — the explorer at 30 again, not 24 — a dragged width comes back as dragged, the right column too, and a session saved in the mode keeps the width from before it" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    // Before: the configured 30 — the rail's 3 and its border off it.
    try t.expectEqual(@as(u16, 30), app.tree.width);
    try t.expectEqual(@as(u16, 26), rects(&app).sidebar.w);
    // In the mode: a fifth of 120.
    try command.run(&app, .{ .static = .@"view.activity_git" });
    try t.expectEqual(@as(u16, 24), app.tree.width);
    try t.expectEqual(@as(u16, 20), rects(&app).sidebar.w);
    // A session saved now remembers the width the column rests at.
    {
        var arena_state = std.heap.ArenaAllocator.init(t.allocator);
        defer arena_state.deinit();
        const saved = try @import("session.zig").capture(&app, arena_state.allocator());
        try t.expectEqual(@as(u16, 30), saved.tree_width);
    }
    // Back to the explorer: 30 again.
    try command.run(&app, .{ .static = .@"view.activity_explorer" });
    try t.expect(!app.git_palette.active);
    try t.expectEqual(Section.explorer, shown(&app, .left).?);
    try t.expectEqual(@as(u16, 30), app.tree.width);
    try t.expectEqual(@as(u16, 26), rects(&app).sidebar.w);
    // Through another section, and through the toggle, the same.
    try command.run(&app, .{ .static = .@"view.activity_git" });
    try command.run(&app, .{ .static = .@"view.activity_todos" });
    try t.expectEqual(@as(u16, 30), app.tree.width);
    try command.run(&app, .{ .static = .@"view.activity_git" });
    try command.run(&app, .{ .static = .@"git.branch_rail_toggle" });
    try t.expectEqual(@as(u16, 30), app.tree.width);
    // A width the user dragged to is the one that comes back.
    app.tree.width = 40;
    try command.run(&app, .{ .static = .@"view.activity_git" });
    try t.expectEqual(@as(u16, 24), app.tree.width);
    try command.run(&app, .{ .static = .@"view.activity_explorer" });
    try t.expectEqual(@as(u16, 40), app.tree.width);
    // Entering twice stashes once: the second entry does not stash 24.
    try command.run(&app, .{ .static = .@"view.activity_git" });
    try command.run(&app, .{ .static = .@"view.activity_git" });
    try command.run(&app, .{ .static = .@"view.activity_explorer" });
    try t.expectEqual(@as(u16, 40), app.tree.width);
    // On the right, the right column's width comes back.
    try move(&app, .git, .right);
    try t.expectEqual(@as(u16, 32), app.side.right_width);
    try command.run(&app, .{ .static = .@"view.activity_git" });
    try t.expectEqual(@as(u16, 24), app.side.right_width);
    try command.run(&app, .{ .static = .@"view.toggle_right_panel" });
    try t.expectEqual(@as(u16, 32), app.side.right_width);
    try t.expectEqual(@as(u16, 40), app.tree.width);
}

test "treeWidth: a fifth of the window, 30..48 — 30 at 80 and 120, 32 at 160, 40 at 200 — unless ui.tree_width names a number" {
    var cfg: Config = .{};
    try t.expectEqual(@as(u16, 30), treeWidth(&cfg, 80));
    try t.expectEqual(@as(u16, 30), treeWidth(&cfg, 120));
    try t.expectEqual(@as(u16, 32), treeWidth(&cfg, 160));
    try t.expectEqual(@as(u16, 40), treeWidth(&cfg, 200));
    // The clamps: never under 30, never over 48.
    try t.expectEqual(Config.tree_width_auto_min, treeWidth(&cfg, 40));
    try t.expectEqual(Config.tree_width_auto_min, treeWidth(&cfg, 0));
    try t.expectEqual(Config.tree_width_auto_max, treeWidth(&cfg, 300));
    try t.expectEqual(Config.tree_width_auto_max, treeWidth(&cfg, 1000));
    // An explicit number wins at every width, clamped as the load does.
    cfg.ui.tree_width = 36;
    for ([_]u16{ 80, 120, 200, 400 }) |cols| try t.expectEqual(@as(u16, 36), treeWidth(&cfg, cols));
    cfg.ui.tree_width = 3;
    try t.expectEqual(Config.tree_width_min, treeWidth(&cfg, 200));
}

test "the left column: the share at start and on a resize; an explicit number holds; a drag pins through a resize; reset unpins; the session keeps a pin and not a share" {
    {
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 200, .rows = 40 });
        defer app.deinit();
        try t.expectEqual(@as(u16, 40), app.tree.width);
        try app.resize(80, 24);
        try t.expectEqual(@as(u16, 30), app.tree.width);
        try app.resize(160, 40);
        try t.expectEqual(@as(u16, 32), app.tree.width);
        // A drag wins over the share, and holds through a resize.
        pinTreeWidth(&app, 45);
        try app.resize(200, 40);
        try t.expectEqual(@as(u16, 45), app.tree.width);
        // A session saved now remembers the pin; unpinned, it does not.
        var arena_state = std.heap.ArenaAllocator.init(t.allocator);
        defer arena_state.deinit();
        const session = @import("session.zig");
        const pinned = try session.capture(&app, arena_state.allocator());
        try t.expectEqual(@as(u16, 45), pinned.tree_width);
        try t.expectEqual(@as(?bool, true), pinned.tree_width_pinned);
        resetTreeWidth(&app);
        try t.expectEqual(@as(u16, 40), app.tree.width);
        const auto = try session.capture(&app, arena_state.allocator());
        try t.expectEqual(@as(?bool, false), auto.tree_width_pinned);
        // Under git mode's snap a resize moves the width the mode gives
        // back, not the snapped one.
        try command.run(&app, .{ .static = .@"view.activity_git" });
        try t.expectEqual(@as(u16, 40), app.tree.width); // a fifth of 200, the snap's own rule
        try app.resize(160, 40);
        try command.run(&app, .{ .static = .@"view.activity_explorer" });
        try t.expectEqual(@as(u16, 32), app.tree.width);
    }
    {
        var cfg: Config = .{};
        cfg.ui.tree_width = 36;
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = App.scratch_workspace, .cols = 200, .rows = 40 });
        defer app.deinit();
        try t.expectEqual(@as(u16, 36), app.tree.width);
        try app.resize(80, 24);
        try t.expectEqual(@as(u16, 36), app.tree.width);
        pinTreeWidth(&app, 50);
        resetTreeWidth(&app);
        try t.expectEqual(@as(u16, 36), app.tree.width);
    }
}

test "git mode's snap follows a resize — a fifth of the new width — and leaving gives back the width the window now asks for" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = App.scratch_workspace, .cols = 200, .rows = 60 });
    defer app.deinit();
    try std.testing.expectEqual(@as(u16, 40), app.tree.width);
    // Git mode's entry, as `git_palette.enter` stashes and snaps.
    app.git_palette.pre_size = .{ .side = .left, .n = size(&app, .left) };
    app.git_palette.active = true;
    snapGit(&app);
    try std.testing.expectEqual(@as(u16, 40), app.tree.width);
    try app.resize(120, 40);
    try std.testing.expectEqual(@as(u16, 24), app.tree.width);
    try std.testing.expectEqual(@as(u16, 30), app.git_palette.pre_size.?.n);
    // A pinned width is kept for the way out, and the snap still moves.
    pinTreeWidth(&app, 52);
    app.git_palette.pre_size.?.n = 52;
    snapGit(&app);
    try app.resize(160, 40);
    try std.testing.expectEqual(@as(u16, 32), app.tree.width);
    try std.testing.expectEqual(@as(u16, 52), app.git_palette.pre_size.?.n);
    app.git_palette.active = false;
    app.git_palette.pre_size = null;
}
