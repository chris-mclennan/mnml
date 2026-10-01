//! The launcher dock — macOS's Dock, in a terminal. A strip of the
//! things you *start*: the installed integrations, the terminals (a
//! *New terminal* item and one per open pty, which the click focuses),
//! the launchers, and any command pinned onto it. It lives along one
//! edge of the editor area and it is hideable, revealable on hover, or
//! always on, the way the menu bar at the top is.
//!
//! **Three names that are not this one.** mnml already says "dock" in
//! two other places and this file is neither. `app/bottom.zig` is the
//! BOTTOM PANEL, which hosts sections and panes under the editor
//! (`ui.bottom_panel_*`, `Ctrl-W J` / `K`). `app/dock.zig` is the dock
//! WIDGETS, the small panels pinned to a corner of the buffer. This
//! file is the LAUNCHER dock, `ui.dock`, and when it and the bottom
//! panel are both at the bottom the launcher dock is the outermost row
//! — the panel is inside it, as the editor is.
//!
//! **It draws over; it never re-lays-out** — the rule
//! `app/sidebar_auto.zig` already lives by. Under `ui.dock.mode =
//! .always` the strip is carved out of the frame like any other chrome
//! and `render.chrome` reports it; under `.auto_hide` the reveal is
//! paint alone, so no pane moves and no pty is resized when the
//! pointer brushes an edge.
//!
//! **The outer-band rule** (written down in `app/hover_zones.zig`,
//! where it is enforced). A dock on a side edge takes the OUTERMOST
//! column of the frame, always, and the side column's own reveal edge
//! moves one cell inwards to make room. So a left dock and a left
//! auto-hiding sidebar are both reachable — the outer cell summons the
//! dock, the next cell in summons the column — instead of one of them
//! silently winning the screen edge. The top row is never the dock's:
//! there is no `.top` edge, because that row is the menu bar's.
//!
//! The reveal is a dwell (`ui.dock.reveal_ms`) arbitrated by
//! `hover_zones`; the hide is `ui.dock.hide_ms` after the pointer
//! leaves, refused while the keyboard is in the strip. `view.dock_pin`
//! ends the game for the session: `mode` then reads `.always` and the
//! strip docks like any other chrome (the pin, unlike the mode, IS
//! remembered — `session.zon` carries it).
//!
//! `view.focus_dock` puts the keyboard in the strip, and the strip
//! holds it only while the hand is on it: a key it has no answer for,
//! or a mouse press that lands anywhere else, hands the keyboard back
//! at once. `h` and `l` are how you walk a bottom strip, so a dock
//! focused and then forgotten would otherwise swallow both of them
//! everywhere else in the app.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Config = @import("../config/Config.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const Key = app_mod.Key;
const Mouse = @import("../core/key.zig").Mouse;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const view = @import("../ui/launcher_dock_view.zig");
const hover_zones = @import("hover_zones.zig");
const tooltip = @import("../ui/tooltip.zig");
const integrations = @import("integrations.zig");
const terminal_glyph = @import("terminal_glyph.zig");
const menu_glyph = @import("../ui/menu_glyph.zig");
const settings = @import("settings.zig");
const bufferline = @import("../ui/bufferline.zig");
const context_menus = @import("context_menus.zig");
const activity_bar = @import("activity_bar.zig");
const rail = @import("../ui/activity_bar.zig");
const side_mod = @import("side.zig");
const Theme = @import("../ui/theme.zig");
const paletteColor = @import("../ui/integrations_view.zig").paletteColor;
const sessions = @import("../sessions.zig");
const pty_pane = @import("pty_pane.zig");
const launch_profiles = @import("launch_profiles.zig");

pub const Mode = Config.DockMode;
pub const Edge = Config.DockEdge;
pub const Labels = Config.DockLabels;
pub const Align = Config.DockAlign;
pub const Placement = Config.DockPlacement;
pub const PlusAt = Config.DockPlusAt;
pub const RunningMark = Config.DockRunningMark;
pub const Part = @import("../ui/hit.zig").LauncherDockPart;

pub const table = .{
    .@"view.dock_toggle" = &toggleCmd,
    .@"view.dock_pin" = &pinCmd,
    .@"view.dock_cycle_mode" = &cycleModeCmd,
    .@"view.dock_move" = &moveCmd,
    .@"view.focus_dock" = &focusCmd,
    .@"view.dock_unpin_item" = &unpinItemCmd,
    .@"view.dock_item_move_prev" = &moveItemPrevCmd,
    .@"view.dock_item_move_next" = &moveItemNextCmd,
    .@"view.dock_item_move_first" = &moveItemFirstCmd,
    .@"view.dock_item_move_last" = &moveItemLastCmd,
};

/// A side dock's width in cells — the activity bar's, so the two rails
/// read as one family.
pub const width: u16 = view.width;
/// A bottom dock's height in rows.
pub const height: u16 = 1;

pub const State = struct {
    /// The strip is revealed over the editor (never set under `always`,
    /// where it is carved instead).
    open: bool = false,
    /// A command opened it, so it is allowed under `.hidden` and does
    /// not start its hide clock until the pointer has been on it once.
    by_key: bool = false,
    /// The pointer has been on the strip since it opened.
    touched: bool = false,
    /// The pointer left the strip at this ms; null while it is on it.
    left_at_ms: ?i64 = null,
    /// Pinned for the session — `mode` reads `.always`. Remembered in
    /// `session.zon`, not in the config.
    pinned: bool = false,
    /// The keyboard is in the strip (`view.focus_dock`).
    kb: bool = false,
    /// The keyboard cursor's item.
    cursor: u16 = 0,
    /// The strip's rect at the last paint — the painter registers it as
    /// the zone's second piece, so resting on it keeps it up.
    rect: Rect = .empty,
    /// How many items the last paint had; the cursor clamps to it.
    count: u16 = 0,
};

// ─── mode and geometry ──────────────────────────────────────────────────

/// `ui.dock.mode`, with the session's pin on top of it.
/// // changed (dock-shared): a strip on the `:` line's row has no
/// reveal to run — it is on a row that is always there — so
/// `.auto_hide` reads `.always` under `.shared`. `.hidden` still hides.
pub fn mode(app: *const App) Mode {
    if (app.launcher_dock.pinned) return .always;
    if (app.cfg.ui.dock.mode == .auto_hide and sharesCmdline(app)) return .always;
    return app.cfg.ui.dock.mode;
}

pub fn edge(app: *const App) Edge {
    return app.cfg.ui.dock.edge;
}

/// `ui.dock.labels`. A side dock has three cells and no room for a
/// label, so it paints the icon form whatever the key says — `.label`
/// included; the key is the BOTTOM strip's question.
pub fn labels(app: *const App) Labels {
    if (edge(app) != .bottom) return .icon;
    return app.cfg.ui.dock.labels;
}

/// `ui.dock.align` — where the run of items sits along the strip. The
/// pin chip keeps the far end whatever it says.
pub fn alignment(app: *const App) Align {
    return app.cfg.ui.dock.@"align";
}

/// // changed (dock-polish): `ui.dock.plus_at` — which end of the run
/// the `+` takes. `.right` is the far end on either axis (the bottom
/// of a side strip); `.left` leads.
pub fn plusAt(app: *const App) PlusAt {
    return app.cfg.ui.dock.plus_at;
}

/// // changed (dock-polish): `ui.dock.running_mark` — how a running
/// item is told from the rest.
pub fn runningMark(app: *const App) RunningMark {
    return app.cfg.ui.dock.running_mark;
}

/// // changed (dock-placement): `ui.dock.placement` — where a BOTTOM
/// strip sits relative to the statusline and the `:` line. `.inner`
/// (the default) is the editor area's last row, ABOVE the statusline;
/// `.outer` is the screen's last row, UNDER the `:` line. A side dock
/// is a column and neither row is its business, so it reads `.inner`
/// whatever the key says — exactly as `labels` reads `.icon` there.
pub fn placement(app: *const App) Placement {
    if (edge(app) != .bottom) return .inner;
    return app.cfg.ui.dock.placement;
}

/// // changed (dock-shared): the strip lives ON the `:` line's row —
/// a bottom dock under `ui.dock.placement = .shared`. It carves no row
/// (`banded` is false), wears no grip, registers no dwell band, and is
/// painted by `render` into the part of that row the typed command
/// does not reach (`sharedStrip`).
pub fn sharesCmdline(app: *const App) bool {
    return placement(app) == .shared;
}

/// The strip is carved out of the frame this frame — `render.chrome`'s
/// one question.
pub fn docked(app: *const App) bool {
    return !app.zen and mode(app) == .always;
}

/// // changed (side-band): whether the frame RESERVES the dock's band
/// this frame — `render.chrome`'s question now, `docked` having become
/// the narrower "does it carry items".
///
/// **An edge band belongs to one surface.** A SIDE dock's band is its
/// own three columns and is reserved for as long as the dock is not
/// `hidden`: everything else — the activity bar, the side columns, the
/// panes, every hit — is laid out INSIDE it, so the strip occupies the
/// same columns down, revealed and pinned. Revealing then relayouts
/// nothing and covers nothing (it fills a band that was already its
/// own), and the columns the grip marks are inert, which is what the
/// grip's whole contract needs: it names the band, it is never a
/// second way in, and it must never answer for a control underneath.
/// Before this the band was reserved in name only — `hover_zones`
/// pushed an auto-hiding side column's reveal edge one cell in and
/// nothing else honoured it, so the grip sat on the editor's scrollbar
/// and on the activity bar's first column, and a revealed strip
/// painted the activity bar out of existence.
///
/// A BOTTOM band is one ROW of a frame that may only have twenty-four,
/// and a row is too dear to hold empty for a strip that is down — so
/// the bottom edge is unchanged: carved only under `.always`, shared
/// with the `:` line otherwise, which is the case `gripBlocked`
/// already governs (the grip stands down while a line is open).
pub fn banded(app: *const App) bool {
    if (app.zen or mode(app) == .hidden) return false;
    // // changed (dock-shared): a `.shared` strip is paint on a row the
    // frame already keeps — the `:` line's — so it reserves nothing.
    if (edge(app) == .bottom) return mode(app) == .always and !sharesCmdline(app);
    return true;
}

/// The strip is painted as an overlay over the editor this frame.
pub fn revealed(app: *const App) bool {
    return !app.zen and mode(app) != .always and app.launcher_dock.open;
}

/// The strip is on screen at all, carved or revealed.
pub fn shown(app: *const App) bool {
    return docked(app) or revealed(app);
}

/// // changed (edge-grip): whether the `⋯` / `⋮` grip paints at the
/// middle of the strip's own band. Only `auto_hide` wears one —
/// `hidden` registers no hover zone, so a grip there would be a handle
/// that does nothing — and only while the strip is down: revealed, the
/// pin chip at its end is the handle, and pinned (`mode` reads
/// `.always`) there is nothing left to summon. A `:` line on the
/// bottom row takes the row back, grip and all.
pub fn gripShown(app: *App) bool {
    return app.cfg.ui.edge_grips and !app.zen and mode(app) == .auto_hide and
        !app.launcher_dock.open and !gripBlocked(app);
}

/// // changed (dock-grip-row): the grip sits on the row the strip
/// paints (`hover_zones.dockBand`), so it stands down for an open `:`
/// line only where that row IS the line's — `.outer`, exactly when
/// `cmdlineBlocks` refuses the strip. Under `.inner` the grip is above
/// the statusline and covers nothing being typed — but that row is the
/// panes' last, which flash's cue and the Undo chip borrow while they
/// are up, so the grip stands down for them there instead.
pub fn gripBlocked(app: *App) bool {
    if (cmdlineBlocks(app)) return true;
    return edge(app) == .bottom and placement(app) == .inner and mode(app) != .always and
        (app.flash != null or app.undo_chip != null);
}

/// The frame needs this many columns before a side dock is worth
/// carving or revealing — its own cells plus the 21 the panes are
/// never squeezed below (`render.frameRects`' own floor).
pub const side_min_width: u16 = width + 21;

/// Where a revealed strip paints: the band `hover_zones` watches,
/// grown to the strip's own size. Empty when there is no room.
/// // changed (edge-grip): on the bottom edge that band is the
/// SCREEN's last row, so a revealed strip paints over the `:` line's
/// row — the toast echo and the in-flight chip with it. An open `:`
/// line refuses the reveal outright (`cmdlineBlocks`), so the one
/// thing that row can be mid-use is never covered.
/// // changed (dock-placement): that is `.outer`. Under `.inner` the
/// strip PAINTS on the editor area's last row — above the statusline,
/// exactly the row an `always` + `.inner` dock is carved from, so the
/// strip is in the same place whichever mode it is in.
/// // changed (dock-grip-row): and the band is that row too, so the
/// strip lands on the grip's own row in both placements.
pub fn overlayRect(app: *const App, full: Rect) Rect {
    const band = hover_zones.dockBand(app, full) orelse return .empty;
    return switch (edge(app)) {
        .bottom => switch (placement(app)) {
            .outer, .inner => band,
            // // changed (dock-shared): the `:` line's row, which the
            // band already is when nothing is carved under it. Only a
            // `hidden` strip's one-shot reveal (`view.dock_toggle`)
            // gets here; `render` lays it out with `sharedStrip`.
            .shared => band,
        },
        .left => if (full.w >= side_min_width) Rect.init(band.x, band.y, width, band.h) else .empty,
        .right => if (full.w >= side_min_width) Rect.init(band.right() -| width, band.y, width, band.h) else .empty,
    };
}

/// // changed (dock-placement): the editor area's last row — where an
/// `.inner` bottom strip lives, carved or painted. It is read off the
/// bare frame (no columns, no dock), so the row is the same one the
/// `always` carve takes: `frameRects` shrinks `upper` by the strip's
/// own height and hands back its bottom row. Null when the screen is
/// too short to hold a bottom dock at all.
pub fn innerRow(full: Rect) ?Rect {
    const rnd = @import("render.zig");
    if (full.isEmpty() or full.h < rnd.dock_bottom_min_height) return null;
    const upper = rnd.frameRects(full, .{}).upper;
    if (upper.h < height) return null;
    return Rect.init(upper.x, upper.bottom() -| height, upper.w, height);
}

/// // changed (dock-shared): where a `.shared` strip paints on the `:`
/// line's row this frame, and where its run starts.
pub const Shared = struct {
    /// The strip's area — the whole row. Empty when the strip steps
    /// aside.
    area: Rect,
    /// The first item's column (the pin chip's when the run is empty).
    run_x: u16,
};

/// // changed (dock-shared): the `.shared` layout. `row` is the `:`
/// line's row; `line_w` is the width an open `:` line paints — the
/// prompt, the typed text and the caret cell — or null when none is
/// open.
///
/// The run and the pin chip are laid out on the WHOLE row per
/// `ui.dock.align`, exactly as the bottom strip's are, and an open line
/// never moves them: the items stay where they were while the user
/// types. **The step-aside rule:** once the line plus its one cell of
/// air would reach the first painted item (`line_w + 1 > run_x`), the
/// strip — run and pin chip — is not painted at all this frame,
/// registers no hit, and comes back the frame the line closes or
/// shortens. Under `.start` the run begins at the row's second cell, so
/// any open line steps it aside at once.
pub fn sharedStrip(app: *App, ui: Ui, row: Rect, line_w: ?u16) Allocator.Error!Shared {
    const hidden: Shared = .{ .area = .empty, .run_x = row.right() };
    if (row.isEmpty() or !sharesCmdline(app) or !shown(app)) return hidden;
    const pin = view.pinRect(row, .bottom);
    if (pin.isEmpty()) return hidden;
    const list = try items(app, ui.arena);
    const lay = view.rowLayout(ui, row, try viewProps(app, ui, list));
    const run_x = if (lay.fits == 0) pin.x else lay.start;
    if (line_w) |lw| if (row.x + lw + 1 > run_x) return hidden;
    return .{ .area = row, .run_x = run_x };
}

// ─── the dwell ──────────────────────────────────────────────────────────

/// // changed (edge-grip): a bottom strip reveals OVER the `:` line's
/// row, so an open `:` line refuses it outright — and puts one that is
/// already up away. Typing is never covered. Only the bottom edge is
/// in contest: a side strip covers no part of that row.
/// // changed (dock-placement): and only `.outer`. An `.inner` strip
/// paints above the statusline and covers nothing of that row, so the
/// rule has nothing to protect — the line and the strip coexist, and
/// the band goes on being watched while a line is open.
pub fn cmdlineBlocks(app: *App) bool {
    return edge(app) == .bottom and placement(app) == .outer and
        mode(app) != .always and @import("cmdline.zig").anyOpen(app);
}

/// Advance the reveal / hide clock. Called from `App.tick` and from the
/// top of `render`, both idempotent at one `now`.
pub fn tick(app: *App, now: i64) void {
    const st = &app.launcher_dock;
    if (app.zen) {
        close(app);
        return;
    }
    if (cmdlineBlocks(app)) {
        if (st.open) close(app);
        return;
    }
    // A docked strip has no reveal to run down; the keyboard may still
    // be in it, so `kb` is left exactly as it was.
    if (mode(app) == .always) {
        st.open = false;
        st.by_key = false;
        st.left_at_ms = null;
        return;
    }
    if (!st.open) {
        if (mode(app) == .auto_hide and hover_zones.dwelled(app, .launcher_dock)) {
            st.open = true;
            st.by_key = false;
            st.touched = true;
            st.left_at_ms = null;
        }
        return;
    }
    // The keyboard holds it open outright.
    if (st.kb) {
        st.left_at_ms = null;
        return;
    }
    if (hover_zones.inZone(app, .launcher_dock)) {
        st.touched = true;
        st.left_at_ms = null;
        return;
    }
    // Summoned by a command and never touched: it waits for a hand
    // rather than vanishing because the mouse was nudged on the way.
    if (st.by_key and !st.touched) return;
    if (st.left_at_ms == null) st.left_at_ms = now;
    if (now -| st.left_at_ms.? >= app.cfg.ui.dock.hide_ms) close(app);
}

/// A frame is due the moment the hide clock runs out.
pub fn nextDeadlineMs(app: *const App) ?i64 {
    const st = &app.launcher_dock;
    if (!st.open or st.kb) return null;
    const left = st.left_at_ms orelse return null;
    const due = left + app.cfg.ui.dock.hide_ms;
    return if (due > app.now_ms) due else null;
}

pub fn close(app: *App) void {
    const st = &app.launcher_dock;
    st.open = false;
    st.by_key = false;
    st.touched = false;
    st.kb = false;
    st.left_at_ms = null;
    app.needs_render = true;
}

fn reveal(app: *App, by_key: bool) void {
    const st = &app.launcher_dock;
    st.open = true;
    st.by_key = by_key;
    st.touched = !by_key;
    st.left_at_ms = null;
    app.needs_render = true;
}

// ─── the model ──────────────────────────────────────────────────────────

/// // changed (railmove): `pinned_panel` is a section moved off the
/// activity bar (`view.activity_*` in `ui.dock.pins`) — it wears the
/// section's glyph and offers *Move back to activity bar*.
pub const Kind = enum { plus, integration, launcher, terminal_new, terminal, pin, pinned_panel };

/// What kind of strip item this is, in the two strips' shared words
/// (`ui/activity_bar.zig`'s `StripKind`): the `+` and a pinned command
/// are launchers, a pty is a terminal, a moved section is a pinned
/// panel. A later "kinds per strip" config filters on this.
pub fn stripKind(k: Kind) rail.StripKind {
    return switch (k) {
        .plus, .launcher, .pin => .launcher,
        .integration => .integration,
        .terminal_new, .terminal => .terminal,
        .pinned_panel => .pinned_panel,
    };
}

pub const Action = union(enum) {
    static: command.CommandId,
    named: []const u8,
    dyn: u32,
    pane: PaneId,
    /// The `+`: the tab bar's own *Create…* menu, opened where the
    /// click landed (`context_menus.openNewTabMenu`).
    menu,
    none,
};

/// // changed (dock-polish): an item's colour as the model names it.
/// An integration wears its category colour, which the manifest and
/// the first-party table spell as a ROLE (`"blue"`, `"#RRGGBB"`) for
/// `integrations_view.paletteColor` to resolve — the same resolver the
/// chip in the tab cluster and the pinned rail icon go through, so the
/// dock's Jira is the tab's Jira. A terminal wears the colour the
/// split cluster's own terminal chip and a shell tab already picked
/// (`bufferline.terminal_chip_fg`), as is: the dock used to give the
/// ghost a green of its own, and the user saw two ghosts disagree.
pub const Color = union(enum) {
    role: []const u8,
    fixed: Theme.Color,
};

pub const Item = struct {
    kind: Kind,
    /// The chip id, the command id, or `term` for a pty — what the
    /// menu, `dock.pins` and `dock.order` name this row by.
    id: []const u8,
    glyph: []const u8,
    fallback: []const u8,
    color: Color,
    label: []const u8,
    running: bool,
    /// A session of this item's kind needs you (`sessions.needsYou`):
    /// the running mark wears the attention colour.
    attention: bool = false,
    action: Action,
};

/// The AI product an integration chip launches, if it is one.
fn chipProduct(id: []const u8) ?launch_profiles.Product {
    if (std.mem.eql(u8, id, "claude_code")) return .claude;
    if (std.mem.eql(u8, id, "codex")) return .codex;
    return null;
}

/// A pty pane of `product` is blocked on the user.
fn productNeedsYou(app: *App, product: launch_profiles.Product) bool {
    var pid: PaneId = 0;
    while (pid < app.panes.capacity()) : (pid += 1) {
        const p = app.panes.pty(pid) orelse continue;
        if (pty_pane.productOf(app, p) != product) continue;
        if (sessions.needsYou(app, pid)) return true;
    }
    return false;
}

/// Every item the strip shows, in paint order, on `arena`:
/// integrations, then launchers that declared no chip, then the
/// terminals, then `ui.dock.pins` — that run reordered by
/// `ui.dock.order` — and the `+` at whichever end `ui.dock.plus_at`
/// says.
///
/// // changed (railmove): an integration is on the strip when it is
/// INSTALLED and not disabled — `Chip.on_dock` — whatever its chip
/// flags say. The strip used to read `Chip.enabled`, which for a
/// first-party surface is the chip's visibility in the tab cluster
/// (the Installed tab's `(hidden)`), so Claude Code, Codex and HTTP
/// — hidden chips out of the box — were never on the dock at all.
pub fn items(app: *App, arena: Allocator) Allocator.Error![]Item {
    var out: std.ArrayListUnmanaged(Item) = .empty;
    // ── integrations ──
    for (try integrations.allChips(app, arena)) |c| {
        if (!c.on_dock) continue;
        // A waiting session lights its product's item in the attention
        // colour, running or not by the mount rule.
        const attention = if (chipProduct(c.id)) |product| productNeedsYou(app, product) else false;
        try out.append(arena, .{
            .kind = .integration,
            .id = c.id,
            .glyph = c.glyph,
            .fallback = c.fallback,
            .color = .{ .role = c.color },
            .label = c.tooltip,
            .running = attention or integrationOpen(app, c.id) or productLive(app, c.id),
            .attention = attention,
            .action = switch (c.action) {
                .dyn => |slot| .{ .dyn = slot },
                .named => |n| .{ .named = n },
                .none => .none,
            },
        });
    }
    // ── launchers: an installed manifest that asked for no chip still
    //    has commands, and the dock is where you start things ──
    for (app.integrations.list) |*inst| {
        if (inst.manifest.chip != null or inst.slots.len == 0) continue;
        try out.append(arena, .{
            .kind = .launcher,
            .id = inst.id(),
            .glyph = launcher_glyph,
            .fallback = launcher_ascii,
            .color = .{ .role = "purple" },
            .label = if (inst.manifest.label.len > 0) inst.manifest.label else inst.id(),
            .running = integrationOpen(app, inst.id()),
            .action = .{ .dyn = inst.slots[0] },
        });
    }
    // ── terminals: a new one, then every open pty — in the colour the
    //    tab cluster's terminal chip wears, never one of their own ──
    const term = terminal_glyph.mark(app);
    try out.append(arena, .{
        .kind = .terminal_new,
        .id = "term.shell",
        .glyph = term.glyph,
        .fallback = term.fallback,
        .color = terminal_color,
        .label = "New terminal",
        .running = false,
        .action = .{ .static = .@"term.shell" },
    });
    var pid: PaneId = 0;
    while (pid < app.panes.capacity()) : (pid += 1) {
        const p = app.panes.get(pid) orelse continue;
        if (p.* != .pty) continue;
        try out.append(arena, .{
            .kind = .terminal,
            .id = "term",
            .glyph = term.glyph,
            .fallback = term.fallback,
            .color = terminal_color,
            .label = p.title(),
            // The dot says what runs: an exited child's pane is open,
            // not running.
            .running = p.pty.exit == null,
            .attention = sessions.needsYou(app, pid),
            .action = .{ .pane = pid },
        });
    }
    // ── pinned commands ──
    for (app.cfg.ui.dock.pins) |id| {
        const ref = command.resolve(app, id) orelse continue;
        // A pin of a command an item already runs is that item, not a
        // second one beside it (Claude Code pinned from its own menu
        // painted `Claude Code` and `AI: open Claude Code`).
        if (alreadyRuns(app, out.items, id)) continue;
        // // changed (railmove): a section's own command is a PANEL on
        // the dock — the section's glyph and name, the running dot
        // while its column is open, and a way back to the bar.
        if (activity_bar.sectionOfCommandName(id)) |s| {
            try out.append(arena, .{
                .kind = .pinned_panel,
                .id = id,
                .glyph = s.meta().glyph,
                .fallback = s.meta().fallback,
                .color = .{ .role = "blue" },
                .label = s.meta().label,
                .running = side_mod.isShown(app, s),
                .action = switch (ref) {
                    .static => |c| .{ .static = c },
                    .dyn => |slot| .{ .dyn = slot },
                },
            });
            continue;
        }
        const title = switch (ref) {
            .static => |c| command.title(c),
            .dyn => |slot| if (app.dyn_commands.at(slot)) |c| c.title else continue,
        };
        try out.append(arena, .{
            .kind = .pin,
            .id = id,
            .glyph = menu_glyph.forCommandName(id, false),
            .fallback = menu_glyph.forCommandName(id, true),
            .color = .{ .role = "blue" },
            .label = shortTitle(title),
            .running = false,
            .action = switch (ref) {
                .static => |c| .{ .static = c },
                .dyn => |slot| .{ .dyn = slot },
            },
        });
    }
    const ordered = try applyOrder(app, arena, out.items);
    // ── the `+`: the tab bar's own, opening the same *Create…* menu,
    //    at the end `ui.dock.plus_at` names. `ui.dock.plus = false`
    //    takes it off. It is never in `ui.dock.order`: an end is a
    //    place, not a rank ──
    if (!app.cfg.ui.dock.plus) return ordered;
    const with = try arena.alloc(Item, ordered.len + 1);
    switch (plusAt(app)) {
        .left => {
            with[0] = plusItem(app);
            @memcpy(with[1..], ordered);
        },
        .right => {
            @memcpy(with[0..ordered.len], ordered);
            with[ordered.len] = plusItem(app);
        },
    }
    return with;
}

/// The terminal items' colour: the split cluster's chip's, shared.
pub const terminal_color: Color = .{ .fixed = bufferline.terminal_chip_fg };

/// // changed (dock-polish): `ui.dock.order` applied to the run — the
/// listed ids lead, in the list's order; everything unlisted follows
/// in the order it was built (so an integration installed after the
/// list was written lands after it, not nowhere); an id nothing on the
/// strip answers to is ignored. Stable, so two items with one id —
/// every open pty is `term` — keep their own order.
fn applyOrder(app: *const App, arena: Allocator, list: []const Item) Allocator.Error![]Item {
    const order = app.cfg.ui.dock.order;
    const out = try arena.dupe(Item, list);
    if (order.len == 0) return out;
    const Keyed = struct {
        rank: usize,
        idx: usize,
        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return if (a.rank != b.rank) a.rank < b.rank else a.idx < b.idx;
        }
    };
    const keys = try arena.alloc(Keyed, list.len);
    for (list, 0..) |it, i| keys[i] = .{ .rank = rankOf(order, it.id), .idx = i };
    std.sort.insertion(Keyed, keys, {}, Keyed.lessThan);
    for (keys, 0..) |k, i| out[i] = list[k.idx];
    return out;
}

/// Where `id` sits in `order`; past the end when it is not listed.
fn rankOf(order: []const []const u8, id: []const u8) usize {
    for (order, 0..) |o, i| if (std.mem.eql(u8, o, id)) return i;
    return order.len;
}

fn indexOfId(ids: []const []const u8, id: []const u8) ?usize {
    for (ids, 0..) |o, i| if (std.mem.eql(u8, o, id)) return i;
    return null;
}

/// How far an item moves along the strip.
pub const Move = enum { prev, next, first, last };

/// // changed (dock-polish): move the item at `i` along the strip —
/// the item menu's *Move …* rows and `Alt+←` / `Alt+→` (`Alt+↑` /
/// `Alt+↓`, `Alt+Home` / `Alt+End`) while it has the keyboard cursor.
/// The strip's ids, first to last and the `+` left out, are written
/// to `ui.dock.order` as one list, so the order survives a restart
/// and an integration installed later simply follows it. Two items
/// with one id (the open ptys, all `term`) move as one. The `+` does
/// not move: `ui.dock.plus_at` places it. The cursor follows the item.
pub fn moveItem(app: *App, i: usize, how: Move) CommandError!void {
    const arena = app.frame.allocator();
    const list = try items(app, arena);
    if (i >= list.len) return app.diag.fail(arena, "dock: nothing focused to move", .{});
    const it = list[i];
    if (it.kind == .plus) {
        app.toast("the + keeps its end — `ui.dock.plus_at` moves it", .{});
        return;
    }
    var ids: std.ArrayListUnmanaged([]const u8) = .empty;
    var at: usize = 0;
    for (list, 0..) |other, k| {
        if (other.kind == .plus) continue;
        const seen = indexOfId(ids.items, other.id);
        if (k == i) at = seen orelse ids.items.len;
        if (seen == null) try ids.append(arena, other.id);
    }
    const n = ids.items.len;
    const to: usize = switch (how) {
        .prev => at -| 1,
        .next => @min(at + 1, n - 1),
        .first => 0,
        .last => n - 1,
    };
    if (to == at) {
        app.toast("{s} is already at the {s}", .{ it.label, if (to == 0) "start" else "end" });
        return;
    }
    const id = ids.items[at];
    if (to < at) {
        std.mem.copyBackwards([]const u8, ids.items[to + 1 .. at + 1], ids.items[to..at]);
    } else {
        std.mem.copyForwards([]const u8, ids.items[at..to], ids.items[at + 1 .. to + 1]);
    }
    ids.items[to] = id;
    try integrations.setDockOrder(app, ids.items);
    // The cursor follows the thing it moved.
    for (try items(app, arena), 0..) |after, k| if (after.kind != .plus and std.mem.eql(u8, after.id, id)) {
        app.launcher_dock.cursor = @intCast(k);
        break;
    };
    app.toast("dock: {s} moved", .{it.label});
}

/// The `+` item. It is the tab bar's `+` (`ui/bufferline.zig`'s glyph
/// and its ascii twin) and it opens the tab bar's menu — the one
/// `context_menus.openNewTabMenu` builds, never a fork of it. Under
/// `.label`, where nothing on the strip is a glyph, the `+` is a
/// character of the word instead.
fn plusItem(app: *const App) Item {
    return .{
        .kind = .plus,
        .id = plus_id,
        .glyph = bufferline.plus_glyph,
        .fallback = bufferline.plus_ascii,
        .color = .{ .role = "green" },
        .label = if (labels(app) == .label) "+ New" else "New",
        .running = false,
        .action = .menu,
    };
}

/// What the `+` row answers to — not a command id (the menu is not a
/// command), just the name `describe` and the item menu key off.
pub const plus_id = "dock.plus";

/// A command title is written for the palette, where a line is long:
/// *Browser: open Chrome (CDP) — console / nav / eval*. A bottom strip
/// is one row for every item there is, so a pin wears the part before
/// the first parenthetical or dash, clipped to `pin_label_max`. The
/// whole title is still in the tooltip.
pub const pin_label_max: usize = 24;

pub fn shortTitle(title: []const u8) []const u8 {
    var out = title;
    if (std.mem.indexOf(u8, out, " \u{2014} ")) |i| out = out[0..i];
    if (std.mem.indexOf(u8, out, " (")) |i| out = out[0..i];
    if (std.mem.indexOf(u8, out, " \u{00b7} ")) |i| out = out[0..i];
    out = std.mem.trimEnd(u8, out, " \t");
    if (out.len <= pin_label_max) return out;
    // Back off to the last word boundary, then to a codepoint boundary,
    // so the clip never splits a word or a character.
    var end = pin_label_max;
    if (std.mem.lastIndexOfScalar(u8, out[0..end], ' ')) |sp| {
        if (sp > 0) end = sp;
    }
    while (end > 0 and (out[end] & 0xc0) == 0x80) end -= 1;
    return std.mem.trimEnd(u8, out[0..end], " \t");
}

/// A generic launcher's mark: the rocket, in the Nerd Font's own plane.
pub const launcher_glyph = "\u{f135}"; //  nf-fa-rocket
pub const launcher_ascii = "^";

/// Whether an integration has a pane open — the dot macOS puts under a
/// running app. A mounted pane names the manifest it came from; the
/// browser is the one first-party surface with a pane of its own.
fn integrationOpen(app: *App, id: []const u8) bool {
    var pid: PaneId = 0;
    while (pid < app.panes.capacity()) : (pid += 1) {
        const p = app.panes.get(pid) orelse continue;
        switch (p.*) {
            .mount => |*m| if (m.integration) |owner| {
                if (std.mem.eql(u8, owner, id)) return true;
            },
            .browser => if (std.mem.eql(u8, id, "browser")) return true,
            else => {},
        }
    }
    return false;
}

/// Whether the Claude Code / Codex item's product has a live session:
/// those items stand for every session of their kind, which are pty
/// panes, not mounts. False for every other id.
fn productLive(app: *App, id: []const u8) bool {
    const product: launch_profiles.Product = if (std.mem.eql(u8, id, "claude_code")) .claude else if (std.mem.eql(u8, id, "codex")) .codex else return false;
    var pid: PaneId = 0;
    while (pid < app.panes.capacity()) : (pid += 1) {
        const p = app.panes.pty(pid) orelse continue;
        if (p.exit == null and pty_pane.productOf(app, p) == product) return true;
    }
    return false;
}

/// Run item `i` — the one door a click, Enter and a menu row share.
/// The `+` needs somewhere to hang its menu; without a pointer it
/// hangs at the strip's own corner.
pub fn activate(app: *App, i: usize) Allocator.Error!void {
    const r = app.launcher_dock.rect;
    return activateAt(app, i, r.x, r.y);
}

/// `activate`, with the pointer's cell — where a menu opens from.
pub fn activateAt(app: *App, i: usize, x: u16, y: u16) Allocator.Error!void {
    const list = try items(app, app.frame.allocator());
    if (i >= list.len) return;
    const it = list[i];
    switch (it.action) {
        .static => |id| run(app, .{ .static = id }),
        .dyn => |slot| run(app, .{ .dyn = slot }),
        .named => |id| command.runNamed(app, id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .pane => |id| {
            app.showPane(id);
            app.focus = .{ .pane = id };
        },
        .menu => {
            // The `+` opens the tab bar's own menu. A revealed strip
            // stays up under it: the menu is where the hand is going,
            // and putting the strip away would take the `+` with it.
            try context_menus.openNewTabMenu(app, x, y);
            app.needs_render = true;
            return;
        },
        .none => app.toast("{s}: nothing to run", .{it.label}),
    }
    // Picking something puts a revealed strip away at once: the
    // pointer is about to be somewhere else (`sidebar_auto`'s rule).
    if (!app.launcher_dock.pinned and app.launcher_dock.open) close(app);
    app.needs_render = true;
}

fn run(app: *App, ref: command.CommandRef) void {
    command.run(app, ref) catch {};
}

// ─── the paint ──────────────────────────────────────────────────────────

/// The strip. `area` is the carved rect under `always`, or the overlay
/// band under a reveal. Registers the strip as the zone's second piece
/// so the pointer resting on it keeps it up.
pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    if (area.isEmpty()) return;
    const st = &app.launcher_dock;
    const list = try items(app, ui.arena);
    st.rect = area;
    st.count = @intCast(list.len);
    if (st.cursor >= list.len) st.cursor = if (list.len == 0) 0 else @intCast(list.len - 1);
    view.draw(ui, area, try viewProps(app, ui, list));
    if (mode(app) != .always) hover_zones.register(app, .{
        .rect = area,
        .id = .launcher_dock,
        .dwell_ms = app.cfg.ui.dock.reveal_ms,
        .priority = hover_zones.prio_dock,
    });
}

/// The strip as the view is told it — one builder, so the paint and
/// `sharedStrip`'s arithmetic can never disagree about the run.
fn viewProps(app: *App, ui: Ui, list: []const Item) Allocator.Error!view.Props {
    const st = &app.launcher_dock;
    const props_items = try ui.arena.alloc(view.Item, list.len);
    for (list, props_items) |it, *v| v.* = .{
        .glyph = it.glyph,
        .fallback = it.fallback,
        .color = resolveColor(ui.theme, it.color),
        .label = it.label,
        .running = it.running,
        .attention = it.attention,
    };
    return .{
        .items = props_items,
        .edge = switch (edge(app)) {
            .bottom => .bottom,
            .left => .left,
            .right => .right,
        },
        .labels = switch (labels(app)) {
            .icon => .icon,
            .icon_label => .icon_label,
            .label => .label,
        },
        .@"align" = switch (alignment(app)) {
            .start => .start,
            .center => .center,
            .end => .end,
        },
        .cursor = if (st.kb) st.cursor else null,
        .pinned = st.pinned,
        .running_mark = switch (runningMark(app)) {
            .bright => .bright,
            .dot => .dot,
            .none => .none,
        },
        .ground = !sharesCmdline(app),
    };
}

/// The colour an item paints in: a role through the one resolver the
/// tab cluster's chips use, a fixed colour as is.
pub fn resolveColor(th: *const Theme, c: Color) Theme.Color {
    return switch (c) {
        .role => |r| paletteColor(th, r),
        .fixed => |v| v,
    };
}

// ─── the mouse ──────────────────────────────────────────────────────────

pub fn mouse(app: *App, part: Part, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    switch (part) {
        .pin => switch (m.button) {
            .left => run(app, .{ .static = .@"view.dock_pin" }),
            .right => try openDockMenu(app, m.x, m.y),
            else => {},
        },
        .item => |i| switch (m.button) {
            .left => try activateAt(app, i, m.x, m.y),
            .right => try openItemMenu(app, i, m.x, m.y),
            else => {},
        },
    }
}

/// The three *Show* rows and the three *Align* rows, ticked on the
/// live `ui.dock.labels` / `ui.dock.align`. They are the family's
/// chip-menu idiom (the `sort:` and `view:` chips): every choice
/// listed, the current one wearing the ✓ — so there is no new command
/// id for a setting the ex word and the Settings row already reach. On
/// a side edge the *Show* rows still write the key, and they say so:
/// the strip is icon-only there by geometry.
fn appendLabelRows(app: *App, rows: *std.ArrayListUnmanaged(command.MenuItem)) Allocator.Error!void {
    const now = app.cfg.ui.dock.labels;
    const side = edge(app) != .bottom;
    try rows.append(app.gpa, .{
        .label = if (side) "Show: icons and labels (bottom edge only)" else "Show: icons and labels",
        .action = .{ .set_dock_labels = .icon_label },
        .checked = now == .icon_label,
        .separator_before = true,
    });
    try rows.append(app.gpa, .{
        .label = "Show: icons only",
        .action = .{ .set_dock_labels = .icon },
        .checked = now == .icon,
    });
    try rows.append(app.gpa, .{
        .label = if (side) "Show: labels only (bottom edge only)" else "Show: labels only",
        .action = .{ .set_dock_labels = .label },
        .checked = now == .label,
    });
    // // changed (dock-placement): where a bottom strip sits relative
    // to the two rows the frame keeps for itself. The words are the
    // person's, the key's values are `.inner` / `.outer`; on a side
    // edge the rows still write the key and say that it waits for the
    // bottom edge, the way the *Show* rows do.
    const place = app.cfg.ui.dock.placement;
    try rows.append(app.gpa, .{
        .label = if (side) "Place: above the statusline (bottom edge only)" else "Place: above the statusline",
        .action = .{ .set_dock_placement = .inner },
        .checked = place == .inner,
        .separator_before = true,
    });
    try rows.append(app.gpa, .{
        .label = if (side) "Place: below the command line (bottom edge only)" else "Place: below the command line",
        .action = .{ .set_dock_placement = .outer },
        .checked = place == .outer,
    });
    // // changed (dock-shared): the third row — on the `:` line's own
    // row, right of what is typed there.
    try rows.append(app.gpa, .{
        .label = if (side) "Place: on the command line (bottom edge only)" else "Place: on the command line",
        .action = .{ .set_dock_placement = .shared },
        .checked = place == .shared,
    });
    const at = app.cfg.ui.dock.@"align";
    try rows.append(app.gpa, .{
        .label = "Align: centre",
        .action = .{ .set_dock_align = .center },
        .checked = at == .center,
        .separator_before = true,
    });
    try rows.append(app.gpa, .{ .label = "Align: start", .action = .{ .set_dock_align = .start }, .checked = at == .start });
    try rows.append(app.gpa, .{ .label = "Align: end", .action = .{ .set_dock_align = .end }, .checked = at == .end });
    try rows.append(app.gpa, .{
        .label = "Show the + button",
        .action = .{ .set_dock_plus = !app.cfg.ui.dock.plus },
        .checked = app.cfg.ui.dock.plus,
        .separator_before = true,
    });
    // // changed (dock-polish): which end the `+` takes, in the words
    // of the edge the strip is on — `.right` is the bottom of a side
    // strip — and the running mark.
    const plus_end = plusAt(app);
    try rows.append(app.gpa, .{
        .label = if (side) "+ at the bottom end" else "+ at the right end",
        .action = .{ .set_dock_plus_at = .right },
        .checked = plus_end == .right,
    });
    try rows.append(app.gpa, .{
        .label = if (side) "+ at the top end" else "+ at the left end",
        .action = .{ .set_dock_plus_at = .left },
        .checked = plus_end == .left,
    });
    const mark = runningMark(app);
    try rows.append(app.gpa, .{
        .label = "Running mark: bright icon",
        .action = .{ .set_dock_running_mark = .bright },
        .checked = mark == .bright,
        .separator_before = true,
    });
    try rows.append(app.gpa, .{ .label = "Running mark: small dot", .action = .{ .set_dock_running_mark = .dot }, .checked = mark == .dot });
    try rows.append(app.gpa, .{ .label = "Running mark: none", .action = .{ .set_dock_running_mark = .none }, .checked = mark == .none });
}

/// The strip's own menu (the pin chip's right click): the three modes,
/// the three edges, and the two label forms.
pub fn openDockMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    var list: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    errdefer list.deinit(app.gpa);
    try list.append(app.gpa, .{ .label = if (app.launcher_dock.pinned) "Unpin dock" else "Pin dock open", .action = .{ .command = .@"view.dock_pin" } });
    try list.append(app.gpa, .{ .label = "Cycle mode (always / auto-hide / hidden)", .action = .{ .command = .@"view.dock_cycle_mode" }, .separator_before = true });
    try list.append(app.gpa, .{ .label = "Move to the next edge (bottom / left / right)", .action = .{ .command = .@"view.dock_move" } });
    try appendLabelRows(app, &list);
    try list.append(app.gpa, .{ .label = "Settings…", .action = .{ .command = .@"view.settings" }, .separator_before = true });
    try app.openMenu("Launcher dock", try list.toOwnedSlice(app.gpa), x, y);
}

/// An item's menu. A left click already runs it, so the rows here are
/// the ones a click cannot be: pin, unpin, and the strip's own verbs.
pub fn openItemMenu(app: *App, i: usize, x: u16, y: u16) Allocator.Error!void {
    const list = try items(app, app.frame.allocator());
    if (i >= list.len) return;
    const it = list[i];
    app.launcher_dock.cursor = @intCast(i);
    var rows: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    errdefer rows.deinit(app.gpa);
    switch (it.kind) {
        .pin => try rows.append(app.gpa, .{ .label = "Unpin from dock", .action = .{ .command = .@"view.dock_unpin_item" } }),
        // // changed (railmove): a moved section's way home, then the
        // plain unpin (which leaves it hidden on the bar).
        .pinned_panel => {
            if (activity_bar.sectionOfCommandName(it.id)) |s| try rows.append(app.gpa, .{ .label = "Move back to activity bar", .action = .{ .rail_from_dock = s } });
            try rows.append(app.gpa, .{ .label = "Unpin from dock", .action = .{ .command = .@"view.dock_unpin_item" } });
        },
        // An installed surface is on the strip because it is installed:
        // there is nothing to pin. A pin left in `ui.dock.pins` from
        // before still gets its way out.
        .integration, .launcher => if (integrations.isPinnedToDock(app, commandIdOf(app, it) orelse "")) {
            try rows.append(app.gpa, .{ .label = "Unpin from dock", .action = .{ .command = .@"integrations.unpin_from_dock" } });
            try integrations.setDockMenuChip(app, it.id);
        },
        else => {},
    }
    // // changed (dock-polish): the four *Move* rows, worded for the
    // edge the strip is on — left / right along a bottom strip, up /
    // down a side one — and never for the `+`, whose end is a setting.
    if (it.kind != .plus) {
        const side = edge(app) != .bottom;
        try rows.append(app.gpa, .{ .label = if (side) "Move up" else "Move left", .action = .{ .command = .@"view.dock_item_move_prev" }, .separator_before = rows.items.len > 0 });
        try rows.append(app.gpa, .{ .label = if (side) "Move down" else "Move right", .action = .{ .command = .@"view.dock_item_move_next" } });
        try rows.append(app.gpa, .{ .label = "Move to start", .action = .{ .command = .@"view.dock_item_move_first" } });
        try rows.append(app.gpa, .{ .label = "Move to end", .action = .{ .command = .@"view.dock_item_move_last" } });
    }
    try rows.append(app.gpa, .{ .label = if (app.launcher_dock.pinned) "Unpin dock" else "Pin dock open", .action = .{ .command = .@"view.dock_pin" }, .separator_before = true });
    try rows.append(app.gpa, .{ .label = "Cycle mode (always / auto-hide / hidden)", .action = .{ .command = .@"view.dock_cycle_mode" } });
    try rows.append(app.gpa, .{ .label = "Move to the next edge (bottom / left / right)", .action = .{ .command = .@"view.dock_move" } });
    try appendLabelRows(app, &rows);
    try app.openMenu(it.label, try rows.toOwnedSlice(app.gpa), x, y);
}

/// A pinned command's whole title, for the tooltip.
fn fullTitle(app: *App, it: Item) []const u8 {
    const ref = command.resolve(app, it.id) orelse return it.label;
    return switch (ref) {
        .static => |c| command.title(c),
        .dyn => |slot| if (app.dyn_commands.at(slot)) |c| c.title else it.label,
    };
}

/// The command id an item names — what `ui.dock.pins` stores.
/// Some item in `list` already runs command `id`.
fn alreadyRuns(app: *App, list: []const Item, id: []const u8) bool {
    for (list) |it| if (commandIdOf(app, it)) |have| if (std.mem.eql(u8, have, id)) return true;
    return false;
}

pub fn commandIdOf(app: *App, it: Item) ?[]const u8 {
    return switch (it.action) {
        .named => |id| id,
        .static => |id| command.name(id),
        .dyn => |slot| if (app.dyn_commands.at(slot)) |c| c.id else null,
        else => null,
    };
}

/// The command id of the item the cursor is parked at — the menu rows'
/// target.
pub fn focusedCommandId(app: *App) Allocator.Error!?[]const u8 {
    const list = try items(app, app.frame.allocator());
    if (app.launcher_dock.cursor >= list.len) return null;
    return commandIdOf(app, list[app.launcher_dock.cursor]);
}

// ─── the keyboard ───────────────────────────────────────────────────────

/// The strip's keys while it has them (`view.focus_dock`): `h` / `l` or
/// the arrows along a bottom strip, `j` / `k` along a side one, Enter
/// runs, Esc leaves. Anything else leaves and is handled below.
pub fn interceptKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.launcher_dock;
    if (!st.kb) return false;
    const horizontal = edge(app) == .bottom;
    switch (k.code) {
        .esc => {
            leave(app);
            return true;
        },
        .enter => {
            const at = st.cursor;
            leave(app);
            try activate(app, at);
            return true;
        },
        // // changed (dock-polish): with Alt, an arrow MOVES the item
        // instead of stepping the cursor; Home / End jump, and with Alt
        // they move the item to that end.
        .left, .up => {
            if (k.mods.alt) try moveCursorItem(app, .prev) else step(app, -1);
            return true;
        },
        .right, .down => {
            if (k.mods.alt) try moveCursorItem(app, .next) else step(app, 1);
            return true;
        },
        .home => {
            if (k.mods.alt) try moveCursorItem(app, .first) else jump(app, 0);
            return true;
        },
        .end => {
            if (k.mods.alt) try moveCursorItem(app, .last) else jump(app, st.count -| 1);
            return true;
        },
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) {
                leave(app);
                return false;
            }
            switch (c) {
                'h' => if (horizontal) {
                    step(app, -1);
                    return true;
                },
                'l' => if (horizontal) {
                    step(app, 1);
                    return true;
                },
                'k' => if (!horizontal) {
                    step(app, -1);
                    return true;
                },
                'j' => if (!horizontal) {
                    step(app, 1);
                    return true;
                },
                ' ' => {
                    const at = st.cursor;
                    leave(app);
                    try activate(app, at);
                    return true;
                },
                'q' => {
                    leave(app);
                    return true;
                },
                else => {},
            }
            // A key the strip has no answer for hands the keyboard back
            // and is handled below, so a forgotten focus cannot swallow
            // an `h` typed into the editor a minute later.
            leave(app);
            return false;
        },
        else => {
            leave(app);
            return false;
        },
    }
}

/// The strip gives up the keyboard (a press landed somewhere else).
pub fn leaveKeyboard(app: *App) void {
    leave(app);
}

fn step(app: *App, by: i32) void {
    const st = &app.launcher_dock;
    if (st.count == 0) return;
    const n: i32 = @intCast(st.count);
    var at: i32 = @as(i32, @intCast(st.cursor)) + by;
    if (at < 0) at = n - 1;
    if (at >= n) at = 0;
    st.cursor = @intCast(at);
    app.needs_render = true;
}

fn jump(app: *App, to: u16) void {
    const st = &app.launcher_dock;
    if (st.count == 0) return;
    st.cursor = @min(to, st.count - 1);
    app.needs_render = true;
}

/// A move from the keys: the strip keeps the keyboard, and a refused
/// move (the `+`, an end) is a toast rather than an error.
fn moveCursorItem(app: *App, how: Move) Allocator.Error!void {
    moveItem(app, app.launcher_dock.cursor, how) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

fn leave(app: *App) void {
    const st = &app.launcher_dock;
    st.kb = false;
    if (!st.pinned and st.open) close(app);
    app.needs_render = true;
}

// ─── hover copy ─────────────────────────────────────────────────────────

/// The tooltip (`ui/tooltip.zig`), the same mechanism the rail uses. A
/// side dock paints no label, so the tip is where the name lives.
pub fn describe(app: *App, arena: Allocator, part: Part) Allocator.Error!tooltip.Tip {
    switch (part) {
        .pin => return .{
            .title = if (app.launcher_dock.pinned) "Dock pinned" else "Pin the dock",
            // // changed (dock-shared): on the `:` line's row the strip
            // is always up, so the pin has nothing to keep open.
            .detail = if (sharesCmdline(app)) "on the command line's row the dock is always up · right-click: mode, edge, placement, settings" else "click keeps the dock open · right-click: mode, edge, placement, settings",
        },
        .item => |i| {
            const list = try items(app, arena);
            if (i >= list.len) return .{ .title = "Dock", .detail = "click runs this item" };
            const it = list[i];
            // The `+` is not a thing that runs: its tip is the verb.
            if (it.kind == .plus) return .{ .title = "New…", .detail = "click opens the new-thing menu — the tab bar's own" };
            return .{
                .title = try std.fmt.allocPrint(arena, "{s}{s}", .{ it.label, if (it.running) " · running" else "" }),
                .detail = switch (it.kind) {
                    .plus => "click opens the new-thing menu — the tab bar's own",
                    .integration => "click opens the integration · right-click: pin / unpin / move",
                    .launcher => "click runs the launcher · right-click: pin / unpin / move",
                    .terminal_new => "click opens a new shell · right-click: move",
                    .terminal => "click focuses this terminal · right-click: move",
                    .pin => "click runs the pinned command · right-click: unpin / move",
                    .pinned_panel => "click shows the section · right-click: move it back to the activity bar / unpin / move",
                },
                // The strip clips a pin's label; the tip carries the
                // whole command title.
                .lines = if (it.kind == .pin) try arena.dupe([]const u8, &.{fullTitle(app, it)}) else &.{},
            };
        },
    }
}

// ─── the runners ────────────────────────────────────────────────────────

/// `view.dock_toggle`: put a revealed strip away, or summon one — the
/// keyboard's door, which works under `.hidden` too.
fn toggleCmd(app: *App) CommandError!void {
    if (mode(app) == .always) {
        app.toast("the dock is always on (`view.dock_cycle_mode` to change)", .{});
        return;
    }
    if (app.launcher_dock.open) {
        close(app);
        return;
    }
    reveal(app, true);
}

/// `view.dock_pin`: a revealed strip docks for the session, and
/// `mode` reads `.always` until it is unpinned. Remembered in the
/// session file, never written to the config.
fn pinCmd(app: *App) CommandError!void {
    const st = &app.launcher_dock;
    if (st.pinned) {
        st.pinned = false;
        st.open = false;
        st.kb = false;
        app.toast("dock: {s}", .{@tagName(app.cfg.ui.dock.mode)});
        app.needs_render = true;
        return;
    }
    st.pinned = true;
    st.open = false;
    app.toast("dock pinned", .{});
    app.needs_render = true;
}

/// `view.dock_cycle_mode`: always → auto-hide → hidden → always, persisted.
fn cycleModeCmd(app: *App) CommandError!void {
    const next: Mode = switch (app.cfg.ui.dock.mode) {
        .always => .auto_hide,
        .auto_hide => .hidden,
        .hidden => .always,
    };
    try setMode(app, next);
}

pub fn setMode(app: *App, next: Mode) CommandError!void {
    app.cfg.ui.dock.mode = next;
    app.launcher_dock.pinned = false;
    if (next != .auto_hide) close(app);
    _ = try settings.persist(app, .home, &.{ "ui", "dock", "mode" }, next);
    app.toast("dock: {s}", .{@tagName(next)});
    app.needs_render = true;
}

/// `view.dock_move`: bottom → left → right → bottom, persisted.
fn moveCmd(app: *App) CommandError!void {
    const next: Edge = switch (app.cfg.ui.dock.edge) {
        .bottom => .left,
        .left => .right,
        .right => .bottom,
    };
    try setEdge(app, next);
}

pub fn setEdge(app: *App, next: Edge) CommandError!void {
    app.cfg.ui.dock.edge = next;
    // // changed (side-band): the strip MOVES with the edge rather than
    // being dismissed by it. It used to close here — "whatever was
    // revealed at the old edge is stale" — which made the pair of
    // settings order-dependent: `:dock left` then `view.dock_toggle`
    // left the strip up, the reverse order put it away, and a user who
    // had summoned the dock lost it by changing where it lives. The
    // band is well defined at every edge, so the strip simply paints
    // in the new one; the hide clock starts again from here.
    app.launcher_dock.left_at_ms = null;
    _ = try settings.persist(app, .home, &.{ "ui", "dock", "edge" }, next);
    app.toast("dock: {s} edge", .{@tagName(next)});
    app.needs_render = true;
}

/// `ui.dock.placement`, persisted: `:dock inner` / `:dock outer` /
/// `:dock shared` (and their `above` / `below` / `cmdline` spellings),
/// the Settings row and the three *Place:* rows on the strip's own right-click menu all land here. A
/// side dock takes the key without complaint — it is the BOTTOM
/// strip's question, and moving back to the bottom edge answers it.
pub fn setPlacement(app: *App, next: Placement) CommandError!void {
    app.cfg.ui.dock.placement = next;
    // The row moved: a strip revealed at the old one is stale.
    if (app.launcher_dock.open) close(app);
    _ = try settings.persist(app, .home, &.{ "ui", "dock", "placement" }, next);
    app.toast("dock: {s}", .{switch (next) {
        .inner => "above the statusline",
        .outer => "below the command line",
        .shared => "on the command line",
    }});
    app.needs_render = true;
}

/// `ui.dock.labels`, persisted: `:dock icons` / `:dock labels`, the
/// Settings row, and the strip's own right-click menu all land here.
/// A side dock takes the key without complaint — it is the bottom
/// form's question, and moving back to the bottom edge answers it.
pub fn setLabels(app: *App, next: Labels) CommandError!void {
    app.cfg.ui.dock.labels = next;
    _ = try settings.persist(app, .home, &.{ "ui", "dock", "labels" }, next);
    app.toast("dock: {s}", .{switch (next) {
        .icon => "icons only",
        .icon_label => "icons and labels",
        .label => "labels only",
    }});
    app.needs_render = true;
}

/// `ui.dock.align`, persisted: `:dock center|start|end`, the Settings
/// row and the strip's own right-click menu all land here. A side dock
/// takes it too — there it centres the items down the column.
pub fn setAlign(app: *App, next: Align) CommandError!void {
    app.cfg.ui.dock.@"align" = next;
    _ = try settings.persist(app, .home, &.{ "ui", "dock", "align" }, next);
    app.toast("dock: {s}", .{switch (next) {
        .start => "aligned to the start",
        .center => "centred",
        .end => "aligned to the end",
    }});
    app.needs_render = true;
}

/// `ui.dock.plus`, persisted: the `+` leads the strip or it does not.
/// `:dock plus` is the word form, the Settings row and the strip's own
/// right-click menu the others.
pub fn setPlus(app: *App, on: bool) CommandError!void {
    app.cfg.ui.dock.plus = on;
    _ = try settings.persist(app, .home, &.{ "ui", "dock", "plus" }, on);
    app.toast("dock: {s}", .{if (on) "the + is on the strip" else "no + on the strip"});
    app.needs_render = true;
}

/// // changed (dock-polish): `ui.dock.plus_at`, persisted: `:dock plus
/// left|right`, the Settings row and the two `+ at the …` rows on the
/// strip's menu all land here.
pub fn setPlusAt(app: *App, next: PlusAt) CommandError!void {
    app.cfg.ui.dock.plus_at = next;
    _ = try settings.persist(app, .home, &.{ "ui", "dock", "plus_at" }, next);
    app.toast("dock: the + at the {s} end", .{switch (next) {
        .right => if (edge(app) == .bottom) "right" else "bottom",
        .left => if (edge(app) == .bottom) "left" else "top",
    }});
    app.needs_render = true;
}

/// `ui.dock.running_mark`, persisted: `:dock mark bright|dot|none`,
/// the Settings row and the `Running mark:` rows on the strip's menu.
pub fn setRunningMark(app: *App, next: RunningMark) CommandError!void {
    app.cfg.ui.dock.running_mark = next;
    _ = try settings.persist(app, .home, &.{ "ui", "dock", "running_mark" }, next);
    app.toast("dock: running mark {s}", .{switch (next) {
        .bright => "is the bright icon",
        .dot => "is a small dot",
        .none => "off",
    }});
    app.needs_render = true;
}

/// `view.dock_item_move_*`: the item the cursor is on — the row a menu
/// was opened on, or the keyboard's — moves along the strip.
fn moveItemPrevCmd(app: *App) CommandError!void {
    return moveItem(app, app.launcher_dock.cursor, .prev);
}
fn moveItemNextCmd(app: *App) CommandError!void {
    return moveItem(app, app.launcher_dock.cursor, .next);
}
fn moveItemFirstCmd(app: *App) CommandError!void {
    return moveItem(app, app.launcher_dock.cursor, .first);
}
fn moveItemLastCmd(app: *App) CommandError!void {
    return moveItem(app, app.launcher_dock.cursor, .last);
}

/// `view.focus_dock`: the keys go into the strip, revealing it first
/// when it is not already up.
fn focusCmd(app: *App) CommandError!void {
    const st = &app.launcher_dock;
    if (!shown(app)) reveal(app, true);
    st.kb = true;
    st.touched = true;
    st.left_at_ms = null;
    app.needs_render = true;
}

/// `view.dock_unpin_item`: the focused item leaves `ui.dock.pins`.
fn unpinItemCmd(app: *App) CommandError!void {
    const id = (try focusedCommandId(app)) orelse
        return app.diag.fail(app.frame.allocator(), "dock: nothing focused to unpin", .{});
    return integrations.unpinDockId(app, id);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const render = @import("render.zig");

fn testApp(tmp: *std.testing.TmpDir, buf: []u8) !App {
    const n = try tmp.dir.realPath(t.io, buf);
    return App.initWith(t.allocator, t.io, .{ .workspace = buf[0..n], .data_root = buf[0..n], .cols = 120, .rows = 40 });
}

test "the model: the enabled integrations, then the New terminal item, then `ui.dock.pins`, then the `+` at the far end — an id nothing answers to is skipped rather than painted dead" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    app.cfg.ui.dock.pins = &.{ "picker.files", "no.such.command" };
    try app.render();
    const list = try items(&app, app.frame.allocator());
    // // changed (railmove): all four first-party surfaces, in the
    // config's order. Browser is the one whose CHIP is on out of the
    // box; the other three ship with the chip hidden, and a hidden
    // chip is not an uninstalled surface.
    try t.expectEqualStrings("Browser", list[0].label);
    try t.expectEqual(Kind.integration, list[0].kind);
    try t.expectEqualStrings("Claude Code", list[1].label);
    try t.expectEqualStrings("Codex", list[2].label);
    try t.expectEqualStrings("HTTP", list[3].label);
    for (list[0..4]) |it| try t.expectEqual(Kind.integration, it.kind);
    // The terminals, then the pins — the unresolvable id is skipped —
    // then the `+`, so the strip is exactly the four, New terminal,
    // picker.files, +.
    try t.expectEqual(@as(usize, 7), list.len);
    try t.expectEqual(Kind.terminal_new, list[4].kind);
    try t.expectEqualStrings("New terminal", list[4].label);
    try t.expectEqual(Kind.pin, list[5].kind);
    try t.expectEqualStrings(shortTitle(command.title(.@"picker.files")), list[5].label);
    try t.expectEqualStrings("picker.files", commandIdOf(&app, list[5]).?);
    // // changed (dock-polish): the `+` ENDS the run — the tab bar's
    // own, opening its menu — where a `+` reads naturally.
    try t.expectEqual(Kind.plus, list[6].kind);
    try t.expectEqualStrings("New", list[6].label);
    try t.expectEqualStrings(@import("../ui/bufferline.zig").plus_glyph, list[6].glyph);
    try t.expect(list[6].action == .menu);
    // It names no command id: the menu is not one, so nothing can pin it.
    try t.expect(commandIdOf(&app, list[6]) == null);
    // A pin that resolves to nothing never becomes a row.
    for (list) |it| try t.expect(!std.mem.eql(u8, it.id, "no.such.command"));
    // `ui.dock.plus_at = .left` puts it back at the head, the rest
    // unchanged behind it.
    app.cfg.ui.dock.plus_at = .left;
    const led = try items(&app, app.frame.allocator());
    try t.expectEqual(@as(usize, 7), led.len);
    try t.expectEqual(Kind.plus, led[0].kind);
    try t.expectEqualStrings("Browser", led[1].label);
    try t.expectEqual(Kind.pin, led[6].kind);
    app.cfg.ui.dock.plus_at = .right;
    // `ui.dock.plus = false` takes the `+` off and the rest closes up.
    app.cfg.ui.dock.plus = false;
    const without = try items(&app, app.frame.allocator());
    try t.expectEqual(@as(usize, 6), without.len);
    try t.expectEqualStrings("Browser", without[0].label);
    for (without) |it| try t.expect(it.kind != .plus);
}

test "a hidden chip is still on the dock: the strip reads installed-and-not-disabled, never the chip's visibility — a first-party row with `enabled = false`, a manifest with `in_palette_bar = false`; a DISABLED manifest and a missing binary are off it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "integrations");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "tool", .data = "#!/bin/sh\n" });
    const tool = try std.fs.path.join(t.allocator, &.{ root, "tool" });
    defer t.allocator.free(tool);
    // Three manifests, named to sort after the first-party four.
    // `zeta_hid`: the chip is OFF the palette bar — hidden — and the
    // binary is there. `zeta_off`: the chip is DISABLED. `zeta_gone`:
    // the binary is nowhere.
    const hid = try std.fmt.allocPrint(t.allocator, ".{{ .id = \"zeta_hid\", .label = \"Zeta hid\", .binary = \"{f}\", .chip = .{{ .glyph = \"Z\", .fallback = \"Z\", .color = \"green\", .in_palette_bar = false }}, .commands = .{{ .{{ .id = \"zeta_hid.open\", .title = \"Zeta hid: open\" }} }} }}", .{std.zig.fmtString(tool)});
    defer t.allocator.free(hid);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "integrations/zeta_hid.zon", .data = hid });
    const off = try std.fmt.allocPrint(t.allocator, ".{{ .id = \"zeta_off\", .label = \"Zeta off\", .binary = \"{f}\", .chip = .{{ .glyph = \"O\", .fallback = \"O\", .color = \"red\", .enabled = false }}, .commands = .{{ .{{ .id = \"zeta_off.open\", .title = \"Zeta off: open\" }} }} }}", .{std.zig.fmtString(tool)});
    defer t.allocator.free(off);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "integrations/zeta_off.zon", .data = off });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "integrations/zeta_gone.zon", .data = ".{ .id = \"zeta_gone\", .label = \"Zeta gone\", .binary = \"/definitely/not/here/zeta\", .chip = .{ .glyph = \"G\", .fallback = \"G\", .color = \"blue\" }, .commands = .{ .{ .id = \"zeta_gone.open\", .title = \"Zeta gone: open\" } } }" });
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("PATH", "/definitely/not/a/dir");
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 120, .rows = 40, .env = &env });
    defer app.deinit();
    app.cfg.ui.dock.plus = false;
    // The manifests are scanned at startup by the driver, not by
    // `initWith`; a test asks for the scan itself.
    try integrations.refresh(&app);
    try app.render();
    const list = try items(&app, app.frame.allocator());
    // The four first-party surfaces, the hidden-chip manifest, the
    // terminal item — and neither the disabled one nor the missing one.
    try t.expectEqual(@as(usize, 6), list.len);
    try t.expectEqualStrings("browser", list[0].id);
    try t.expectEqualStrings("claude_code", list[1].id);
    try t.expectEqualStrings("codex", list[2].id);
    try t.expectEqualStrings("http", list[3].id);
    try t.expectEqualStrings("zeta_hid", list[4].id);
    try t.expectEqual(Kind.terminal_new, list[5].kind);
    for (list) |it| {
        try t.expect(!std.mem.eql(u8, it.id, "zeta_off"));
        try t.expect(!std.mem.eql(u8, it.id, "zeta_gone"));
    }
    // The chips' own flags are exactly as they were: Claude's chip is
    // hidden (the Installed tab's `(hidden)`), and the hidden manifest
    // chip is not on the palette bar's strip. Both are on the dock.
    const claude = (try integrations.findChip(&app, app.frame.allocator(), "claude_code")).?;
    try t.expect(!claude.enabled);
    try t.expect(claude.on_dock);
    const strip = try integrations.chips(&app, app.frame.allocator());
    for (strip) |c| try t.expect(!std.mem.eql(u8, c.id, "zeta_hid"));
    const zh = (try integrations.findChip(&app, app.frame.allocator(), "zeta_hid")).?;
    try t.expect(zh.enabled and zh.on_dock and !zh.in_palette_bar);
    // Disabling Browser's CHIP takes it off the strip and leaves it on
    // the dock; disabling a MANIFEST takes it off both.
    app.cfg.ui.integration_icons = &.{ .{ .id = "browser", .command = "browser.open", .label = "Browser", .enabled = false, .in_palette_bar = false }, .{ .id = "claude_code", .command = "ai.claude_code", .label = "Claude Code", .enabled = false, .in_palette_bar = false }, .{ .id = "codex", .command = "ai.codex", .label = "Codex", .enabled = false, .in_palette_bar = false }, .{ .id = "http", .command = "view.activity_http", .label = "HTTP", .enabled = false, .in_palette_bar = false } };
    const again = try items(&app, app.frame.allocator());
    try t.expectEqual(@as(usize, 6), again.len);
    try t.expectEqualStrings("browser", again[0].id);
    // The strip lost the four (`in_palette_bar = false`); the two
    // manifests whose chips never left the bar are still there, dim.
    for (try integrations.chips(&app, app.frame.allocator())) |c| {
        try t.expect(integrations.firstPartyIndex(c.id) == null);
        try t.expect(!std.mem.eql(u8, c.id, "zeta_hid"));
    }
    // A custom icon (no first-party row behind it) has the one flag and
    // keeps reading it.
    app.cfg.ui.integration_icons = &.{ .{ .id = "mine", .command = "picker.files", .label = "Mine", .enabled = false, .in_palette_bar = false }, .{ .id = "ours", .command = "picker.files", .label = "Ours", .enabled = true, .in_palette_bar = false } };
    const custom = try items(&app, app.frame.allocator());
    try t.expectEqualStrings("ours", custom[0].id);
    for (custom) |it| try t.expect(!std.mem.eql(u8, it.id, "mine"));
}

test "colours: an integration wears its chip's role through the one resolver the tab cluster uses; a terminal wears the split cluster's chip colour as is, never a green of its own" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    try app.render();
    const list = try items(&app, app.frame.allocator());
    const th = &app.theme;
    // Browser's chip says `blue`; the dock item says the same role and
    // resolves to the same colour the chip does.
    const browser = (try integrations.findChip(&app, app.frame.allocator(), "browser")).?;
    try t.expectEqualStrings(browser.color, list[0].color.role);
    try t.expect(Theme.Color.eql(paletteColor(th, browser.color), resolveColor(th, list[0].color)));
    // The terminal item — after the four first-party surfaces
    // (railmove) — is the cluster chip's constant, exactly.
    try t.expectEqual(Kind.terminal_new, list[4].kind);
    try t.expect(list[4].color == .fixed);
    try t.expect(Theme.Color.eql(bufferline.terminal_chip_fg, resolveColor(th, list[4].color)));
    try t.expect(!Theme.Color.eql(th.palette.green, resolveColor(th, list[4].color)));
    // And a shell tab's icon is that same colour (`render.ptyIcon`), so
    // the ghost is one colour on the tab bar, in the cluster and on the
    // dock.
    try t.expect(Theme.Color.eql(bufferline.terminal_chip_fg, @as(Theme.Color, .{ .index = 15 })));
}

test "the running mark: the view is handed `ui.dock.running_mark`, `.bright` out of the box" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    try t.expectEqual(RunningMark.bright, runningMark(&app));
    try setRunningMark(&app, .dot);
    try t.expectEqual(RunningMark.dot, app.cfg.ui.dock.running_mark);
    try setRunningMark(&app, .none);
    try t.expectEqual(RunningMark.none, runningMark(&app));
    try setRunningMark(&app, .bright);
    // The plus end, the same way.
    try t.expectEqual(PlusAt.right, plusAt(&app));
    try setPlusAt(&app, .left);
    try t.expectEqual(PlusAt.left, app.cfg.ui.dock.plus_at);
    try setPlusAt(&app, .right);
}

test "order: `ui.dock.order` leads the strip with the listed ids, keeps the unlisted in their default order after them, ignores an id nothing answers to, and never moves the `+`" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    app.cfg.ui.dock.pins = &.{ "picker.files", "app.quit" };
    try app.render();
    // The default: the four first-party surfaces (railmove), New
    // terminal, picker.files, app.quit, +.
    const base = try items(&app, app.frame.allocator());
    try t.expectEqual(@as(usize, 8), base.len);
    try t.expectEqualStrings("browser", base[0].id);
    try t.expectEqualStrings("claude_code", base[1].id);
    try t.expectEqualStrings("codex", base[2].id);
    try t.expectEqualStrings("http", base[3].id);
    try t.expectEqualStrings("term.shell", base[4].id);
    try t.expectEqualStrings("picker.files", base[5].id);
    try t.expectEqualStrings("app.quit", base[6].id);
    try t.expectEqual(Kind.plus, base[7].kind);
    // A partial list: the listed lead in that order, the rest follow
    // as they were, the unknown id changes nothing, the `+` stays put.
    app.cfg.ui.dock.order = &.{ "app.quit", "nope.nope", "term.shell" };
    const some = try items(&app, app.frame.allocator());
    try t.expectEqual(@as(usize, 8), some.len);
    try t.expectEqualStrings("app.quit", some[0].id);
    try t.expectEqualStrings("term.shell", some[1].id);
    try t.expectEqualStrings("browser", some[2].id);
    try t.expectEqualStrings("claude_code", some[3].id);
    try t.expectEqualStrings("codex", some[4].id);
    try t.expectEqualStrings("http", some[5].id);
    try t.expectEqualStrings("picker.files", some[6].id);
    try t.expectEqual(Kind.plus, some[7].kind);
    // The `+` is not a rank: naming it in the list is ignored, and the
    // left end is still `plus_at`'s to give.
    app.cfg.ui.dock.order = &.{ plus_id, "picker.files" };
    const named = try items(&app, app.frame.allocator());
    try t.expectEqualStrings("picker.files", named[0].id);
    try t.expectEqual(Kind.plus, named[7].kind);
    app.cfg.ui.dock.order = &.{};
}

test "an installed item is never doubled by a pin of its own command, and its menu offers no Pin to dock" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    try app.render();
    const before = try items(&app, app.frame.allocator());
    try t.expectEqualStrings("Claude Code", before[1].label);
    const claude_cmd = try app.gpa.dupe(u8, commandIdOf(&app, before[1]).?);
    defer app.gpa.free(claude_cmd);
    const Rows = struct {
        fn has(items_: []const command.MenuItem, label: []const u8) bool {
            for (items_) |it| if (std.mem.eql(u8, it.label, label)) return true;
            return false;
        }
    };
    try openItemMenu(&app, 1, 10, 37);
    try t.expect(!Rows.has(app.overlay.menu.items, "Pin to dock"));
    try t.expect(!Rows.has(app.overlay.menu.items, "Unpin from dock"));
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // A pin of the same command (an older config, a pin from the
    // palette) adds no second item…
    const pins = [_][]const u8{claude_cmd};
    app.cfg.ui.dock.pins = &pins;
    const after = try items(&app, app.frame.allocator());
    try t.expectEqual(before.len, after.len);
    var n: usize = 0;
    for (after) |it| if (commandIdOf(&app, it)) |c| if (std.mem.eql(u8, c, claude_cmd)) {
        n += 1;
    };
    try t.expectEqual(@as(usize, 1), n);
    // …and the item's menu offers the pin's way out.
    try openItemMenu(&app, 1, 10, 37);
    try t.expect(Rows.has(app.overlay.menu.items, "Unpin from dock"));
    try t.expect(!Rows.has(app.overlay.menu.items, "Pin to dock"));
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    app.cfg.ui.dock.pins = &.{};
}

test "the item menu: the four Move rows say left / right on a bottom strip and up / down on a side one, from the edge — and the `+` gets none" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    try app.render();
    const Rows = struct {
        fn has(items_: []const command.MenuItem, label: []const u8) bool {
            for (items_) |it| if (std.mem.eql(u8, it.label, label)) return true;
            return false;
        }
    };
    // Item 0 is Browser on a bottom strip.
    try openItemMenu(&app, 0, 10, 37);
    var rows = app.overlay.menu.items;
    try t.expect(Rows.has(rows, "Move left"));
    try t.expect(Rows.has(rows, "Move right"));
    try t.expect(Rows.has(rows, "Move to start"));
    try t.expect(Rows.has(rows, "Move to end"));
    try t.expect(!Rows.has(rows, "Move up"));
    try t.expect(Rows.has(rows, "+ at the right end"));
    try t.expect(Rows.has(rows, "Running mark: bright icon"));
    // On a side edge the same rows read up / down, and the `+` rows
    // say bottom / top.
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    app.cfg.ui.dock.edge = .left;
    try openItemMenu(&app, 0, 1, 10);
    rows = app.overlay.menu.items;
    try t.expect(Rows.has(rows, "Move up"));
    try t.expect(Rows.has(rows, "Move down"));
    try t.expect(!Rows.has(rows, "Move left"));
    try t.expect(Rows.has(rows, "Move to start"));
    try t.expect(Rows.has(rows, "+ at the bottom end"));
    try t.expect(Rows.has(rows, "+ at the top end"));
    // The `+` — the last item — offers no move at all.
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    app.cfg.ui.dock.edge = .bottom;
    const list = try items(&app, app.frame.allocator());
    try t.expectEqual(Kind.plus, list[list.len - 1].kind);
    try openItemMenu(&app, list.len - 1, 10, 37);
    rows = app.overlay.menu.items;
    try t.expect(!Rows.has(rows, "Move left"));
    try t.expect(!Rows.has(rows, "Move to end"));
    try t.expect(Rows.has(rows, "Show the + button"));
}

test "moveItem: prev / next / first / last rewrite `ui.dock.order` as the whole strip, the cursor follows the item, an end is a toast, and the `+` refuses" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    app.cfg.ui.dock.pins = &.{"picker.files"};
    try app.render();
    // Browser, Claude Code, Codex, HTTP (railmove), New terminal,
    // picker.files, +. Move New terminal right.
    try moveItem(&app, 4, .next);
    var list = try items(&app, app.frame.allocator());
    try t.expectEqualStrings("browser", list[0].id);
    try t.expectEqualStrings("http", list[3].id);
    try t.expectEqualStrings("picker.files", list[4].id);
    try t.expectEqualStrings("term.shell", list[5].id);
    try t.expectEqual(Kind.plus, list[6].kind);
    try t.expectEqual(@as(u16, 5), app.launcher_dock.cursor);
    // The whole run was written, `+` left out, so the order survives
    // a reload and an item installed later follows it.
    try t.expectEqual(@as(usize, 6), app.cfg.ui.dock.order.len);
    try t.expectEqualStrings("browser", app.cfg.ui.dock.order[0]);
    try t.expectEqualStrings("claude_code", app.cfg.ui.dock.order[1]);
    try t.expectEqualStrings("codex", app.cfg.ui.dock.order[2]);
    try t.expectEqualStrings("http", app.cfg.ui.dock.order[3]);
    try t.expectEqualStrings("picker.files", app.cfg.ui.dock.order[4]);
    try t.expectEqualStrings("term.shell", app.cfg.ui.dock.order[5]);
    for (app.cfg.ui.dock.order) |id| try t.expect(!std.mem.eql(u8, id, plus_id));
    // Past the end is a toast and no write.
    try moveItem(&app, 5, .next);
    try t.expectEqualStrings("term.shell", app.cfg.ui.dock.order[5]);
    // First and last.
    try moveItem(&app, 5, .first);
    list = try items(&app, app.frame.allocator());
    try t.expectEqualStrings("term.shell", list[0].id);
    try t.expectEqual(@as(u16, 0), app.launcher_dock.cursor);
    // The order is READ BACK, not only written: a second app on the
    // same data root — a restart, loaded the way `main` loads, through
    // `config.load` with `$MNML_DATA_ROOT` naming the home file — builds
    // its strip from the file, and New terminal still leads Browser
    // there. (The pins were set in memory above, so the fresh strip is
    // the four first-party surfaces and the terminal — six with the `+`.)
    {
        var vars = std.process.Environ.Map.init(t.allocator);
        defer vars.deinit();
        try vars.put("MNML_DATA_ROOT", app.data_root);
        var loaded = try @import("../config/load.zig").load(t.allocator, t.io, .{ .workspace = app.data_root, .env = .{ .vars = &vars } });
        var again = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = app.data_root, .data_root = app.data_root, .cols = 120, .rows = 40 });
        loaded = undefined; // the app owns it now
        defer again.deinit();
        try again.render();
        try t.expectEqual(@as(usize, 6), again.cfg.ui.dock.order.len);
        try t.expectEqualStrings("term.shell", again.cfg.ui.dock.order[0]);
        const reloaded = try items(&again, again.frame.allocator());
        try t.expectEqual(@as(usize, 6), reloaded.len);
        try t.expectEqualStrings("term.shell", reloaded[0].id);
        try t.expectEqualStrings("browser", reloaded[1].id);
        try t.expectEqual(Kind.plus, reloaded[5].kind);
    }
    try moveItem(&app, 0, .last);
    list = try items(&app, app.frame.allocator());
    try t.expectEqualStrings("term.shell", list[5].id);
    try t.expectEqual(Kind.plus, list[6].kind);
    try moveItem(&app, 5, .prev);
    list = try items(&app, app.frame.allocator());
    try t.expectEqualStrings("term.shell", list[4].id);
    // The `+` does not move — its end is `plus_at`'s — and is never
    // written into the order.
    try moveItem(&app, 6, .prev);
    list = try items(&app, app.frame.allocator());
    try t.expectEqual(Kind.plus, list[6].kind);
    for (app.cfg.ui.dock.order) |id| try t.expect(!std.mem.eql(u8, id, plus_id));
    // Nothing focused is an error, not a crash.
    try t.expectError(error.Failed, moveItem(&app, 99, .next));
}

test "a pinned command wears the part of its title before the first parenthetical or dash, clipped to the strip's own width" {
    // Rust's palette titles are written for a wide line; the strip is
    // one row for every item there is.
    try t.expectEqualStrings("Browser: open Chrome", shortTitle("Browser: open Chrome (CDP) \u{2014} console / nav / eval"));
    try t.expectEqualStrings("Quit mnml", shortTitle("Quit mnml"));
    try t.expectEqualStrings("Terminal: open a NEW", shortTitle("Terminal: open a NEW shell (split beside)"));
    // Each cut earns its keep on a title short enough that the length
    // clip would not have made it: a parenthetical, a dash, a middle dot.
    try t.expectEqualStrings("Git: push", shortTitle("Git: push (force)"));
    try t.expectEqualStrings("Findings: rescan", shortTitle("Findings: rescan \u{2014} the .mnml/findings folder"));
    try t.expectEqualStrings("Sessions: table", shortTitle("Sessions: table \u{00b7} every run"));
    // A long title with nothing to cut at is clipped, never split
    // through a codepoint.
    const long = shortTitle("\u{00e9}\u{00e9}\u{00e9}\u{00e9}\u{00e9}\u{00e9}\u{00e9}\u{00e9}\u{00e9}\u{00e9}\u{00e9}\u{00e9}\u{00e9}\u{00e9}\u{00e9}");
    try t.expect(long.len <= pin_label_max);
    try t.expect(std.unicode.utf8ValidateSlice(long));
}

test "mode transitions: the cycle walks always → auto-hide → hidden and writes the key; a pin makes mode read always and unpinning gives it back" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    try t.expectEqual(Mode.auto_hide, mode(&app));
    try cycleModeCmd(&app);
    try t.expectEqual(Mode.hidden, app.cfg.ui.dock.mode);
    try cycleModeCmd(&app);
    try t.expectEqual(Mode.always, app.cfg.ui.dock.mode);
    try t.expect(docked(&app));
    try cycleModeCmd(&app);
    try t.expectEqual(Mode.auto_hide, app.cfg.ui.dock.mode);
    try t.expect(!docked(&app));
    // The pin overrides the config without changing it.
    try pinCmd(&app);
    try t.expectEqual(Mode.always, mode(&app));
    try t.expectEqual(Mode.auto_hide, app.cfg.ui.dock.mode);
    try pinCmd(&app);
    try t.expectEqual(Mode.auto_hide, mode(&app));
    // The edge cycle, and the strip it leaves behind.
    try t.expectEqual(Edge.bottom, edge(&app));
    try moveCmd(&app);
    try t.expectEqual(Edge.left, edge(&app));
    try moveCmd(&app);
    try t.expectEqual(Edge.right, edge(&app));
    try moveCmd(&app);
    try t.expectEqual(Edge.bottom, edge(&app));
}

test "the dwell: auto-hide reveals after reveal_ms in the band, stays while the pointer is on the strip, and hides hide_ms after it leaves" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    app.cfg.ui.dock.reveal_ms = 250;
    app.cfg.ui.dock.hide_ms = 400;
    const full = Rect.init(0, 0, 120, 40);
    const band = hover_zones.dockBand(&app, full).?;
    // // changed (dock-grip-row): the bottom band is the row the strip
    // paints — under the default `.inner` the editor area's last row,
    // above the statusline — so the hand and the items meet.
    try t.expectEqual(innerRow(full).?, band);
    try t.expectEqual(@as(u16, 37), band.y);
    try t.expectEqual(full.w, band.w);

    app.now_ms = 1000;
    app.hover = .{ .x = 60, .y = band.y };
    hover_zones.begin(&app, full, 1000);
    tick(&app, 1000);
    try t.expect(!revealed(&app));
    app.now_ms = 1250;
    hover_zones.begin(&app, full, 1250);
    tick(&app, 1250);
    try t.expect(revealed(&app));
    // The painter's own zone keeps it up while the pointer rests on it.
    hover_zones.register(&app, .{ .rect = band, .id = .launcher_dock, .dwell_ms = 250, .priority = hover_zones.prio_dock });
    app.now_ms = 2000;
    hover_zones.begin(&app, full, 2000);
    tick(&app, 2000);
    try t.expect(revealed(&app));
    // Away: the hide clock starts, and runs out 400 ms later.
    app.hover = .{ .x = 60, .y = 10 };
    app.now_ms = 2100;
    hover_zones.begin(&app, full, 2100);
    tick(&app, 2100);
    try t.expect(revealed(&app));
    try t.expectEqual(@as(i64, 2500), nextDeadlineMs(&app).?);
    app.now_ms = 2499;
    hover_zones.begin(&app, full, 2499);
    tick(&app, 2499);
    try t.expect(revealed(&app));
    app.now_ms = 2500;
    hover_zones.begin(&app, full, 2500);
    tick(&app, 2500);
    try t.expect(!revealed(&app));
}

test "under `.outer` the `:` line owns the bottom row outright: an open one refuses the reveal and puts a revealed strip away — a side strip, which covers none of that row, is not in contest" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    const cmdline = @import("cmdline.zig");
    app.cfg.ui.dock.reveal_ms = 250;
    // // changed (dock-placement): the rule is the `.outer` strip's —
    // it is the one that paints on the `:` line's row.
    try setPlacement(&app, .outer);
    const full = Rect.init(0, 0, 120, 40);
    const band = hover_zones.dockBand(&app, full).?;
    // The band IS the `:` line's row: that is the whole reason for the
    // rule below.
    try t.expectEqual(render.frameRects(full, .{}).cmdline.y, band.y);

    // Dwell with the line open: nothing comes up.
    cmdline.open(&app);
    try t.expect(cmdlineBlocks(&app));
    app.now_ms = 1000;
    app.hover = .{ .x = 60, .y = band.y };
    hover_zones.begin(&app, full, 1000);
    tick(&app, 1000);
    app.now_ms = 1400;
    hover_zones.begin(&app, full, 1400);
    tick(&app, 1400);
    try t.expect(!revealed(&app));

    // Closing the line asks for a FRESH dwell, and does not pop the
    // strip up the frame the line goes: the band is not registered at
    // all while a line is open (`hover_zones.registerGeometric`), so
    // the clock was down the whole time rather than running under it.
    cmdline.close(&app);
    try t.expect(!cmdlineBlocks(&app));
    hover_zones.begin(&app, full, 1400);
    tick(&app, 1400);
    try t.expect(!revealed(&app));
    app.now_ms = 1600;
    hover_zones.begin(&app, full, 1600);
    tick(&app, 1600);
    try t.expect(!revealed(&app));
    app.now_ms = 1800;
    hover_zones.begin(&app, full, 1800);
    tick(&app, 1800);
    try t.expect(revealed(&app));

    // Opening the line over a revealed strip puts the strip away
    // rather than typing under it.
    cmdline.open(&app);
    tick(&app, 1800);
    try t.expect(!revealed(&app));
    cmdline.close(&app);

    // A side strip covers no part of that row, so the line is no
    // business of its own.
    try setEdge(&app, .left);
    cmdline.open(&app);
    try t.expect(!cmdlineBlocks(&app));
    const side = hover_zones.dockBand(&app, full).?;
    app.now_ms = 3000;
    app.hover = .{ .x = side.x, .y = 10 };
    hover_zones.begin(&app, full, 3000);
    tick(&app, 3000);
    app.now_ms = 3300;
    hover_zones.begin(&app, full, 3300);
    tick(&app, 3300);
    try t.expect(revealed(&app));

    // A docked strip is carved, not painted over anything, so it is
    // never in contest either.
    cmdline.close(&app);
    try setEdge(&app, .bottom);
    try setMode(&app, .always);
    cmdline.open(&app);
    try t.expect(!cmdlineBlocks(&app));
    try t.expect(docked(&app));
}

test "zone arbitration: a left dock owns its WHOLE band and the auto-hiding sidebar's reveal edge starts where that band ends; hidden gives the edge back" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    app.cfg.ui.sidebar = .auto;
    app.cfg.ui.dock.edge = .left;
    app.now_ms = 1000;
    const full = Rect.init(0, 0, 120, 40);
    // // changed (side-band): the band is the strip's own three
    // columns, not one of them, and all three are the dock's. It used
    // to be column 0 alone, with the sidebar's edge one cell in — so
    // an `always` dock's three columns and the hidden column's reveal
    // edge overlapped, and the column's grip painted over the dock's
    // own glyphs.
    for ([_]u16{ 0, 1, 2 }) |x| {
        app.hover = .{ .x = x, .y = 10 };
        hover_zones.begin(&app, full, 1000);
        try t.expectEqual(@as(?hover_zones.Id, .launcher_dock), hover_zones.winner(&app));
    }
    // The first column outside the band summons the sidebar.
    app.hover = .{ .x = width, .y = 10 };
    hover_zones.begin(&app, full, 1000);
    try t.expectEqual(@as(?hover_zones.Id, .sidebar_left), hover_zones.winner(&app));
    // A hidden dock claims nothing, and column 0 is the sidebar's again.
    app.cfg.ui.dock.mode = .hidden;
    app.hover = .{ .x = 0, .y = 10 };
    hover_zones.begin(&app, full, 1000);
    try t.expectEqual(@as(?hover_zones.Id, .sidebar_left), hover_zones.winner(&app));
    // The top row stays the menu bar's whatever the dock's edge is:
    // the band never reaches it.
    app.cfg.ui.dock.mode = .always;
    const band = hover_zones.dockBand(&app, full).?;
    try t.expect(band.y > 0);
    try t.expectEqual(width, band.w);
}

test "the keyboard: h / l walk a bottom strip and wrap, j / k do not; Enter runs and leaves; Esc leaves" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    try focusCmd(&app);
    try app.render();
    try t.expect(app.launcher_dock.kb);
    try t.expect(app.launcher_dock.count >= 2);
    try t.expectEqual(@as(u16, 0), app.launcher_dock.cursor);
    try t.expect(try interceptKey(&app, Key.char('l')));
    try t.expectEqual(@as(u16, 1), app.launcher_dock.cursor);
    // `j` is the SIDE strip's key: a bottom dock does not take it —
    // and a key the strip has no answer for hands the keyboard back
    // rather than swallowing the next one typed into the editor.
    try t.expect(!try interceptKey(&app, Key.char('j')));
    try t.expect(!app.launcher_dock.kb);
    try t.expect(!try interceptKey(&app, Key.char('h')));
    try focusCmd(&app);
    try app.render();
    app.launcher_dock.cursor = 1;
    try t.expect(try interceptKey(&app, Key.char('h')));
    try t.expectEqual(@as(u16, 0), app.launcher_dock.cursor);
    // Wrapping backwards from the first lands on the last.
    try t.expect(try interceptKey(&app, Key.char('h')));
    try t.expectEqual(app.launcher_dock.count - 1, app.launcher_dock.cursor);
    // Esc hands the keys back.
    try t.expect(try interceptKey(&app, .{ .code = .esc }));
    try t.expect(!app.launcher_dock.kb);
    try t.expect(!try interceptKey(&app, Key.char('l')));
}

test "a side dock on a narrow screen paints nothing rather than eating the editor; a right dock's cells end at the frame's far column" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    app.cfg.ui.dock.edge = .left;
    try t.expect(overlayRect(&app, Rect.init(0, 0, side_min_width - 1, 20)).isEmpty());
    const left = overlayRect(&app, Rect.init(0, 0, 120, 40));
    try t.expectEqual(@as(u16, width), left.w);
    try t.expectEqual(@as(u16, 0), left.x);
    app.cfg.ui.dock.edge = .right;
    const right = overlayRect(&app, Rect.init(0, 0, 120, 40));
    try t.expectEqual(@as(u16, 120), right.right());
    try t.expectEqual(@as(u16, width), right.w);
}

test "the label form: `ui.dock.labels` is written and read back, and a side edge paints icons whatever it says" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    // The default is today's row: glyph and label.
    try t.expectEqual(Labels.icon_label, labels(&app));
    try setLabels(&app, .icon);
    try t.expectEqual(Labels.icon, app.cfg.ui.dock.labels);
    try t.expectEqual(Labels.icon, labels(&app));
    try setLabels(&app, .icon_label);
    try t.expectEqual(Labels.icon_label, labels(&app));
    // A side dock has three cells and no room for a label, so it reads
    // `.icon` without touching the key — moving back answers it again.
    try setEdge(&app, .left);
    try t.expectEqual(Labels.icon, labels(&app));
    try t.expectEqual(Labels.icon_label, app.cfg.ui.dock.labels);
    try setEdge(&app, .bottom);
    try t.expectEqual(Labels.icon_label, labels(&app));
    // The key reached the file the settings row would write.
    try setLabels(&app, .icon);
    const text = try tmp.dir.readFileAlloc(t.io, "config.zon", t.allocator, .limited(1 << 16));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".labels = .icon,") != null);
}

test "the third label form: `.label` is written and read back, and a side edge still paints the icon form — it has three cells whatever the key says" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    try setLabels(&app, .label);
    try t.expectEqual(Labels.label, app.cfg.ui.dock.labels);
    try t.expectEqual(Labels.label, labels(&app));
    // Under `.label` the `+` wears its plus as a character of the word
    // — the form paints no glyphs at all. // changed (dock-polish): the
    // `+` is the LAST item now.
    try app.render();
    const worded = try items(&app, app.frame.allocator());
    try t.expectEqualStrings("+ New", worded[worded.len - 1].label);
    try setLabels(&app, .icon_label);
    const iconed = try items(&app, app.frame.allocator());
    try t.expectEqualStrings("New", iconed[iconed.len - 1].label);
    // A side dock reads `.icon` without touching the key, as it does
    // for `.icon_label`.
    try setLabels(&app, .label);
    try setEdge(&app, .left);
    try t.expectEqual(Labels.icon, labels(&app));
    try t.expectEqual(Labels.label, app.cfg.ui.dock.labels);
    const side = try items(&app, app.frame.allocator());
    try t.expectEqualStrings("New", side[side.len - 1].label);
    try setEdge(&app, .bottom);
    try t.expectEqual(Labels.label, labels(&app));
    const text = try tmp.dir.readFileAlloc(t.io, "config.zon", t.allocator, .limited(1 << 16));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".labels = .label,") != null);
}

test "`ui.dock.align`: the default is centred, the three values are written and read back, and the file wears the keyword's quotes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    // The user's own setup: centred out of the box.
    try t.expectEqual(Align.center, alignment(&app));
    try setAlign(&app, .start);
    try t.expectEqual(Align.start, alignment(&app));
    try setAlign(&app, .end);
    try t.expectEqual(Align.end, alignment(&app));
    try setAlign(&app, .center);
    try t.expectEqual(Align.center, alignment(&app));
    // A side dock takes the key too — it centres down the column there.
    try setEdge(&app, .left);
    try t.expectEqual(Align.center, alignment(&app));
    // `align` is a Zig keyword, so the key is quoted in the file; a
    // bare `.align = ` would not parse back.
    try setAlign(&app, .end);
    const text = try tmp.dir.readFileAlloc(t.io, "config.zon", t.allocator, .limited(1 << 16));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".@\"align\" = .end,") != null);
    try t.expect(std.mem.indexOf(u8, text, ".align = ") == null);
}

test "the strip's Settings rows: the six discrete `ui.dock.*` choices, each reading the live config" {
    // v1 Settings is discrete choices; the dock's dwells and its pins
    // stay config-only. A row whose path stopped resolving would not
    // compile, so this pins WHICH rows the overlay offers.
    const rows = @import("settings.zig").rows;
    const want = [_][]const u8{ "ui.dock.mode", "ui.dock.edge", "ui.dock.placement", "ui.dock.labels", "ui.dock.align", "ui.dock.plus" };
    for (want) |path| {
        var found = false;
        for (rows) |r| if (std.mem.eql(u8, r.path, path)) {
            found = true;
            break;
        };
        try t.expect(found);
    }
    // The two new ones offer exactly the choices the enum has.
    try t.expectEqual(@as(usize, 3), @import("settings.zig").options("ui.dock.align").len);
    try t.expectEqual(@as(usize, 3), @import("settings.zig").options("ui.dock.labels").len);
    try t.expectEqual(@as(usize, 2), @import("settings.zig").options("ui.dock.plus").len);
    // // changed (dock-placement): the placement row offers the two
    // choices in a person's words rather than the enum's tags — the
    // list is in tag order, so `.inner` is still index 0.
    // // changed (dock-shared): and a third, `on command line`.
    const place_opts = @import("settings.zig").options("ui.dock.placement");
    try t.expectEqual(@as(usize, 3), place_opts.len);
    try t.expectEqualStrings("above statusline", place_opts[0]);
    try t.expectEqualStrings("below command line", place_opts[1]);
    try t.expectEqualStrings("on command line", place_opts[2]);
    var fresh: @import("../config/Config.zig") = .{};
    try t.expectEqual(@as(usize, 0), @import("settings.zig").currentIndex(&fresh, "ui.dock.placement"));
    @import("settings.zig").setIndex(&fresh, "ui.dock.placement", 1);
    try t.expectEqual(Placement.outer, fresh.ui.dock.placement);
    @import("settings.zig").setIndex(&fresh, "ui.dock.placement", 2);
    try t.expectEqual(Placement.shared, fresh.ui.dock.placement);
    try t.expectEqual(@as(usize, 2), @import("settings.zig").currentIndex(&fresh, "ui.dock.placement"));
}

test "the `+`: its hover copy is the verb, its menu is the tab bar's own, and the keyboard's End reaches it — it ends the run" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    try app.render();
    // // changed (dock-polish): the `+` is the last item.
    const last = (try items(&app, app.frame.allocator())).len - 1;
    const tip = try describe(&app, app.frame.allocator(), .{ .item = @intCast(last) });
    try t.expectEqualStrings("New\u{2026}", tip.title);
    // Running it opens the `+` menu — `Create\u{2026}`, the one
    // `context_menus.openNewTabMenu` builds for the tab bar.
    try activateAt(&app, last, 4, 37);
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("Create\u{2026}", app.overlay.menu.title);
    try t.expect(app.overlay.menu.items.len > 0);
    // `view.focus_dock` parks on the first item — Browser — and End
    // jumps to the `+`.
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    try focusCmd(&app);
    try app.render();
    try t.expectEqual(@as(u16, 0), app.launcher_dock.cursor);
    try t.expect(try interceptKey(&app, .{ .code = .end }));
    try t.expectEqual(@as(u16, @intCast(last)), app.launcher_dock.cursor);
    try t.expect(try interceptKey(&app, .{ .code = .home }));
    try t.expectEqual(@as(u16, 0), app.launcher_dock.cursor);
    leave(&app);
}

test "`ui.dock.placement`: `.inner` is the default and the strip is the EDITOR AREA's last row — carved and revealed on the same row, with the statusline and the `:` line left where they are" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    const full = Rect.init(0, 0, 120, 40);
    // The user's preference is what mnml ships.
    try t.expectEqual(Placement.inner, placement(&app));
    try t.expectEqual(Placement.inner, app.cfg.ui.dock.placement);

    // Carved: `upper` gives up its last row and nothing else moves.
    const none = render.frameRects(full, .{});
    const inner = render.frameRects(full, render.chrome(&app));
    try t.expect(inner.launcher_dock.isEmpty()); // auto_hide carves nothing
    try setMode(&app, .always);
    const carved = render.frameRects(full, render.chrome(&app));
    try t.expectEqual(Rect.init(0, 37, 120, 1), carved.launcher_dock);
    try t.expect(carved.status.eql(none.status) and carved.cmdline.eql(none.cmdline));

    // Revealed: the SAME row, so the strip does not move when the mode
    // does — the reveal is paint over the editor's last line.
    try setMode(&app, .auto_hide);
    try t.expectEqual(carved.launcher_dock, overlayRect(&app, full));
    try t.expectEqual(carved.launcher_dock, innerRow(full).?);

    // `.outer` is the other row, and it takes the `:` line's.
    try setPlacement(&app, .outer);
    try t.expectEqual(Rect.init(0, 39, 120, 1), overlayRect(&app, full));
    try setMode(&app, .always);
    try t.expectEqual(Rect.init(0, 39, 120, 1), render.frameRects(full, render.chrome(&app)).launcher_dock);
    try t.expectEqual(@as(u16, 37), render.frameRects(full, render.chrome(&app)).status.y);

    // A side dock is a column: it reads `.inner` whatever the key says,
    // and neither of those two rows is its business.
    try setEdge(&app, .left);
    try t.expectEqual(Placement.inner, placement(&app));
    try t.expectEqual(Placement.outer, app.cfg.ui.dock.placement);
    try setEdge(&app, .bottom);
    try t.expectEqual(Placement.outer, placement(&app));

    // The key reached the file the settings row would write.
    try setPlacement(&app, .inner);
    const text = try tmp.dir.readFileAlloc(t.io, "config.zon", t.allocator, .limited(1 << 16));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".placement = .inner,") != null);
}

/// The rows a bottom strip's grip and items are on, read off the
/// painted screen: the grip's `⋯` while the strip is down, then the
/// `New terminal` item after a hover dwell on the grip, after a click
/// on it (the pin) and after `view.focus_dock` (the keyboard).
const GripRows = struct { grip: ?u16, hover: ?u16, click: ?u16, keyboard: ?u16 };

fn rowContaining(app: *App, needle: []const u8) ?u16 {
    var buf: [4096]u8 = undefined;
    var y: u16 = 0;
    while (y < app.screen.height) : (y += 1) {
        const text = @import("../ui/canvas.zig").rowText(&app.screen, y, &buf);
        if (std.mem.indexOf(u8, text, needle) != null) return y;
    }
    return null;
}

fn gripAndItemRows(app: *App) !GripRows {
    const dispatch = @import("dispatch.zig");
    var out: GripRows = .{ .grip = null, .hover = null, .click = null, .keyboard = null };
    app.cfg.ui.dock.reveal_ms = 250;
    app.cfg.ui.dock.hide_ms = 300;
    app.hover = .{ .x = 0, .y = 10 };
    app.now_ms = 1000;
    try app.render();
    out.grip = rowContaining(app, edge_grip_glyph);
    const gy = out.grip orelse return out;
    const gx: u16 = @intCast(app.screen.width / 2);
    // Hover: rest on the grip for the dwell.
    app.hover = .{ .x = gx, .y = gy };
    app.now_ms = 2000;
    try app.render();
    app.now_ms = 2300;
    try app.render();
    if (revealed(app)) out.hover = rowContaining(app, "New terminal");
    // Away, and wait out the hide clock.
    app.hover = .{ .x = 0, .y = 10 };
    app.now_ms = 3000;
    try app.render();
    app.now_ms = 3400;
    try app.render();
    try t.expect(!revealed(app));
    // Click: a press on the grip pins the strip.
    try dispatch.mouse(app, .{ .x = gx, .y = gy, .kind = .press, .button = .left }, 1);
    try dispatch.mouse(app, .{ .x = gx, .y = gy, .kind = .release, .button = .left }, 1);
    app.hover = .{ .x = 0, .y = 10 };
    try app.render();
    if (app.launcher_dock.pinned) {
        out.click = rowContaining(app, "New terminal");
        try pinCmd(app);
    }
    try t.expect(!app.launcher_dock.pinned);
    app.now_ms = 4000;
    try app.render();
    // Keyboard: `view.focus_dock`.
    try focusCmd(app);
    try app.render();
    if (shown(app)) out.keyboard = rowContaining(app, "New terminal");
    leave(app);
    return out;
}

const edge_grip_glyph = "\u{22EF}";

test "the grip and the items are ONE row in each placement — hover, click and keyboard all bring the strip up on the grip's own row" {
    // // changed (dock-grip-row): the user's rule — the items appear
    // where the grip is, never apart from it. Under the default
    // `.inner` the grip used to sit on the screen's last row while
    // the strip painted two rows up, above the statusline.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    _ = try app.openScratch();
    const full = Rect.init(0, 0, 120, 40);
    try t.expectEqual(Placement.inner, placement(&app));

    // `.inner`: above the statusline — the editor area's last row.
    const inner = try gripAndItemRows(&app);
    try t.expectEqual(@as(?u16, 37), inner.grip);
    try t.expectEqual(inner.grip, inner.hover);
    try t.expectEqual(inner.grip, inner.click);
    try t.expectEqual(inner.grip, inner.keyboard);
    try t.expectEqual(innerRow(full).?, hover_zones.dockBand(&app, full).?);

    // `.outer`: the screen's last row, under the `:` line.
    try setPlacement(&app, .outer);
    const outer = try gripAndItemRows(&app);
    try t.expectEqual(@as(?u16, 39), outer.grip);
    try t.expectEqual(outer.grip, outer.hover);
    try t.expectEqual(outer.grip, outer.click);
    try t.expectEqual(outer.grip, outer.keyboard);
}

test "an `.inner` grip never paints over the panes' text on its row: it takes the blank cells nearest the middle, and stands down when the row has none" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    // Every row full of text: no three blank cells on row 37.
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(t.allocator);
    for (0..60) |_| {
        try text.appendNTimes(t.allocator, 'x', 200);
        try text.append(t.allocator, '\n');
    }
    try app.activeEditor().?.buf.editor.setText(text.items);
    app.hover = .{ .x = 0, .y = 10 };
    try app.render();
    try t.expectEqual(@as(?u16, null), rowContaining(&app, edge_grip_glyph));
    // The band is still the row, so the dwell still brings the strip up.
    try t.expectEqual(@as(u16, 37), hover_zones.dockBand(&app, Rect.init(0, 0, 120, 40)).?.y);
    // Short lines leave the middle blank: the grip is back, on row 37.
    try app.activeEditor().?.buf.editor.setText("short\n");
    try app.render();
    try t.expectEqual(@as(?u16, 37), rowContaining(&app, edge_grip_glyph));
}

test "`.shared` wears no grip: the strip is always up, on the `:` line's row" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    _ = try app.openScratch();
    try setPlacement(&app, .shared);
    try app.render();
    try t.expect(!gripShown(&app));
    try t.expectEqual(@as(?u16, null), rowContaining(&app, edge_grip_glyph));
    try t.expectEqual(@as(?u16, 39), rowContaining(&app, "New terminal"));
    try focusCmd(&app);
    try app.render();
    try t.expectEqual(@as(?u16, 39), rowContaining(&app, "New terminal"));
    leave(&app);
}

test "the `:` line and an `.inner` strip coexist: the line's rule is `.outer`'s alone, and only the `.outer` grip — the one on the line's own row — stands down" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    const cmdline = @import("cmdline.zig");
    const edge_grip = @import("../ui/edge_grip.zig");
    const full = Rect.init(0, 0, 120, 40);
    try t.expect(app.cfg.ui.edge_grips);

    // The grip: three cells at the middle of the strip's own row —
    // the editor area's last under `.inner`, the screen's under `.outer`.
    try t.expect(gripShown(&app));
    try t.expectEqual(Rect.init(58, 37, 3, 1), edge_grip.place(hover_zones.dockBand(&app, full).?, .bottom).?);
    try setPlacement(&app, .outer);
    try t.expectEqual(Rect.init(58, 39, 3, 1), edge_grip.place(hover_zones.dockBand(&app, full).?, .bottom).?);

    // An open `:` line takes the row back from the `.outer` strip AND
    // from the grip.
    cmdline.open(&app);
    try t.expect(cmdlineBlocks(&app));
    try t.expect(!gripShown(&app));
    cmdline.close(&app);

    // Under `.inner` the strip and its grip cover none of that row, so
    // the line's rule does not apply to either: the grip stays up.
    try setPlacement(&app, .inner);
    cmdline.open(&app);
    try t.expect(!cmdlineBlocks(&app));
    try t.expect(!gripBlocked(&app));
    try t.expect(gripShown(&app));
    // And the band goes on being watched, so a dwell still reveals.
    app.cfg.ui.dock.reveal_ms = 250;
    app.now_ms = 3000;
    app.hover = .{ .x = 60, .y = 37 };
    hover_zones.begin(&app, full, 3000);
    tick(&app, 3000);
    app.now_ms = 3300;
    hover_zones.begin(&app, full, 3300);
    tick(&app, 3300);
    try t.expect(revealed(&app));
    try t.expectEqual(@as(u16, 37), overlayRect(&app, full).y);
    cmdline.close(&app);
}

test "the running mark follows real state: a session whose child exited loses it, and the Claude Code item is lit while any Claude session lives" {
    // sess-dock-running-dot.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    const path = try std.fmt.allocPrint(t.allocator, "{s}/ai:{s}", .{ @import("build_options").shims_dir, app.env.get("PATH") orelse "/usr/bin:/bin" });
    defer t.allocator.free(path);
    try app.env.put("PATH", path);
    const Probe = struct {
        fn item(list: []const Item, id: []const u8) Item {
            for (list) |it| if (it.kind == .integration and std.mem.eql(u8, it.id, id)) return it;
            unreachable;
        }
        fn terminals(list: []const Item, out: *[2]bool) usize {
            var n: usize = 0;
            for (list) |it| if (it.kind == .terminal) {
                if (n < out.len) out[n] = it.running;
                n += 1;
            };
            return n;
        }
    };
    // Nothing running: the Claude Code item is dark.
    try t.expect(!Probe.item(try items(&app, app.frame.allocator()), "claude_code").running);
    try command.run(&app, .{ .static = .@"ai.claude_code_new" });
    const first = app.active.?;
    try command.run(&app, .{ .static = .@"ai.claude_code_new" });
    var marks: [2]bool = undefined;
    var list = try items(&app, app.frame.allocator());
    try t.expect(Probe.item(list, "claude_code").running);
    try t.expect(!Probe.item(list, "codex").running);
    try t.expectEqual(@as(usize, 2), Probe.terminals(list, &marks));
    try t.expect(marks[0] and marks[1]);
    // One exits: its item keeps its place and loses the mark; the other
    // still lights the Claude Code item.
    app.panes.pty(first).?.exit = .{ .code = 3 };
    list = try items(&app, app.frame.allocator());
    try t.expectEqual(@as(usize, 2), Probe.terminals(list, &marks));
    try t.expect(!marks[0] and marks[1]);
    try t.expect(Probe.item(list, "claude_code").running);
    // Both gone: dark again.
    app.panes.pty(app.active.?).?.exit = .{ .code = 0 };
    list = try items(&app, app.frame.allocator());
    try t.expect(!Probe.item(list, "claude_code").running);
}

// ─── `.shared`: the strip on the `:` line's row ─────────────────────────

/// The row a `.shared` strip's items answer on: the first and one past
/// the last column with an item hit, or null when none does.
fn itemSpan(app: *const App, y: u16) ?struct { start: u16, end: u16 } {
    var start: ?u16 = null;
    var end: u16 = 0;
    const w: u16 = @intCast(app.screen.width);
    var x: u16 = 0;
    while (x < w) : (x += 1) {
        const h = app.hits.at(x, y) orelse continue;
        if (h != .launcher_dock or h.launcher_dock != .item) continue;
        if (start == null) start = x;
        end = x + 1;
    }
    return if (start) |s| .{ .start = s, .end = end } else null;
}

/// Any launcher-dock hit anywhere on the screen.
fn anyDockHit(app: *const App) bool {
    const w: u16 = @intCast(app.screen.width);
    const hgt: u16 = @intCast(app.screen.height);
    var y: u16 = 0;
    while (y < hgt) : (y += 1) {
        var x: u16 = 0;
        while (x < w) : (x += 1) {
            if (app.hits.at(x, y)) |h| if (h == .launcher_dock) return true;
        }
    }
    return false;
}

/// Open the app's `:` line holding `s`, the caret at its end.
fn typeLine(app: *App, s: []const u8) !void {
    const cmdline = @import("cmdline.zig");
    if (app.cmdline == null) cmdline.open(app);
    const c = &app.cmdline.?;
    c.text.clearRetainingCapacity();
    try c.text.appendSlice(app.gpa, s);
    c.caret = s.len;
}

test "`.shared`: the strip lives ON the `:` line's row — no row carved, no grip, `auto_hide` reading `always`, the run centred and the pin chip at the far end, the rest of the row still the `:` line's click target" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    const full = Rect.init(0, 0, 120, 40);
    try t.expectEqual(Mode.auto_hide, app.cfg.ui.dock.mode);
    try setPlacement(&app, .shared);
    try t.expect(sharesCmdline(&app));
    // Nothing to summon: the mode reads `always`, the file keeps its own.
    try t.expectEqual(Mode.always, mode(&app));
    try t.expectEqual(Mode.auto_hide, app.cfg.ui.dock.mode);
    try t.expect(!gripShown(&app));
    try t.expect(!banded(&app));
    // No row is carved: the frame is the dock-less one, row for row.
    const none = render.frameRects(full, .{});
    const fr = render.frameRects(full, render.chrome(&app));
    try t.expect(fr.launcher_dock.isEmpty());
    try t.expect(fr.upper.eql(none.upper) and fr.status.eql(none.status) and fr.cmdline.eql(none.cmdline));

    try app.render();
    // The strip is the `:` row, and it is up without any dwell.
    try t.expectEqual(Rect.init(0, 39, 120, 1), app.launcher_dock.rect);
    const span = itemSpan(&app, 39).?;
    const run_w = span.end - span.start;
    // Centred in 1..117 exactly as the bottom strip is (the view's own
    // `rowStart`): the pin chip keeps 117..119.
    try t.expectEqual(@max(@as(u16, 1), (117 - run_w) / 2), span.start);
    try t.expect(app.hits.at(118, 39).?.launcher_dock == .pin);
    // Left of the run the row is still the `:` line's click target.
    const bar = app.hits.at(2, 39).?;
    try t.expect(bar == .button and bar.button == @intFromEnum(render.Button.cmdline_bar));
    // No item anywhere else on the screen, and no dwell band watched.
    try t.expect(itemSpan(&app, 37) == null and itemSpan(&app, 38) == null);
    var grip = false;
    for (app.hits.items.items) |e| if (e.target == .button and e.target.button == @intFromEnum(render.Button.edge_grip_dock)) {
        grip = true;
    };
    try t.expect(!grip);

    // `.hidden` still hides it: no item, no pin.
    try setMode(&app, .hidden);
    try app.render();
    try t.expect(!anyDockHit(&app));
    try t.expect(app.launcher_dock.rect.isEmpty());
}

test "`.shared` with a `:` line open: the items do not move while typing — centre and end keep the no-line layout, and `.start`, whose run begins where the line does, steps aside the moment one opens" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    try setPlacement(&app, .shared);
    try app.render();
    const run_w = blk: {
        const s = itemSpan(&app, 39).?;
        break :blk s.end - s.start;
    };
    const cases = [_]struct { a: Align, bare: u16 }{
        .{ .a = .center, .bare = @max(@as(u16, 1), (117 - run_w) / 2) },
        .{ .a = .end, .bare = 117 - run_w },
    };
    for (cases) |c| {
        app.cfg.ui.dock.@"align" = c.a;
        try app.render();
        try t.expectEqual(c.bare, itemSpan(&app, 39).?.start);
        // Keystroke after keystroke, the run stays put.
        for ([_][]const u8{ "a", "ab", "abc", "abcdefgh" }) |typed| {
            try typeLine(&app, typed);
            try app.render();
            const s = itemSpan(&app, 39).?;
            try t.expectEqual(c.bare, s.start);
            try t.expectEqual(run_w, s.end - s.start);
            try t.expect(app.hits.at(118, 39).?.launcher_dock == .pin);
            // The line's own cells are the line's.
            try t.expect(app.hits.at(2, 39).?.button == @intFromEnum(render.Button.cmdline_bar));
        }
        @import("cmdline.zig").close(&app);
        try app.render();
        try t.expectEqual(c.bare, itemSpan(&app, 39).?.start);
    }
    // `.start`: the run sits at column 1, so even a bare `:▏` reaches it.
    app.cfg.ui.dock.@"align" = .start;
    try app.render();
    try t.expectEqual(@as(u16, 1), itemSpan(&app, 39).?.start);
    try typeLine(&app, "");
    try app.render();
    try t.expect(!anyDockHit(&app));
    @import("cmdline.zig").close(&app);
    try app.render();
    try t.expectEqual(@as(u16, 1), itemSpan(&app, 39).?.start);
}

test "`.shared` steps aside at the first item's column: while the line and its cell of air end before the first painted item the run holds still — one more typed cell and the strip is gone, hits and all, until the line shortens or closes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    try setPlacement(&app, .shared);
    try app.render();
    const first = itemSpan(&app, 39).?.start;
    // `:` + n typed cells + the caret cell = n + 2 painted cells, then
    // the air cell: the strip stays while (n + 2) + 1 <= first.
    const n_fit: usize = first - 3;
    var text: [120]u8 = undefined;
    @memset(&text, 'x');
    try typeLine(&app, text[0..n_fit]);
    try app.render();
    try t.expectEqual(first, itemSpan(&app, 39).?.start);
    try t.expect(app.hits.at(118, 39).?.launcher_dock == .pin);
    // The air cell is the one just before the first item — the line's.
    try t.expect(app.hits.at(first - 1, 39).?.button == @intFromEnum(render.Button.cmdline_bar));

    // One more cell and the air would land on the first item: the strip
    // steps aside whole — no item, no pin chip, no hit anywhere.
    try typeLine(&app, text[0 .. n_fit + 1]);
    try app.render();
    try t.expect(!anyDockHit(&app));
    try t.expect(app.launcher_dock.rect.isEmpty());
    // The row is the line's again, all of it.
    try t.expect(app.hits.at(118, 39).?.button == @intFromEnum(render.Button.cmdline_bar));

    // Shortened, it comes back where it was; closed, the same place.
    try typeLine(&app, text[0..n_fit]);
    try app.render();
    try t.expectEqual(first, itemSpan(&app, 39).?.start);
    try typeLine(&app, text[0 .. n_fit + 1]);
    try app.render();
    try t.expect(!anyDockHit(&app));
    @import("cmdline.zig").close(&app);
    try app.render();
    try t.expectEqual(first, itemSpan(&app, 39).?.start);
}

test "`.shared` is a bottom strip's word: a side dock ignores it (auto-hide, grip and all), and no mode ever shows the bottom grip under it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    try setPlacement(&app, .shared);
    // Every mode, bottom edge: the grip is never shown, never painted.
    for ([_]Mode{ .always, .auto_hide, .hidden }) |m| {
        app.cfg.ui.dock.mode = m;
        try app.render();
        try t.expect(!gripShown(&app));
        for (app.hits.items.items) |e| try t.expect(!(e.target == .button and e.target.button == @intFromEnum(render.Button.edge_grip_dock)));
    }
    // A side dock reads `.inner`, keeps its own auto-hide, its band and
    // its grip — and nothing of the strip lands on the `:` row.
    app.cfg.ui.dock.mode = .auto_hide;
    try setEdge(&app, .left);
    try t.expectEqual(Placement.inner, placement(&app));
    try t.expectEqual(Placement.shared, app.cfg.ui.dock.placement);
    try t.expect(!sharesCmdline(&app));
    try t.expectEqual(Mode.auto_hide, mode(&app));
    try app.render();
    try t.expect(gripShown(&app));
    try t.expect(itemSpan(&app, 39) == null);
    try t.expect(banded(&app));
}
