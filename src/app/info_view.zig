//! The info view's words and state (`ui/info_view.zig` paints them).
//! What the box says is Rust `hover_help.rs`'s ladder: the thing the
//! pointer rests on (a chip, a tree row, a tab — from the previous
//! frame's hits, so the box can be laid out before this frame paints),
//! else what the keyboard focus is on (the tree's cursor row, past the
//! first), else the active pane, else the one-liner for the focused
//! surface — `Sidebar` / `Editor` / `Right panel`. An overlay is not a
//! surface: the ladder reads the one the keys go back to (`focusUnder`).
//!
//! The hover rung reads the dictionary first (`app/info_view_copy.zig`
//! — a curated `Entry` per target, split by area) and only then
//! `discovery.describe`, the one-line tooltip; a fallback is marked on
//! screen with a dim *no help written yet* aside so the gap is visible
//! where it is, not only in `zig build hover-audit`.
//!
//! **The box is sticky under the pointer.** The pointer has to cross
//! onto the box to click a link row, and the box itself says nothing
//! new — so while the pointer rests on the box the ladder keeps the
//! last target it resolved from (`State.sticky`), and a link's press
//! re-resolves that target: the command it runs, the Settings row it
//! opens, the URL, the manual section a `docs` link renders
//! (`app/docs.zig`), or the prompt an `Ask about this` link sends
//! (`info_view_copy.askPrompt`), built at press time from the state of
//! that moment. Nothing from the frame arena is kept between frames.
//!
//! **The way to the box is safe.** The pointer leaving a target for
//! the box crosses other targets on the way — the tree's rows, the
//! empty space under them — and each used to take the box over, so a
//! link was never reachable. Leaving a target starts a grace window
//! (`ui.hover_help_grace_ms`): while it runs and the pointer keeps
//! heading for the box — no farther from it than the step before, and
//! inside the column (± `corridor_margin`) or the triangle from where it
//! left toward the box's near edge (`inCorridor`) — the box keeps the
//! entry it had. A step outside the corridor switches at once; the
//! window running out while the pointer rests switches too (the tick's
//! one deadline, `nextDeadlineMs`, not a timer of its own). On the box
//! the entry is held until the pointer leaves it, whatever the event —
//! a wheel notch or a press included.
//!
//! **A pin holds it outright.** The pin chip on the title row (and
//! `help.pin_toggle`) freezes the entry the box shows — its words and
//! what its links do, copied onto the gpa (`Pinned`), since the frame
//! that resolved them is gone by the next paint — until the pin is
//! pressed again or Esc is pressed in the box.
//!
//! The kebab's menu is the one row Rust has: turn the panel off.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Mouse = @import("../core/key.zig").Mouse;
const command = @import("../core/command.zig");
const CommandId = command.CommandId;
const hit_mod = @import("../ui/hit.zig");
const HitTarget = hit_mod.HitTarget;
const view = @import("../ui/info_view.zig");
const tree_view = @import("../ui/tree_view.zig");
const icons = @import("../ui/icons.zig");
const discovery = @import("discovery.zig");
const sessions = @import("../sessions.zig");
const copy = @import("info_view_copy.zig");
const settings_app = @import("settings.zig");
const git_app = @import("git.zig");
const docs = @import("docs.zig");
const Rect = @import("../ui/rect.zig");

pub const Copy = view.Copy;
pub const Part = view.Part;
pub const Entry = copy.Entry;

pub const max_links = copy.max_links;

/// The aside a fallback carries — the on-screen mark of a control
/// without an entry.
pub const no_help_aside = "no help written yet";

pub const State = struct {
    scroll: u16 = 0,
    /// From the last paint, so the wheel knows where it stops.
    max_scroll: u16 = 0,
    /// A hash of the last copy's title: a new topic scrolls back to the top.
    topic: u64 = 0,
    /// What the `→` rows do, by position.
    links: [max_links]?copy.LinkAction = @splat(null),
    /// The last hover target the ladder resolved from — kept while the
    /// pointer is on the box, so the links stay under the hand. A
    /// `.link` target carries an arena slice and is never kept.
    sticky: ?HitTarget = null,
    /// The target under the pointer for this frame, read by
    /// `snapshotHover` BEFORE the frame arena resets — the hits live on
    /// that arena, and the ladder allocates on it.
    hover_target: ?HitTarget = null,
    /// A hovered link's url, copied out of the dying frame.
    link_url: [512]u8 = undefined,
    /// Where the box was painted last frame (null while it is not):
    /// what the corridor heads for.
    rect: ?Rect = null,
    /// The pointer at the previous snapshot — the corridor asks whether
    /// the pointer is still closing on the box.
    last_ptr: ?Pt = null,
    /// The pointer was on the box at the previous snapshot: leaving the
    /// box is not leaving a target, and starts no grace.
    was_on_box: bool = false,
    /// The entry held while the pointer travels to the box.
    grace: ?Grace = null,
    /// The hover target the last pick resolved its copy from, if any —
    /// what a pin asks its `Ask` link about.
    shown: ?HitTarget = null,
    /// The pinned entry: while set, it is what the box says.
    pinned: ?Pinned = null,

    pub fn deinit(st: *State) void {
        if (st.pinned) |*p| p.deinit();
        st.pinned = null;
    }
};

/// A pinned entry, owned: the copy and its link actions deep-copied off
/// the frame arena, and the target it came from (never a `.link`, whose
/// url is an arena slice) for an `Ask` link.
pub const Pinned = struct {
    arena: std.heap.ArenaAllocator,
    copy: Copy,
    links: [max_links]?copy.LinkAction,
    target: ?HitTarget,

    pub fn init(gpa: Allocator, c: Copy, links: [max_links]?copy.LinkAction, target: ?HitTarget) Allocator.Error!Pinned {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const shortcuts = try a.alloc(view.Shortcut, c.shortcuts.len);
        for (c.shortcuts, shortcuts) |s, *d| d.* = .{ .chord = try a.dupe(u8, s.chord), .label = try a.dupe(u8, s.label) };
        const try_it = try a.alloc(view.Link, c.try_it.len);
        for (c.try_it, try_it) |l, *d| d.* = .{ .label = try a.dupe(u8, l.label), .kind = l.kind };
        var owned: [max_links]?copy.LinkAction = @splat(null);
        for (links, 0..) |l, i| owned[i] = if (l) |act| switch (act) {
            .url => |u| .{ .url = try a.dupe(u8, u) },
            .docs => |d| .{ .docs = .{ .doc = d.doc, .section = try a.dupe(u8, d.section) } },
            else => act,
        } else null;
        return .{
            .copy = .{
                .title = try a.dupe(u8, c.title),
                .body = try a.dupe(u8, c.body),
                .aside = if (c.aside) |x| try a.dupe(u8, x) else null,
                .aside_first = c.aside_first,
                .shortcuts = shortcuts,
                .try_it = try_it,
            },
            .links = owned,
            .target = if (target) |tg| (if (tg == .link) null else tg) else null,
            .arena = arena,
        };
    }

    pub fn deinit(p: *Pinned) void {
        p.arena.deinit();
    }
};

/// Pinned or not — what the title row's chip shows.
pub fn isPinned(app: *const App) bool {
    return app.info_view.pinned != null;
}

/// `help.pin_toggle` and the pin chip: freeze the entry the box shows,
/// or let it go.
pub fn togglePin(app: *App) Allocator.Error!void {
    const st = &app.info_view;
    app.needs_render = true;
    if (st.pinned) |*p| {
        p.deinit();
        st.pinned = null;
        app.toast("info panel: unpinned", .{});
        return;
    }
    const c = try pickCopy(app, app.frame.allocator());
    st.pinned = try Pinned.init(app.gpa, c, st.links, st.shown);
    app.toast("info panel: pinned \u{2014} {s}", .{st.pinned.?.copy.title});
}

/// Let a pinned entry go (Esc in the box); false when nothing was pinned.
pub fn unpin(app: *App) bool {
    const st = &app.info_view;
    if (st.pinned) |*p| {
        p.deinit();
        st.pinned = null;
        app.needs_render = true;
        return true;
    }
    return false;
}

pub const table = .{
    .@"help.pin_toggle" = &pinCommand,
};

fn pinCommand(app: *App) command.CommandError!void {
    try togglePin(app);
}

pub const Pt = struct { x: u16, y: u16 };

/// The entry the box keeps while the pointer heads for it: the target
/// it came from, where the pointer left it, and when the window shuts.
pub const Grace = struct {
    target: HitTarget,
    anchor: Pt,
    until_ms: i64,
};

/// Cells either side of the column the pointer may stray and still be
/// on its way down (or up) to the box.
pub const corridor_margin: u16 = 2;

/// Whether the pointer at `now` is still on its way to `box`: no
/// farther from it on either axis than at `prev`, and inside the
/// column's band (± `corridor_margin`) or the triangle from `anchor`
/// (where it left its target) to the box's near edge, widened by the
/// margin at the box's end.
pub fn inCorridor(anchor: Pt, prev: Pt, now: Pt, box: Rect) bool {
    if (box.isEmpty()) return false;
    const dp = gap(prev, box);
    const dn = gap(now, box);
    if (dn.x > dp.x or dn.y > dp.y) return false;
    if (now.x + corridor_margin >= box.x and now.x < box.right() + corridor_margin) return true;
    // The near edge's two ends, widened by the margin.
    const m: i32 = corridor_margin;
    const bx0: i32 = @as(i32, box.x) - m;
    const bx1: i32 = @as(i32, box.right()) - 1 + m;
    const by0: i32 = @as(i32, box.y) - m;
    const by1: i32 = @as(i32, box.bottom()) - 1 + m;
    const ax: i32 = anchor.x;
    const ay: i32 = anchor.y;
    const c1, const c2 = if (ay < box.y)
        .{ [2]i32{ bx0, box.y }, [2]i32{ bx1, box.y } }
    else if (ay >= box.bottom())
        .{ [2]i32{ bx0, @as(i32, box.bottom()) - 1 }, [2]i32{ bx1, @as(i32, box.bottom()) - 1 } }
    else if (ax < box.x)
        .{ [2]i32{ box.x, by0 }, [2]i32{ box.x, by1 } }
    else
        .{ [2]i32{ @as(i32, box.right()) - 1, by0 }, [2]i32{ @as(i32, box.right()) - 1, by1 } };
    return inTriangle(.{ ax, ay }, c1, c2, .{ now.x, now.y });
}

/// The pointer's distance to `box` along each axis (0 inside its span).
fn gap(p: Pt, box: Rect) Pt {
    const dx: u16 = if (p.x < box.x) box.x - p.x else if (p.x >= box.right()) p.x - (box.right() - 1) else 0;
    const dy: u16 = if (p.y < box.y) box.y - p.y else if (p.y >= box.bottom()) p.y - (box.bottom() - 1) else 0;
    return .{ .x = dx, .y = dy };
}

/// `p` inside (or on an edge of) the triangle `a b c`.
fn inTriangle(a: [2]i32, b: [2]i32, c: [2]i32, p: [2]i32) bool {
    const d1 = cross(a, b, p);
    const d2 = cross(b, c, p);
    const d3 = cross(c, a, p);
    const neg = d1 < 0 or d2 < 0 or d3 < 0;
    const pos = d1 > 0 or d2 > 0 or d3 > 0;
    return !(neg and pos);
}

fn cross(a: [2]i32, b: [2]i32, p: [2]i32) i64 {
    return @as(i64, b[0] - a[0]) * (p[1] - a[1]) - @as(i64, b[1] - a[1]) * (p[0] - a[0]);
}

/// The grace window's end is a frame: the box switches to whatever the
/// resting pointer is on. One deadline, read by `App.nextDeadlineMs`.
pub fn nextDeadlineMs(app: *const App) ?i64 {
    const g = app.info_view.grace orelse return null;
    return g.until_ms;
}

/// `App.tick`: a grace window that ran out asks for the frame that
/// shows what the pointer rests on now.
pub fn tick(app: *App, now: i64) void {
    const g = app.info_view.grace orelse return;
    if (now < g.until_ms) return;
    // The held entry is let go with the window: what the pointer rests
    // on takes the box at the next frame.
    app.info_view.grace = null;
    app.info_view.sticky = null;
    app.needs_render = true;
}

/// Read the previous frame's hits while they are still whole: what the
/// pointer rests on, with the box's own cells resolving to the last
/// target (`State.sticky`). `render` calls this before `frame.begin`.
pub fn snapshotHover(app: *App) void {
    const st = &app.info_view;
    st.hover_target = null;
    const h = app.hover orelse {
        st.grace = null;
        st.last_ptr = null;
        st.was_on_box = false;
        return;
    };
    const ptr: Pt = .{ .x = h.x, .y = h.y };
    const prev = st.last_ptr;
    const was_on_box = st.was_on_box;
    st.last_ptr = ptr;
    const under = app.hits.at(h.x, h.y);
    // On the box, whatever brought the pointer there — a move, a wheel
    // notch, a press on a link — the box holds what it had.
    if (under != null and under.? == .info_view) {
        st.was_on_box = true;
        st.grace = null;
        st.hover_target = st.sticky;
        return;
    }
    st.was_on_box = false;
    if (!app.hover_live) {
        st.grace = null;
        return;
    }
    // On the way to the box: the entry the pointer left stays while it
    // keeps heading there and the window is open.
    if (graceHolds(app, ptr, prev, was_on_box, under)) {
        st.hover_target = st.sticky;
        return;
    }
    // Over nothing, the entry is let go: a later step toward the box
    // must not bring back one the pointer already left behind.
    const target = under orelse {
        st.sticky = null;
        return;
    };
    st.sticky = if (target == .link) null else target;
    // A link's url is an arena slice about to die: copy it into the
    // state's own buffer (a longer one is cut — the copy names it).
    if (target == .link) {
        const n = @min(target.link.url.len, st.link_url.len);
        @memcpy(st.link_url[0..n], target.link.url[0..n]);
        st.hover_target = .{ .link = .{ .url = st.link_url[0..n] } };
        return;
    }
    st.hover_target = target;
}

/// Whether the box keeps the entry it had while the pointer is at
/// `ptr` over `under`: a grace window is open (or opens now, as the
/// pointer leaves the target it had) and the pointer is still in the
/// corridor to the box. A new target outside the corridor ends it.
fn graceHolds(app: *App, ptr: Pt, prev: ?Pt, was_on_box: bool, under: ?HitTarget) bool {
    const st = &app.info_view;
    const box = st.rect orelse {
        st.grace = null;
        return false;
    };
    const kept = st.sticky orelse {
        st.grace = null;
        return false;
    };
    // Back on the target the box already shows: nothing to hold.
    if (under) |u| if (sameTarget(u, kept)) {
        st.grace = null;
        return false;
    };
    const from = prev orelse return false;
    if (st.grace == null) {
        // A pointer that has not moved is resting, not travelling.
        if (from.x == ptr.x and from.y == ptr.y) return false;
        const ms = app.cfg.ui.hover_help_grace_ms;
        // Leaving the box, or a pointer that was not resting on the
        // entry's target, starts nothing.
        if (ms == 0 or was_on_box) return false;
        st.grace = .{ .target = kept, .anchor = from, .until_ms = app.now_ms + ms };
    }
    const g = st.grace.?;
    if (app.now_ms >= g.until_ms or !inCorridor(g.anchor, from, ptr, box)) {
        st.grace = null;
        return false;
    }
    return true;
}

/// Two targets name the same thing (a `.link`'s url compared by text).
fn sameTarget(a: HitTarget, b: HitTarget) bool {
    if (a == .link or b == .link) return a == .link and b == .link and std.mem.eql(u8, a.link.url, b.link.url);
    return std.meta.eql(a, b);
}

/// The copy for this frame — and the state it implies: the links the
/// rows will run, the scroll reset when the topic changed.
pub fn pick(app: *App, arena: Allocator) Allocator.Error!Copy {
    const c = try pickCopy(app, arena);
    const st = &app.info_view;
    const topic = std.hash.Wyhash.hash(0, c.title);
    if (topic != st.topic) {
        st.topic = topic;
        st.scroll = 0;
    }
    return c;
}

fn pickCopy(app: *App, arena: Allocator) Allocator.Error!Copy {
    const st = &app.info_view;
    st.links = @splat(null);
    st.shown = null;
    if (st.pinned) |*p| {
        st.links = p.links;
        st.shown = p.target;
        return p.copy;
    }
    if (st.hover_target) |target| if (try hoverCopy(app, arena, target)) |c| {
        st.shown = if (target == .link) null else target;
        return c;
    };
    if (try focusCopy(app, arena)) |c| return c;
    if (try activePaneCopy(app, arena)) |c| return c;
    return emptyCopy(app);
}

/// What the pointer rests on: the dictionary's entry, else the
/// tooltip's line marked as a fallback. The box itself says nothing
/// new.
fn hoverCopy(app: *App, arena: Allocator, target: HitTarget) Allocator.Error!?Copy {
    if (target == .info_view) return null;
    if (try copy.lookup(app, arena, target)) |entry| {
        const m = try copy.materialize(app, arena, entry);
        app.info_view.links = m.actions;
        return m.copy;
    }
    // A menu row without an entry: the command's title and chord,
    // rather than the tooltip's `opens more rows` — marked all the same.
    if (target == .menu_item) if (try copy.menus.rowFallback(app, arena, target.menu_item.menu, target.menu_item.idx)) |f| return .{ .title = f.title, .body = f.body, .aside = no_help_aside, .aside_first = true };
    const tip = (try discovery.describe(app, arena, target)) orelse return null;
    return .{ .title = tip.title, .body = tip.detail orelse "", .aside = no_help_aside, .aside_first = true };
}

/// Whether `target` resolves to a curated entry, the tooltip's fallback,
/// or nothing — what the audit tallies.
pub const Resolution = enum { curated, fallback, none };

pub fn resolve(app: *App, arena: Allocator, target: HitTarget) Allocator.Error!Resolution {
    if (target == .info_view) return .curated;
    if (try copy.lookup(app, arena, target) != null) return .curated;
    if (try discovery.describe(app, arena, target) != null) return .fallback;
    return .none;
}

/// The surface the keys go back to under an overlay: the prompt's, the
/// confirm's or the menu's way back, else the active pane (the tree
/// when there is none). Rust keeps `app.focus` on the surface while a
/// picker or a confirm is up, so its ladder never sees the overlay —
/// the delete box shows the row's doc and the picker the `Sidebar`
/// line. The statusline's mode chip resolves the same way.
fn focusUnder(app: *const App) app_mod.FocusId {
    const fallback: app_mod.FocusId = if (app.active) |a| .{ .pane = a } else .tree;
    return switch (app.focus) {
        .overlay => switch (app.overlay) {
            .prompt => |p| p.return_focus orelse fallback,
            .confirm => |c| c.return_focus orelse fallback,
            .menu => |m| m.return_focus,
            else => fallback,
        },
        else => app.focus,
    };
}

/// The tree's cursor row, flattened as Rust's focus ladder shows it.
/// Nothing on a header, and nothing at rest on the first row — the
/// `Sidebar` copy stays until the user walks.
fn focusCopy(app: *App, arena: Allocator) Allocator.Error!?Copy {
    if (focusUnder(app) != .tree) return null;
    const rows = app.tree.rows.items;
    if (app.tree.cursor >= rows.len) return null;
    const row = rows[app.tree.cursor];
    if (row.header) return null;
    var first: usize = 0;
    while (first < rows.len and rows[first].header) : (first += 1) {}
    if (app.tree.cursor == first) return null;
    const m = try copy.materialize(app, arena, try copy.tree.rowOrGeneric(arena, row.name(), row.is_dir));
    return try view.flatten(arena, m.copy);
}

/// The active pane's summary (Rust `describe_active_pane`).
fn activePaneCopy(app: *App, arena: Allocator) Allocator.Error!?Copy {
    const id = app.active orelse return null;
    const p = app.panes.get(id) orelse return null;
    return switch (p.*) {
        .editor => |*e| try editorCopy(app, arena, p, e),
        .request => .{ .title = p.title(), .body = "Request pane — Enter to send, Ctrl+S saves as .http/.curl." },
        // The title is the pane's label — `ghostty (zsh)` on a shell:
        // the terminal mnml runs inside, then the child. The chords
        // are the active profile's, read off the keymap. Rust's copy
        // named a detach and a kill chord; mnml binds neither, and
        // closing the tab is what ends the child.
        // A Claude / Codex pane is titled by its session's name — the
        // one its tab and SESSIONS card read (`sessions.nameOf`).
        .pty => blk: {
            const session = sessions.paneName(app, id);
            break :blk .{
                .title = if (session) |n| try arena.dupe(u8, n.text) else p.title(),
                .body = try std.fmt.allocPrint(arena, "{s} \u{2014} {s}.", .{ if (session != null) "Session pane" else "Terminal pane", try copy.chordLine(app, arena, &.{
                    .{ .command = .@"term.restart", .label = "Restart" },
                    .{ .command = .@"term.rename", .label = "Rename" },
                    .{ .command = .@"buffer.close", .label = "Close" },
                }) }),
            };
        },
        .md_preview => .{ .title = p.title(), .body = "Rendered markdown preview — click header chip to jump back to source." },
        // The ZON tree: the focused field's doc line (docs/CONFIG.md's
        // comment for a config key, else its type).
        .zon => |*z| blk: {
            if (z.stale) try z.rebuildRows();
            const row = z.current() orelse break :blk .{ .title = p.title(), .body = "ZON tree — Enter edits a field, ←→ adjust it, / filters by path, e opens the source." };
            break :blk .{ .title = try std.fmt.allocPrint(arena, "{s}", .{row.path}), .body = try z.docLine(arena, row) };
        },
        // A one-shot answer, not a session: it has no prompt of its own.
        .ai => .{ .title = p.title(), .body = "One-shot AI answer — r re-ask · c cancel · a apply the code block (a reviewed diff) · p continue in Claude Code · y copy · q close." },
        // Rust's `describe_active_pane` says nothing for the graph: the
        // box keeps the sidebar's own words in git mode.
        .git_graph => null,
        else => .{ .title = p.title() },
    };
}

/// `name  ·  LANG  ·  L:C  ·  N lines` with the editor's chords; the
/// identifier under the cursor first when there is one. The chords are
/// the active profile's (D4b): `[gd] Definition · [K] Hover` for vim,
/// `[F12] Definition · [Ctrl+K Ctrl+I] Hover` for standard.
fn editorCopy(app: *App, arena: Allocator, p: *const app_mod.Pane, e: *const app_mod.EditorPane) Allocator.Error!Copy {
    const ed = e.buf.editor;
    const pos = ed.rowCol();
    const title = p.title();
    var lang_buf: [16]u8 = undefined;
    const lang: []const u8 = if (e.buf.doc.path) |path| (if (icons.extensionOf(std.fs.path.basename(path))) |ext| (if (ext.len <= lang_buf.len) std.ascii.upperString(&lang_buf, ext) else "TEXT") else "TEXT") else "TEXT";
    const sym = wordUnderCursor(ed.doc.bytes(), ed.cursor);
    if (sym.len > 0 and sym.len <= 48) return .{
        .title = try std.fmt.allocPrint(arena, "{s}  ·  {s}  ·  {s}  ·  L{d}:{d}", .{ sym, lang, title, pos.row + 1, pos.col + 1 }),
        .body = try copy.chordLine(app, arena, &.{
            .{ .command = .@"lsp.goto_definition", .label = "Definition" },
            .{ .command = .@"lsp.references", .label = "References" },
            .{ .command = .@"lsp.hover", .label = "Hover" },
            .{ .command = .@"lsp.rename", .label = "Rename" },
        }),
    };
    const lines = @max(ed.lineCount(), 1);
    return .{
        .title = try std.fmt.allocPrint(arena, "{s}  ·  {s}  ·  L{d}:{d}  ·  {d} lines{s}", .{ title, lang, pos.row + 1, pos.col + 1, lines, if (p.dirty()) " · unsaved" else "" }),
        .body = if (e.pinned) "Pinned — stays at the front of the bufferline." else try copy.chordLine(app, arena, &.{
            .{ .command = .@"lsp.goto_definition", .label = "Definition" },
            .{ .command = .@"lsp.references", .label = "References" },
            .{ .command = .@"lsp.code_action", .label = "Code actions" },
            .{ .command = .@"picker.files", .label = "Files" },
        }),
    };
}

/// The chord the copy shows for `id` under the active profile
/// (`info_view_copy.chordOf`).
pub const chordOf = copy.chordOf;

/// The identifier the cursor is in or on; empty between tokens.
pub fn wordUnderCursor(text: []const u8, cursor: usize) []const u8 {
    if (text.len == 0) return "";
    const at = @min(cursor, text.len - 1);
    if (!isWord(text[at])) return "";
    var start = at;
    while (start > 0 and isWord(text[start - 1])) start -= 1;
    var end = at + 1;
    while (end < text.len and isWord(text[end])) end += 1;
    return text[start..end];
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Rust's box title for a section: its label in title case (`Todos`).
fn sectionTitle(p: app_mod.PanelId) []const u8 {
    return switch (p) {
        .todos => "Todos",
        .notes => "Notes",
        .findings => "Findings",
        .sessions => "Sessions",
        .git => "Source control",
        .diagnostics => "Diagnostics",
        .http => "HTTP",
        .outline => "Outline",
        .debug => "Run and debug",
        .integrations => "Integrations",
        .scripts => "Scripts",
        .script => "Script section",
        .search => "Search",
        .jobs => "Jobs",
    };
}

/// The one-liner per focused surface.
fn emptyCopy(app: *App) Copy {
    return switch (focusUnder(app)) {
        .tree => .{ .title = "Sidebar", .body = "Arrows or j/k walk rows. Enter opens the selection. Ctrl+Shift+P opens the palette." },
        // The box is titled with the section (Rust's `Todos`), whichever
        // column it is in.
        .panel => |p| if (p == .git and app.git_palette.active)
            .{ .title = "Sidebar", .body = "Arrows or j/k walk rows. Enter opens the selection. Ctrl+Shift+P opens the palette." }
        else if (p == .integrations)
            // Rust's words for the INTEGRATIONS section.
            .{ .title = sectionTitle(p), .body = "Installed integrations. Enter fires the command. Right-click for Configure / Uninstall." }
        else if (p == .search)
            // Rust's words for the SEARCH section.
            .{ .title = sectionTitle(p), .body = "Workspace search. `/` filters. Enter jumps to the match." }
        else
            .{ .title = sectionTitle(p), .body = "Arrows walk rows. Enter jumps to the source. F6 cycles focus." },
        // In git mode the graph pane says nothing of its own and Rust's box
        // shows the sidebar's words.
        .pane => |id| if (app.git_palette.active and app.panes.get(id) != null and app.panes.get(id).?.* == .git_graph)
            .{ .title = "Sidebar", .body = "Arrows or j/k walk rows. Enter opens the selection. Ctrl+Shift+P opens the palette." }
        else
            .{ .title = "Editor", .body = "Hover a chip, tab, or tree row for help. Ctrl+Shift+P opens the palette." },
        // The start surface (`app/welcome.zig`).
        .welcome => .{ .title = "Start", .body = "j/k walk a list, Tab moves to the next. Enter acts on the row. ? opens the cheatsheet; Esc gives the keys back to the tree." },
        // `focusUnder` never says so: an overlay names its surface.
        .overlay => unreachable,
    };
}

// ─── the dictionary, re-exported for its callers ────────────────────────

/// The curated copy for a tree row (`info_view_copy/tree.zig`).
pub fn treeRowCopy(arena: Allocator, label: []const u8, is_dir: bool) Allocator.Error!?Entry {
    return copy.tree.rowEntry(arena, label, is_dir);
}

/// A header chip's copy, with its links resolved into the app's state.
pub fn chipCopy(app: *App, c: tree_view.Chip) Allocator.Error!Copy {
    const m = try copy.materialize(app, app.frame.allocator(), copy.tree.chip(c));
    app.info_view.links = m.actions;
    return m.copy;
}

// ─── mouse ──────────────────────────────────────────────────────────────

/// A press or wheel on the box: the kebab drops its menu, a link row
/// does what it names, the wheel scrolls, anything else is swallowed.
pub fn mouse(app: *App, part: Part, m: Mouse, count: u16) Allocator.Error!void {
    const st = &app.info_view;
    switch (m.kind) {
        // A row per wheel event, as Rust's hover-help strip.
        .scroll_up => st.scroll -|= @max(count, 1),
        .scroll_down => st.scroll = @min(st.scroll + @max(count, 1), st.max_scroll),
        .press => {
            // right-click: the kebab's menu on either button.
            if (m.button == .right and part == .kebab) return openKebabMenu(app, m.x, m.y + 1);
            if (m.button != .left) return;
            switch (part) {
                .kebab => try openKebabMenu(app, m.x, m.y + 1),
                .pin => try togglePin(app),
                .try_it => |i| if (i < max_links) if (st.links[i]) |action| try runLink(app, action),
                .body => {},
            }
        },
        else => {},
    }
    app.needs_render = true;
}

/// What a link row does when pressed.
fn runLink(app: *App, action: copy.LinkAction) Allocator.Error!void {
    switch (action) {
        .command => |id| command.run(app, .{ .static = id }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .settings => |row| try openSettingsRow(app, row),
        .url => |url| git_app.openExternal(app, url),
        .docs => |d| _ = try docs.open(app, d.doc, d.section),
        .ask => {
            // A pinned entry asks about what it was pinned from.
            const target = (if (app.info_view.pinned) |p| p.target else app.info_view.sticky) orelse return;
            const arena = app.frame.allocator();
            const entry = (try copy.lookup(app, arena, target)) orelse return;
            try copy.ask(app, arena, target, entry);
        },
    }
}

/// The Settings overlay, opened with the cursor on the row `row`
/// (an index into `settings.rows`) — the search-jump a `⚙` link does.
pub fn openSettingsRow(app: *App, row: u16) Allocator.Error!void {
    try settings_app.open(app);
    const list = try settings_app.items(app, app.frame.allocator());
    const st = &app.overlay.settings;
    for (list, 0..) |it, i| switch (it) {
        .row => |r| if (r.id == row) {
            st.ui.cursor = i;
            st.ui.settle(list);
            return;
        },
        else => {},
    };
}

/// The sidebar menu: the one row Rust has.
pub fn openKebabMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const items = try app.gpa.alloc(command.MenuItem, 1);
    errdefer app.gpa.free(items);
    items[0] = .{ .label = "Turn off info panel (Settings → UI to bring back)", .action = .{ .command = .@"view.toggle_hover_help" } };
    try app.openMenu("Sidebar", items, x, y);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Key = app_mod.Key;

fn realRoot(tmp: *std.testing.TmpDir, gpa: Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}

test "the ladder: Sidebar at rest, the row past the first when the tree walks, the file summary once one is open, the Editor line on a scratch" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "src");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/main.rs", .data = "fn main() {}\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "README.md", .data = "# demo\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 120, .rows = 40 });
    defer app.deinit();
    try app.tree.refresh(&app);
    app.focus = .tree;
    const arena = app.frame.allocator();
    // Row 0 (`src`) at rest: the Sidebar one-liner.
    const rest = try pick(&app, arena);
    try t.expectEqualStrings("Sidebar", rest.title);
    try t.expect(std.mem.startsWith(u8, rest.body, "Arrows or j/k walk rows."));
    // Walk to main.rs: the curated Rust copy, flattened with its chords.
    app.tree.cursor = 1;
    const rs = try pick(&app, arena);
    try t.expectEqualStrings("main.rs — Rust source", rs.title);
    try t.expect(std.mem.indexOf(u8, rs.body, "Compiled with cargo.") != null);
    try t.expect(std.mem.indexOf(u8, rs.body, "[Enter] Open in the active pane  [Ctrl+Enter] Open in a horizontal split") != null);
    try t.expectEqual(@as(usize, 0), rs.shortcuts.len);
    // A directory row.
    app.tree.cursor = 0;
    app.tree.cursor = app.tree.rowOf("src").?;
    try t.expectEqualStrings("Sidebar", (try pick(&app, arena)).title);
    // Open README.md: focus moves to the pane and the summary names it.
    app.tree.cursor = app.tree.rowOf("README.md").?;
    try app.tree.activate(&app, app.tree.cursor);
    const md = try pick(&app, arena);
    try t.expect(std.mem.startsWith(u8, md.title, "README.md"));
    try t.expect(std.mem.indexOf(u8, md.title, "MD") != null or std.mem.indexOf(u8, md.title, "L1:1") != null or app.panes.get(app.active.?).?.* == .md_preview);
    // A scratch buffer at 1:1 on empty text: the quiet fallback with L:C.
    _ = try app.openScratch();
    app.focus = .{ .pane = app.active.? };
    const scratch = try pick(&app, arena);
    try t.expect(std.mem.indexOf(u8, scratch.title, "L1:1") != null);
    try t.expect(std.mem.indexOf(u8, scratch.title, "1 lines") != null);
    try t.expect(std.mem.indexOf(u8, scratch.body, "[F12] Definition") != null);
    try t.expect(std.mem.indexOf(u8, scratch.body, "[Ctrl+.] Code actions") != null);
    try t.expect(std.mem.indexOf(u8, scratch.body, "[Ctrl+P] Files") != null);
}

test "the ladder under an overlay: the surface beneath, as Rust's focus never leaves it — the picker over the tree says Sidebar, the delete box keeps the row, a menu from the tree too; the git palette says Sidebar; a hovered chip beats them all" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "src");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/main.rs", .data = "fn main() {}\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "README.md", .data = "# demo\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 120, .rows = 40 });
    defer app.deinit();
    try app.tree.refresh(&app);
    app.focus = .tree;
    const arena = app.frame.allocator();
    const sidebar = "Sidebar";
    // The picker (any overlay without a way back) over the tree with
    // nothing open: the Sidebar line, not the Editor's.
    app.overlay = .discovery;
    app.focus = .overlay;
    try t.expectEqualStrings(sidebar, (try pick(&app, arena)).title);
    // The git palette with nothing open (its graph pane says nothing of
    // its own): the sidebar's words from its panel, and from a prompt
    // over it with no way back; the panel's own name once it is off.
    app.overlay = .none;
    app.git_palette.active = true;
    app.focus = .{ .panel = .git };
    try t.expectEqualStrings(sidebar, (try pick(&app, arena)).title);
    app.overlay = .{ .prompt = .{ .state = .{ .title = "Commit" }, .purpose = .goto_line } };
    app.focus = .overlay;
    try t.expectEqualStrings(sidebar, (try pick(&app, arena)).title);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    app.git_palette.active = false;
    app.focus = .{ .panel = .git };
    try t.expectEqualStrings("Source control", (try pick(&app, arena)).title);
    // The tree walked to main.rs, then its delete box (the confirm's way
    // back is the tree): the row's doc stays under the box.
    app.overlay = .none;
    app.focus = .tree;
    app.tree.cursor = app.tree.rowOf("src/main.rs") orelse app.tree.rowOf("main.rs").?;
    try t.expectEqualStrings("main.rs — Rust source", (try pick(&app, arena)).title);
    const msg = try app.gpa.dupe(u8, "Delete src/main.rs?");
    app.overlay = .{ .confirm = .{ .state = .{ .title = "Delete", .message = msg, .choices = &App.close_choices }, .purpose = .quit, .message = msg, .return_focus = .tree } };
    app.focus = .overlay;
    try t.expectEqualStrings("main.rs — Rust source", (try pick(&app, arena)).title);
    // A confirm with no way back and nothing open falls to the tree too.
    app.overlay.confirm.return_focus = null;
    try t.expectEqualStrings("main.rs — Rust source", (try pick(&app, arena)).title);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // The kebab's menu opened from the tree remembers the tree.
    app.focus = .tree;
    try openKebabMenu(&app, 5, 5);
    try t.expect(app.focus == .overlay);
    try t.expectEqualStrings("main.rs — Rust source", (try pick(&app, arena)).title);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // A hovered chip beats the walked row.
    app.focus = .tree;
    try app.render();
    var chip_at: ?struct { x: u16, y: u16 } = null;
    for (app.hits.items.items) |e| if (e.target == .tree_chip and e.target.tree_chip == .refresh) {
        chip_at = .{ .x = e.rect.x, .y = e.rect.y };
    };
    app.hover = .{ .x = chip_at.?.x, .y = chip_at.?.y };
    app.hover_live = true;
    snapshotHover(&app);
    try t.expectEqualStrings("Refresh tree", (try pick(&app, arena)).title);
    app.hover_live = false;
    snapshotHover(&app);
    // A file open with the tree focused at its first row: Rust's focus
    // rung says nothing there and the active pane's summary shows —
    // walked past it, the row's doc wins over the open file.
    try app.tree.activate(&app, app.tree.cursor);
    try t.expect(app.active != null);
    app.focus = .tree;
    app.tree.cursor = 0;
    const at_rest = try pick(&app, arena);
    try t.expect(std.mem.startsWith(u8, at_rest.title, "fn  ·  RS  ·  main.rs"));
    try t.expectEqualStrings("[F12] Definition · [Shift+F12] References · [Ctrl+K Ctrl+I] Hover · [F2] Rename", at_rest.body);
    // The vim profile reads its own chords.
    try app.setInputStyle(.vim);
    try t.expectEqualStrings("[gd] Definition · [gr] References · [K] Hover · [Space r a] Rename", (try pick(&app, arena)).body);
    try app.setInputStyle(.standard);
    app.tree.cursor = app.tree.rowOf("src/main.rs") orelse app.tree.rowOf("main.rs").?;
    try t.expectEqualStrings("main.rs — Rust source", (try pick(&app, arena)).title);
    // The picker over that: its way back is the pane, so the summary.
    app.overlay = .discovery;
    app.focus = .overlay;
    try t.expect(std.mem.startsWith(u8, (try pick(&app, arena)).title, "fn  ·  RS  ·  main.rs"));
    app.overlay = .none;
    // The pane focused: the summary, whatever the tree's cursor.
    app.focus = .{ .pane = app.active.? };
    try t.expect(std.mem.startsWith(u8, (try pick(&app, arena)).title, "fn  ·  RS  ·  main.rs"));
}

test "hover: a chip's copy carries a Run it link the app resolves; the kebab menu offers the toggle; the wheel scrolls within the paint's bound" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    const arena = app.frame.allocator();
    const c = try chipCopy(&app, .refresh);
    try t.expectEqualStrings("Refresh tree", c.title);
    try t.expectEqual(@as(usize, 2), c.try_it.len);
    try t.expectEqual(command.CommandId.@"tree.refresh", app.info_view.links[0].?.command);
    // A hovered chip through the hits.
    try app.render();
    var chip_at: ?struct { x: u16, y: u16 } = null;
    for (app.hits.items.items) |e| if (e.target == .tree_chip and e.target.tree_chip == .new_file) {
        chip_at = .{ .x = e.rect.x, .y = e.rect.y };
    };
    app.hover = .{ .x = chip_at.?.x, .y = chip_at.?.y };
    app.hover_live = true;
    snapshotHover(&app);
    const hovered = try pick(&app, arena);
    try t.expectEqualStrings("New file", hovered.title);
    try t.expectEqual(command.CommandId.@"file.new", app.info_view.links[0].?.command);
    // The link row runs it: a prompt opens.
    try mouse(&app, .{ .try_it = 0 }, .{ .x = 0, .y = 0, .kind = .press, .button = .left }, 1);
    try t.expect(app.overlay == .prompt);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // The kebab.
    try mouse(&app, .kebab, .{ .x = 5, .y = 5, .kind = .press, .button = .left }, 1);
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("Turn off info panel (Settings → UI to bring back)", app.overlay.menu.items[0].label);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // The wheel.
    // A row per wheel event (the batch's count), clamped to the paint's bound.
    app.info_view.max_scroll = 4;
    try mouse(&app, .body, .{ .x = 5, .y = 5, .kind = .scroll_down, .button = .none }, 1);
    try t.expectEqual(@as(u16, 1), app.info_view.scroll);
    try mouse(&app, .body, .{ .x = 5, .y = 5, .kind = .scroll_down, .button = .none }, 5);
    try t.expectEqual(@as(u16, 4), app.info_view.scroll);
    try mouse(&app, .body, .{ .x = 5, .y = 5, .kind = .scroll_up, .button = .none }, 3);
    try t.expectEqual(@as(u16, 1), app.info_view.scroll);
    // A new topic scrolls back to the top.
    app.hover_live = false;
    snapshotHover(&app);
    _ = try pick(&app, arena);
    try t.expectEqual(@as(u16, 0), app.info_view.scroll);
}

test "the box is sticky under the pointer: the entry and its links stay while the pointer crosses onto the box; a fallback carries the no-help aside; a Settings link opens the overlay on its row" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    const arena = app.frame.allocator();
    try app.render();
    // Hover the statusline's mode chip: a curated entry with links.
    var seg_at: ?struct { x: u16, y: u16 } = null;
    var box_at: ?struct { x: u16, y: u16 } = null;
    for (app.hits.items.items) |e| {
        if (e.target == .statusline_seg and e.target.statusline_seg == 0) seg_at = .{ .x = e.rect.x, .y = e.rect.y };
        if (e.target == .info_view and e.target.info_view == .body) box_at = .{ .x = e.rect.x + 2, .y = e.rect.y + 3 };
    }
    app.hover = .{ .x = seg_at.?.x, .y = seg_at.?.y };
    app.hover_live = true;
    snapshotHover(&app);
    const chip = try pick(&app, arena);
    try t.expectEqualStrings("Mode chip — standard keymap", chip.title);
    try t.expect(chip.aside == null);
    try t.expect(chip.try_it.len >= 2);
    try t.expectEqual(view.LinkKind.settings, chip.try_it[1].kind);
    // The pointer moves onto the box: the same entry, the same links.
    app.hover = .{ .x = box_at.?.x, .y = box_at.?.y };
    snapshotHover(&app);
    const still = try pick(&app, arena);
    try t.expectEqualStrings("Mode chip — standard keymap", still.title);
    try t.expect(app.info_view.links[1].? == .settings);
    // The Settings link: the overlay opens on the input-style row.
    try mouse(&app, .{ .try_it = 1 }, .{ .x = 0, .y = 0, .kind = .press, .button = .left }, 1);
    try t.expect(app.overlay == .settings);
    const list = try settings_app.items(&app, arena);
    try t.expectEqual(copy.settingsRow("editor.input_style"), list[app.overlay.settings.ui.cursor].row.id);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    app.focus = .tree;
    // A docs link: the manual's section opens as a preview and takes
    // the focus.
    app.info_view.links[0] = .{ .docs = .{ .doc = .config, .section = "The launcher dock" } };
    try mouse(&app, .{ .try_it = 0 }, .{ .x = 0, .y = 0, .kind = .press, .button = .left }, 1);
    try t.expect(app.active != null);
    const manual = app.panes.get(app.active.?).?;
    try t.expect(manual.* == .md_preview);
    try t.expectEqualStrings("CONFIG.md \u{2014} The launcher dock", manual.title());
    try t.expect(app.focus == .pane);
    app.focus = .tree;
    // A target the dictionary has nothing for (an overlay row with no
    // overlay open): the tooltip's line, marked as a fallback.
    app.hover_live = true;
    try t.expectEqual(Resolution.fallback, try resolve(&app, arena, .{ .overlay_item = 0 }));
    try t.expectEqual(Resolution.none, try resolve(&app, arena, .{ .tree_node = 9999 }));
    try t.expectEqual(Resolution.curated, try resolve(&app, arena, .{ .statusline_seg = 0 }));
    try t.expectEqual(Resolution.curated, try resolve(&app, arena, .{ .rail = .gear }));
}

test "a pty pane's copy: the title names the terminal and the shell, and the chords under it are the profile's, not prose" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 120, .rows = 40 });
    defer app.deinit();
    try app.env.put("TERM_PROGRAM", "ghostty");
    try app.env.put("SHELL", "/bin/sh");
    const id = try @import("pty_pane.zig").open(&app, .{ .placement = .tab });
    app.focus = .{ .pane = id };
    const arena = app.frame.allocator();
    const c = try pick(&app, arena);
    // The title is the pane's label: the terminal mnml runs inside,
    // then the child — the same pair the tab shows.
    try t.expectEqualStrings("ghostty (sh)", c.title);
    try t.expect(std.mem.startsWith(u8, c.body, "Terminal pane \u{2014} "));
    // The close chord comes off the keymap (standard profile here), so
    // a rebind moves the copy with it; `term.restart` is unbound and
    // contributes its label alone.
    try t.expect(std.mem.indexOf(u8, c.body, "[Ctrl+W] Close") != null);
    try t.expect(std.mem.indexOf(u8, c.body, "Restart") != null);
    try t.expect(std.mem.indexOf(u8, c.body, "Ctrl+Alt+") == null);
}

test "an AI answer pane's copy names its own keys — it has no prompt to type at" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    const id = try app.panes.add(.{ .ai = .{
        .gpa = t.allocator,
        .title = try t.allocator.dupe(u8, "ai: explain"),
        .prompt = try t.allocator.dupe(u8, "p"),
        .job = 0,
        .kind = .action,
        .session_id = @splat('0'),
    } });
    app.showPane(id);
    app.focus = .{ .pane = id };
    const c = try pick(&app, app.frame.allocator());
    try t.expectEqualStrings("ai: explain", c.title);
    try t.expect(std.mem.indexOf(u8, c.body, "bottom prompt") == null);
    for ([_][]const u8{ "r re-ask", "c cancel", "a apply", "p continue", "y copy", "q close" }) |k|
        try t.expect(std.mem.indexOf(u8, c.body, k) != null);
}

test "the corridor: closing on the box inside the column or the triangle holds; a step away, or wide of both, does not" {
    const box = Rect.init(4, 30, 26, 8);
    // Straight down the column.
    try t.expect(inCorridor(.{ .x = 21, .y = 1 }, .{ .x = 21, .y = 1 }, .{ .x = 18, .y = 5 }, box));
    try t.expect(inCorridor(.{ .x = 21, .y = 1 }, .{ .x = 18, .y = 5 }, .{ .x = 16, .y = 20 }, box));
    // A step back up is a step away.
    try t.expect(!inCorridor(.{ .x = 21, .y = 1 }, .{ .x = 18, .y = 5 }, .{ .x = 18, .y = 4 }, box));
    // Sideways, still level and inside the column: no farther.
    try t.expect(inCorridor(.{ .x = 21, .y = 1 }, .{ .x = 18, .y = 5 }, .{ .x = 28, .y = 5 }, box));
    // Out of the column sideways is away from the box.
    try t.expect(!inCorridor(.{ .x = 21, .y = 1 }, .{ .x = 18, .y = 5 }, .{ .x = 31, .y = 5 }, box));
    // Right of the column past the margin, closing in: only the triangle
    // from where it left (x 80) toward the box's top edge holds it.
    try t.expect(inCorridor(.{ .x = 80, .y = 2 }, .{ .x = 80, .y = 2 }, .{ .x = 70, .y = 6 }, box));
    try t.expect(!inCorridor(.{ .x = 80, .y = 2 }, .{ .x = 80, .y = 2 }, .{ .x = 79, .y = 25 }, box));
    // From below (the statusline), heading up to the box's bottom edge.
    try t.expect(inCorridor(.{ .x = 40, .y = 39 }, .{ .x = 40, .y = 39 }, .{ .x = 35, .y = 38 }, box));
    try t.expect(!inCorridor(.{ .x = 40, .y = 39 }, .{ .x = 40, .y = 39 }, .{ .x = 41, .y = 39 }, box));
    // No box, no corridor.
    try t.expect(!inCorridor(.{ .x = 1, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 2 }, Rect.empty));
}

/// The cell of the first hit `pred` accepts, from the last paint.
fn hitCell(app: *App, comptime pred: fn (HitTarget) bool) ?Pt {
    for (app.hits.items.items) |e| if (pred(e.target)) return .{ .x = e.rect.x, .y = e.rect.y };
    return null;
}

fn hoverAt(app: *App, p: Pt) !void {
    app.hover = .{ .x = p.x, .y = p.y };
    app.hover_live = true;
    try app.render();
}

test "grace: the entry stays while the pointer crosses rows toward the box, switches on a step away, and lets go when the window runs out" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |n| try tmp.dir.writeFile(t.io, .{ .sub_path = n, .data = "x\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 120, .rows = 40 });
    defer app.deinit();
    try app.tree.refresh(&app);
    app.focus = .tree;
    app.now_ms = 1000;
    try app.render();
    const chip = hitCell(&app, struct {
        fn f(h: HitTarget) bool {
            return h == .tree_chip and h.tree_chip == .new_file;
        }
    }.f).?;
    const box = app.info_view.rect.?;
    const row_a = app.tree.rowOf("a.txt").?;
    const row_b = app.tree.rowOf("b.txt").?;
    var a_cell: Pt = undefined;
    var b_cell: Pt = undefined;
    for (app.hits.items.items) |e| if (e.target == .tree_node) {
        if (e.target.tree_node == row_a) a_cell = .{ .x = e.rect.x + 4, .y = e.rect.y };
        if (e.target.tree_node == row_b) b_cell = .{ .x = e.rect.x + 4, .y = e.rect.y };
    };
    const arena = app.frame.allocator();
    try hoverAt(&app, chip);
    try t.expectEqualStrings("New file", (try pick(&app, arena)).title);
    // Down the column over b.txt's row, then the empty tree under it.
    try hoverAt(&app, b_cell);
    try t.expectEqualStrings("New file", (try pick(&app, arena)).title);
    try t.expect(app.info_view.grace != null);
    try t.expectEqual(@as(?i64, 1000 + 900), nextDeadlineMs(&app));
    try hoverAt(&app, .{ .x = b_cell.x, .y = box.y - 2 });
    try t.expectEqualStrings("New file", (try pick(&app, arena)).title);
    // Onto the box: held with no window running.
    try hoverAt(&app, .{ .x = box.x + 2, .y = box.y + 3 });
    try t.expectEqualStrings("New file", (try pick(&app, arena)).title);
    try t.expect(app.info_view.grace == null);
    // A wheel notch over the box (no motion) keeps it too.
    app.hover_live = false;
    try app.render();
    try t.expectEqualStrings("New file", (try pick(&app, arena)).title);
    // Back to the chip, then a step UP the column from b.txt to a.txt:
    // away from the box, so a.txt's row takes the box at once.
    try hoverAt(&app, chip);
    try hoverAt(&app, b_cell);
    try t.expectEqualStrings("New file", (try pick(&app, arena)).title);
    try hoverAt(&app, a_cell);
    try t.expect(!std.mem.eql(u8, "New file", (try pick(&app, arena)).title));
    try t.expect(app.info_view.grace == null);
    // The window running out while the pointer rests on a crossed row:
    // the tick asks for the frame, and the row takes the box.
    try hoverAt(&app, chip);
    try hoverAt(&app, b_cell);
    try t.expectEqualStrings("New file", (try pick(&app, arena)).title);
    try app.tick(app.now_ms + 900);
    try t.expect(app.info_view.grace == null);
    try t.expect(app.needs_render);
    try app.render();
    try t.expect(!std.mem.eql(u8, "New file", (try pick(&app, arena)).title));
    // `ui.hover_help_grace_ms = 0`: every crossing switches at once.
    app.cfg.ui.hover_help_grace_ms = 0;
    try hoverAt(&app, chip);
    try hoverAt(&app, b_cell);
    try t.expect(!std.mem.eql(u8, "New file", (try pick(&app, arena)).title));
    try t.expectEqual(@as(?i64, null), nextDeadlineMs(&app));
}

test "pin: the entry and its links outlive the frame and every hover until unpinned; a pin left on is freed with the app" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    for ([_][]const u8{ "a.txt", "b.txt" }) |n| try tmp.dir.writeFile(t.io, .{ .sub_path = n, .data = "x\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 120, .rows = 40 });
    defer app.deinit();
    try app.tree.refresh(&app);
    app.focus = .tree;
    try app.render();
    const chip = hitCell(&app, struct {
        fn f(h: HitTarget) bool {
            return h == .tree_chip and h.tree_chip == .new_file;
        }
    }.f).?;
    const pin_at = hitCell(&app, struct {
        fn f(h: HitTarget) bool {
            return h == .info_view and h.info_view == .pin;
        }
    }.f).?;
    const arena = app.frame.allocator();
    try hoverAt(&app, chip);
    try t.expectEqualStrings("New file", (try pick(&app, arena)).title);
    // The chip's press pins it (through the box's own mouse handler).
    try mouse(&app, .pin, .{ .x = pin_at.x, .y = pin_at.y, .kind = .press, .button = .left }, 1);
    try t.expect(isPinned(&app));
    try t.expect(app.info_view.pinned.?.target.? == .tree_chip);
    // Frames go by and the pointer wanders — up the column, off it.
    const a_row = app.tree.rowOf("a.txt").?;
    var a_cell: Pt = undefined;
    for (app.hits.items.items) |e| if (e.target == .tree_node and e.target.tree_node == a_row) {
        a_cell = .{ .x = e.rect.x + 4, .y = e.rect.y };
    };
    try hoverAt(&app, a_cell);
    try hoverAt(&app, .{ .x = 80, .y = 20 });
    const held = try pick(&app, arena);
    try t.expectEqualStrings("New file", held.title);
    try t.expect(std.mem.startsWith(u8, held.body, "Creates an empty file"));
    try t.expectEqual(command.CommandId.@"file.new", app.info_view.links[0].?.command);
    // The link still runs what it named.
    try mouse(&app, .{ .try_it = 0 }, .{ .x = 0, .y = 0, .kind = .press, .button = .left }, 1);
    try t.expect(app.overlay == .prompt);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    app.focus = .tree;
    // The command unpins; the pointer's row takes the box.
    try command.run(&app, .{ .static = .@"help.pin_toggle" });
    try t.expect(!isPinned(&app));
    try hoverAt(&app, a_cell);
    try hoverAt(&app, a_cell);
    try t.expectEqualStrings("a.txt — Plain text", (try pick(&app, arena)).title);
    // Pinned again and left on: `App.deinit` frees it (the allocator
    // is the leak-checking one).
    try togglePin(&app);
    try t.expectEqualStrings("a.txt — Plain text", app.info_view.pinned.?.copy.title);
    try t.expect(unpin(&app));
    try t.expect(!unpin(&app));
    try togglePin(&app);
}
