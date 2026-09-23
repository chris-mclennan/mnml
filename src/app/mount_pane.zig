//! `Pane.mount`: an integration hosted over a mount socket (E5). The
//! pane owns a `bridge.host.Mount` (socket + child + reader task) and a
//! UI-side copy of the sibling's grid; `handle` answers the reader's
//! events, the key / mouse / paste entry points turn what the user did
//! into `HostMessage.input`, and `draw` keeps the sibling's geometry and
//! focus in step with the rect the layout hands the pane.
//!
//! The sibling owns its keys the way a pty does: a modified chord the
//! keymap binds goes to the chord chain; everything else is forwarded.
//! Once the sibling is gone (`bye`, EOF, a spawn failure) the pane shows
//! the banner and any key closes it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const profile = @import("../config/profile.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = app_mod.Key;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const Chord = key_mod.Chord;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const host = @import("../bridge/host.zig");
const arrange = @import("arrange.zig");
const broker_app = @import("broker.zig");
const wire = @import("../bridge/wire.zig");
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const view = @import("../ui/mount_view.zig");
const vaxis = @import("vaxis");
const Theme = @import("../ui/theme.zig");
const pty_pane = @import("pty_pane.zig");
const sessions_table = @import("sessions_table.zig");
const sessions_mod = @import("../sessions.zig");
const build_options = @import("build_options");

pub const supported = host.supported;

/// One session a pane asked to be told about. `key` is the pane's own
/// name for the button that started it and goes back out untouched;
/// the three selector fields are matched the way `focus-session`
/// matches, because they are the only names a dispatched `term` line
/// can carry. `sent` is the last state the pane heard, so the host
/// speaks on the edge and stays quiet in between.
pub const Watch = struct {
    key: []u8,
    id: []u8,
    cwd: []u8,
    prompt_line: []u8,
    sent: ?wire.SessionState = null,
    /// The session the watch matched, once it has matched one. A watch
    /// sticks to its session rather than re-matching every scan: a
    /// second dispatch with the same prompt must not steal the first
    /// one's button.
    matched: []u8 = &.{},

    pub fn deinit(w: *Watch, gpa: Allocator) void {
        gpa.free(w.key);
        gpa.free(w.id);
        gpa.free(w.cwd);
        gpa.free(w.prompt_line);
        gpa.free(w.matched);
    }

    pub fn selector(w: *const Watch) sessions_table.Selector {
        return .{
            .id = if (w.id.len > 0) w.id else null,
            .cwd = if (w.cwd.len > 0) w.cwd else null,
            .prompt_line = if (w.prompt_line.len > 0) w.prompt_line else null,
        };
    }
};

/// The four states a pane is told about, from the scan's six. A
/// session with a process is running unless it stopped to ask
/// something; one without is done, or failed when its transcript ended
/// on an error.
pub fn stateOf(s: sessions_mod.AgentState) wire.SessionState {
    return switch (s) {
        .waiting => .waiting,
        .streaming, .tool_call, .idle => .running,
        .failed => .failed,
        .done => .done,
    };
}

pub const MountPane = struct {
    gpa: Allocator,
    mount: ?*host.Mount,
    /// The tab label until the sibling sets a title. Owned.
    label: []u8,
    /// The sibling's title. Owned.
    title_buf: ?[]u8 = null,
    /// The manifest id that opened it, if any. Owned.
    integration: ?[]u8 = null,
    /// // changed (integration-split): the argv this pane was spawned
    /// with, joined by spaces — what `findOpen` matches on, so a second
    /// click on the same integration command focuses THIS pane while a
    /// different command of the same integration (`--only prs-mine`
    /// beside `--only prs`) still gets one of its own. Owned; empty
    /// only for a pane a test built by hand, which matches nothing.
    cmdline: []u8 = &.{},
    /// The same argv as a list (deep link cut off) — what a session
    /// writes down so a restart brings the pane back. Owned.
    argv: []const []const u8 = &.{},
    /// The UI's copy of the sibling's screen.
    grid: host.Grid = .{},
    cursor: ?wire.Cursor = null,
    /// Why the sibling is gone; the banner text. Owned.
    exit: ?[]u8 = null,
    /// A frame has landed.
    painted: bool = false,
    /// The geometry the sibling last heard.
    cols: u16 = 0,
    rows: u16 = 0,
    focus_sent: ?bool = null,
    generation: u32,
    /// Sessions this pane started and wants told about.
    watches: std.ArrayListUnmanaged(Watch) = .empty,

    pub fn deinit(self: *MountPane, gpa: Allocator) void {
        if (self.mount) |m| {
            m.close();
            m.destroy();
        }
        for (self.watches.items) |*w| w.deinit(gpa);
        self.watches.deinit(gpa);
        self.grid.deinit(gpa);
        gpa.free(self.label);
        if (self.cmdline.len > 0) gpa.free(self.cmdline);
        for (self.argv) |a| gpa.free(a);
        if (self.argv.len > 0) gpa.free(self.argv);
        if (self.title_buf) |t| gpa.free(t);
        if (self.integration) |i| gpa.free(i);
        if (self.exit) |e| gpa.free(e);
    }

    pub fn title(self: *const MountPane) []const u8 {
        return self.title_buf orelse self.label;
    }

    pub fn alive(self: *const MountPane) bool {
        return self.exit == null and self.mount != null;
    }

    fn send(self: *MountPane, msg: wire.HostMessage) void {
        const m = self.mount orelse return;
        if (!m.connected) return;
        m.send(msg) catch {};
    }

    /// // changed (focus-row): hand the sibling the one thing a hover
    /// row named, so an already-open pane moves its cursor instead of
    /// a second copy of the same listing opening beside it. False when
    /// the child is not there to hear it — a pane still connecting has
    /// the key on its own argv already.
    pub fn focusItem(self: *MountPane, key: []const u8) bool {
        const m = self.mount orelse return false;
        if (!m.connected) return false;
        m.send(.{ .focus_item = .{ .key = key } }) catch return false;
        return true;
    }

    fn setExit(self: *MountPane, reason: []const u8) Allocator.Error!void {
        if (self.exit != null) return;
        self.exit = try std.fmt.allocPrint(self.gpa, "[{s}] — any key closes", .{reason});
    }
};

pub const OpenOptions = struct {
    argv: []const []const u8,
    /// // changed (focus-row): the argv this pane is KNOWN by, when
    /// that is not the argv it runs. A deep link (`--focus ENG-2`) is
    /// an argument to one listing, not a different listing, so the
    /// identity leaves it out: the second row of the same hover then
    /// finds the pane the first one opened. Empty means `argv` itself.
    identity: []const []const u8 = &.{},
    /// The one thing the pane should land on — forwarded down the
    /// mount when `identity` is already open, rather than opening a
    /// second one. Empty asks for nothing.
    focus: []const u8 = "",
    /// The tab label; argv[0]'s basename when null.
    label: ?[]const u8 = null,
    /// The manifest that opened it.
    integration: ?[]const u8 = null,
    /// Absolute; the workspace when null.
    cwd: ?[]const u8 = null,
    /// `MNML_SETTING_<KEY>` and friends.
    extra_env: []const EnvPair = &.{},
};

pub const EnvPair = struct { name: []const u8, value: []const u8 };

var next_id: u32 = 0;

/// Where the file-IPC channel is for this app: `MNML_IPC_DIR`, else
/// `<workspace>/.mnml/<the profile's mailbox>`. On the frame arena.
pub fn ipcDir(app: *App) Allocator.Error![]const u8 {
    if (app.env.get("MNML_IPC_DIR")) |d| if (d.len > 0) return d;
    return std.fs.path.join(app.frame.allocator(), &.{ app.workspace, ".mnml", profile.ipcSubdir(app.profile()) });
}

/// `ipcDir`, made to exist: it is the directory an integration is told
/// (`MNML_IPC_DIR`) to append its Tier-2 lines to — the statusline
/// chip, a toast, a `term` dispatch — and it is only worth telling if
/// it is there. It used to come into being only as the parent of the
/// mount's socket, `<ipc_dir>/mounts/<pid>-<id>.sock`; a workspace too
/// deep for a `sockaddr_un` puts the socket under `/tmp` instead, so on
/// a deep workspace the channel never existed and every integration's
/// chip, toast and dispatch went nowhere. (The corpus met it the day
/// its `TMPDIR` was a checkout's `.verify/tmp`.)
pub fn preparedIpcDir(app: *App) Allocator.Error![]const u8 {
    const dir = try ipcDir(app);
    Io.Dir.cwd().createDirPath(app.io, dir) catch {};
    return dir;
}

/// The live mount pane spawned from exactly this command line, if
/// there is one.
/// // changed (integration-split): clicking a chip a second time is
/// "show me that", never "start another one" — the muscle memory of
/// every other rail row, and what Rust does before it spawns anything
/// (`open_mount_from_manifest`, which matches on the label). The match
/// here is the whole argv rather than the label, because a manifest's
/// commands share a label and differ only in their args: `--only prs`
/// and `--only prs-mine` are two different things to look at.
pub fn findOpen(app: *App, cmdline: []const u8) ?PaneId {
    if (cmdline.len == 0) return null;
    for (app.panes.slots.items, 0..) |*slot, i| {
        const p = &(slot.* orelse continue);
        const m = p.asMount() orelse continue;
        // A pane showing its exit banner is not a pane to go back to;
        // one whose child is still connecting is.
        if (m.exit != null) continue;
        if (std.mem.eql(u8, m.cmdline, cmdline)) return @intCast(i);
    }
    return null;
}

/// `argv` as one string, for `findOpen`.
fn joinArgv(alloc: Allocator, argv: []const []const u8) Allocator.Error![]u8 {
    return std.mem.join(alloc, " ", argv);
}

/// Spawn `argv` as a mount and show it.
///
/// // changed (integration-split): `integrations.open_as` decides where
/// it lands. `.split` — the default, and what the Rust editor always
/// does (`open_mount_with_args` → `split_leaf_with(active,
/// SplitDir::Horizontal, …)`, which is SIDE BY SIDE: the Rust
/// `SplitDir` names its divider, not its arrangement) — puts it beside
/// the active pane, and with `integrations.equalize_on_open` the splits
/// even out afterwards, so clicking two integrations gives two equal
/// columns rather than a sliver. `.tab` keeps the old behaviour.
pub fn open(app: *App, opts: OpenOptions) CommandError!PaneId {
    if (!supported) return app.diag.fail(app.frame.allocator(), "mount: no Unix sockets on this platform", .{});
    if (opts.argv.len == 0) return app.diag.fail(app.frame.allocator(), "mount: nothing to run", .{});
    // Already running: show that one instead of spawning a second.
    const identity = if (opts.identity.len > 0) opts.identity else opts.argv;
    const key = try joinArgv(app.frame.allocator(), identity);
    if (findOpen(app, key)) |existing| {
        // // changed (focus-row): and if the press named one thing,
        // the pane that is already up moves its cursor onto it.
        if (opts.focus.len > 0) if (app.panes.get(existing)) |p| if (p.asMount()) |mp| {
            _ = mp.focusItem(opts.focus);
        };
        app.showPane(existing);
        app.focus = .{ .pane = existing };
        app.needs_render = true;
        return existing;
    }
    const gpa = app.gpa;
    const label = try gpa.dupe(u8, opts.label orelse std.fs.path.basename(opts.argv[0]));
    errdefer gpa.free(label);
    const integration: ?[]u8 = if (opts.integration) |i| try gpa.dupe(u8, i) else null;
    errdefer if (integration) |i| gpa.free(i);
    const cmdline = try joinArgv(gpa, identity);
    errdefer gpa.free(cmdline);
    const kept = try gpa.alloc([]const u8, identity.len);
    var n_kept: usize = 0;
    errdefer {
        for (kept[0..n_kept]) |x| gpa.free(x);
        gpa.free(kept);
    }
    for (identity) |x| {
        kept[n_kept] = try gpa.dupe(u8, x);
        n_kept += 1;
    }

    next_id += 1;
    const id = app.panes.peekId();
    const ipc_dir = try preparedIpcDir(app);
    const sock = try host.socketPath(gpa, ipc_dir, next_id);
    defer gpa.free(sock);
    var env = try host.envFor(gpa, &app.env, .{
        .socket_path = sock,
        .workspace = app.workspace,
        .theme = app.theme.name,
        .ipc_dir = ipc_dir,
        .data_root = app.data_root,
        .request_log = .{ .enabled = app.cfg.integrations.request_log.enabled, .max_mb = app.cfg.integrations.request_log.max_mb },
    });
    defer env.deinit();
    // Where the API brokers are, and whether to look for one at all
    // (`app/broker.zig`). Not part of `envFor` because it is the App's
    // to answer, not the bridge's.
    try broker_app.putEnv(app, &env);
    for (opts.extra_env) |pair| try env.put(pair.name, pair.value);

    const mount = host.Mount.spawn(gpa, app.io, app.events, .{
        .argv = opts.argv,
        .cwd = opts.cwd orelse app.workspace,
        .env = &env,
        .socket_path = sock,
        .pane = id,
        .generation = next_id,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SpawnFailed => return app.diag.fail(app.frame.allocator(), "mount: cannot run {s}", .{opts.argv[0]}),
        error.BindFailed => return app.diag.fail(app.frame.allocator(), "mount: cannot bind {s}", .{sock}),
        error.ListenFailed => return app.diag.fail(app.frame.allocator(), "mount: cannot start the reader", .{}),
        error.Unsupported => return app.diag.fail(app.frame.allocator(), "mount: no Unix sockets on this platform", .{}),
    };
    errdefer {
        mount.close();
        mount.destroy();
    }
    const got = try app.panes.add(.{ .mount = .{
        .gpa = gpa,
        .mount = mount,
        .label = label,
        .integration = integration,
        .cmdline = cmdline,
        .argv = kept,
        .generation = next_id,
    } });
    std.debug.assert(got == id);
    place(app, id);
    app.needs_render = true;
    return id;
}

/// Where a fresh mount pane lands (see `open`'s header).
fn place(app: *App, id: PaneId) void {
    if (app.cfg.integrations.open_as == .tab) return app.showPane(id);
    // `integrations.arrange` sizes it — the one rule every new pane
    // goes through (`app/arrange.zig`). No room for another split: a
    // tab is better than nothing.
    const leaf = arrange.splitActive(app, id, .{
        .dir = .horizontal,
        .fixed_equalize = app.cfg.integrations.equalize_on_open,
    }) catch blk: {
        app.showPane(id);
        break :blk null;
    };
    // A pane that took a leaf of its own takes the keys with it; one
    // that joined a strip leaves the focus where it was.
    if (leaf != null) app.focus = .{ .pane = id };
}

/// `mount.open`: the binary (and args) typed into a prompt.
fn openCmd(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "Mount integration (binary and args)"), .purpose = .mount_open } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn acceptPrompt(app: *App, text: []const u8) CommandError!void {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t");
    while (it.next()) |tok| try argv.append(app.frame.allocator(), tok);
    if (argv.items.len == 0) return app.diag.fail(app.frame.allocator(), "mount: nothing to run", .{});
    _ = try open(app, .{ .argv = argv.items });
}

pub const table = .{
    .@"mount.open" = &openCmd,
};

// ─── events ─────────────────────────────────────────────────────────────

fn paneOf(app: *App, ev: *const host.Event) ?*MountPane {
    const p = app.panes.get(ev.pane) orelse return null;
    const mp = p.asMount() orelse return null;
    if (mp.generation != ev.generation) return null;
    return mp;
}

/// What the reader posted. The event is destroyed here on every path.
pub fn handle(app: *App, ev: *host.Event) Allocator.Error!void {
    defer ev.destroy(app.gpa);
    const p = paneOf(app, ev) orelse return;
    const gpa = app.gpa;
    switch (ev.kind) {
        .connected => {
            const m = p.mount orelse return;
            m.onConnected();
            const geometry = currentGeometry(app, ev.pane, p);
            p.cols = geometry.cols;
            p.rows = geometry.rows;
            p.send(.{
                .hello = .{
                    .geometry = geometry,
                    .theme = app.theme.name,
                    .workspace = app.workspace,
                    .capabilities = .{ .rgb = true, .nerd_font = !app.cfg.ui.ascii_icons, .ascii = app.cfg.ui.ascii_icons },
                    .palette = paletteOf(&app.theme),
                    // The pane's tab strip marks its active tab the way the
                    // rest of mnml does, rather than picking for itself.
                    .tab_indicator = switch (app.cfg.ui.tab_indicator) {
                        .block => .block,
                        .rule => .rule,
                        .line => .line,
                        .quarter => .quarter,
                        .quarter_track => .quarter_track,
                    },
                },
            });
            m.greeted = true;
            const focused = app.active == ev.pane and app.focus == .pane;
            p.send(.{ .focus = focused });
            p.focus_sent = focused;
        },
        .frame => {
            const m = p.mount orelse return;
            try m.takeGrid(gpa, &p.grid);
            p.painted = true;
        },
        .title => |t| {
            const copy = try gpa.dupe(u8, t);
            if (p.title_buf) |old| gpa.free(old);
            p.title_buf = copy;
        },
        .cursor => |c| p.cursor = c,
        .command => |id| {
            command.runNamed(app, id) catch {};
        },
        .toast => |t| {
            const level: app_mod.ToastLevel = switch (t.level) {
                .info => .info,
                .warn => .warn,
                .@"error" => .err,
            };
            // An offer, when the pane sent one and it is one the host
            // can act on: a label and EITHER a command id or a page,
            // never both and never neither (`wire.ToastAction`). A
            // message that reports a merge and then vanishes leaves
            // the reader with no door to the thing it merged.
            if (t.action) |a| {
                const owned: app_mod.ToastAction = if (a.isCommand()) .{ .command = .{
                    .label = try app.gpa.dupe(u8, a.label),
                    .id = try app.gpa.dupe(u8, a.command),
                    .pane = ev.pane,
                } } else .{ .open_url = .{
                    .label = try app.gpa.dupe(u8, a.label),
                    .url = try app.gpa.dupe(u8, a.url),
                } };
                return app.toastWithAction(level, owned, "{s}: {s}", .{ p.title(), t.text });
            }
            try app.toastLevel(level, "{s}: {s}", .{ p.title(), t.text });
        },
        .watch_session => |req| {
            // The event's four strings become the watch's, or are
            // freed here — `Event.destroy` frees them either way, so
            // they are copied rather than adopted.
            try addWatch(app, p, req.key, req.id, req.cwd, req.prompt_line);
            // Answer at once with what the scan already knows, so a
            // button does not sit on the press's own guess until the
            // next cadence comes round.
            notifyOne(app, p, &p.watches.items[p.watches.items.len - 1]);
        },
        .bye => try p.setExit("exited"),
        .closed => |reason| try p.setExit(reason),
    }
    app.needs_render = true;
}

/// Take (or replace) a watch under `key`. A second press on the same
/// button follows the newer session rather than doubling the list.
fn addWatch(app: *App, p: *MountPane, key: []const u8, id: []const u8, cwd: []const u8, prompt_line: []const u8) Allocator.Error!void {
    const gpa = app.gpa;
    for (p.watches.items, 0..) |*w, i| {
        if (!std.mem.eql(u8, w.key, key)) continue;
        w.deinit(gpa);
        _ = p.watches.orderedRemove(i);
        break;
    }
    const k = try gpa.dupe(u8, key);
    errdefer gpa.free(k);
    const sid = try gpa.dupe(u8, id);
    errdefer gpa.free(sid);
    const c = try gpa.dupe(u8, cwd);
    errdefer gpa.free(c);
    const l = try gpa.dupe(u8, prompt_line);
    errdefer gpa.free(l);
    try p.watches.append(gpa, .{ .key = k, .id = sid, .cwd = c, .prompt_line = l });
}

/// The session one watch is about: the one it already matched, else
/// the newest the selector picks out. Several sessions can share a cwd
/// and a prompt line; the newest is the one the press just started.
fn sessionFor(app: *App, w: *const Watch) ?sessions_mod.Item {
    if (w.matched.len > 0) {
        for (app.sessions.items) |it| if (std.mem.eql(u8, it.session_id, w.matched)) return it;
        // The session left the listing (older than the scan's window):
        // nothing more to say about it.
        return null;
    }
    const sel = w.selector();
    var best: ?sessions_mod.Item = null;
    for (app.sessions.items) |it| {
        if (!sel.matches(it)) continue;
        if (best) |b| if (b.last_activity_s >= it.last_activity_s) continue;
        best = it;
    }
    return best;
}

/// Send one watch's state if it moved. Silent when nothing matched yet
/// — a dispatch whose session has not appeared in a scan is simply not
/// news.
fn notifyOne(app: *App, p: *MountPane, w: *Watch) void {
    const it = sessionFor(app, w) orelse return;
    if (w.matched.len == 0) {
        w.matched = app.gpa.dupe(u8, it.session_id) catch return;
    }
    const state = stateOf(it.state);
    if (w.sent) |had| if (had == state) return;
    w.sent = state;
    p.send(.{
        .session_state = .{
            .key = w.key,
            .state = state,
            .session_id = it.session_id,
            // The session's last word: on a failure it is the reason, on a
            // pause it is the question.
            .detail = firstLine(it.last_assistant_msg orelse ""),
        },
    });
}

/// The first line of a message, clipped — a pane puts it on one row.
pub fn firstLine(s: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    return s[0..@min(end, 200)];
}

/// `integrations.retry_refresh` — what an integration's failed-refresh
/// toast offers. The pane the toast came from is focused first (the
/// offer carries its id), so this always lands on the pane that
/// failed rather than on whichever one happens to be in front.
///
/// `r` is the refresh key every pane in the family binds, which is why
/// the host can retry without knowing anything about the integration.
pub fn retryRefresh(app: *App) CommandError!void {
    const id = app.active orelse return;
    const pane = app.panes.get(id) orelse return;
    const mp = pane.asMount() orelse {
        app.toast("retry: the focused pane is not an integration", .{});
        return;
    };
    if (!mp.alive()) {
        app.toast("retry: {s} is no longer running", .{mp.title()});
        return;
    }
    mp.send(.{ .input = .{ .event = .{ .key = .{ .spec = "r" } } } });
}

/// After a sessions snapshot: every mount pane hears about every watch
/// of its own that moved. Called from `sessions.handle`.
pub fn notifySessionWatches(app: *App) void {
    for (app.panes.slots.items) |*slot| if (slot.*) |*pane| switch (pane.*) {
        .mount => |*mp| {
            // A pane whose sibling has gone hears nothing more; one
            // that never connected simply drops the send.
            if (mp.exit != null) continue;
            for (mp.watches.items) |*w| notifyOne(app, mp, w);
        },
        else => {},
    };
}

/// The pane's body size as the last frame laid it out — or the app's
/// pane size before the first frame.
fn currentGeometry(app: *App, id: PaneId, p: *MountPane) wire.Geometry {
    if (p.cols > 0 and p.rows > 0) return .{ .cols = p.cols, .rows = p.rows };
    _ = id;
    return .{ .cols = @intCast(@max(app.pane_cols, 1)), .rows = @intCast(@max(app.pane_rows, 1)) };
}

// ─── input ──────────────────────────────────────────────────────────────

/// Keys: chords the app binds go to the chain; the rest to the sibling.
/// After exit, any key closes the pane. Returns true when handled.
pub fn handleKey(app: *App, id: PaneId, p: *MountPane, k: Key) Allocator.Error!bool {
    if (app.chord.len > 0) return false;
    const modified = k.mods.ctrl or k.mods.alt or k.mods.super;
    if (!p.alive()) {
        if (modified) return false;
        try app.forceClosePane(id);
        return true;
    }
    if (modified and !pty_pane.childOwned(k)) {
        if (app.keymap.resolveSeq(&.{Chord.of(k)}) != .none) return false;
    }
    const spec = try std.fmt.allocPrint(app.frame.allocator(), "{f}", .{Chord.of(k)});
    p.send(.{ .input = .{ .event = .{ .key = .{ .spec = spec } } } });
    return true;
}

pub fn paste(app: *App, p: *MountPane, text: []const u8) void {
    _ = app;
    if (!p.alive()) return;
    p.send(.{ .input = .{ .event = .{ .paste = .{ .text = text } } } });
}

/// A press on row `row` of the pane; `rect` is the row's hit rect so
/// the column is pane-relative.
pub fn click(app: *App, id: PaneId, p: *MountPane, row: u32, m: Mouse, rect: ?Rect) Allocator.Error!void {
    if (!p.alive()) {
        try app.forceClosePane(id);
        return;
    }
    const col: u16 = if (rect) |r| m.x -| r.x else m.x;
    const button: wire.Button = switch (m.button) {
        .left, .none => .left,
        .right => .right,
        .middle => .middle,
    };
    p.send(.{ .input = .{ .event = .{ .click = .{ .col = col, .row = @intCast(@min(row, std.math.maxInt(u16))), .button = button } } } });
}

/// A wheel notch over the pane.
pub fn wheel(p: *MountPane, row: u32, m: Mouse, rect: ?Rect, count: u16) void {
    if (!p.alive()) return;
    const col: u16 = if (rect) |r| m.x -| r.x else m.x;
    const n: i16 = @intCast(@min(@max(count, 1), 100));
    p.send(.{ .input = .{ .event = .{ .scroll = .{ .col = col, .row = @intCast(@min(row, std.math.maxInt(u16))), .dy = if (m.kind == .scroll_up) n else -n } } } });
}

/// The pointer over the pane. A motion with a button held is a drag —
/// the sibling hears the same event with `dragging` set, which is what
/// lets it track a scrollbar the user is pulling.
pub fn hover(p: *MountPane, row: u32, m: Mouse, rect: ?Rect) void {
    if (!p.alive()) return;
    const col: u16 = if (rect) |r| m.x -| r.x else m.x;
    p.send(.{ .input = .{ .event = .{ .hover = .{ .col = col, .row = @intCast(@min(row, std.math.maxInt(u16))), .dragging = m.kind == .drag } } } });
}

// ─── frame ──────────────────────────────────────────────────────────────

/// The theme's roles as wire colours, for `hello.palette`: a sibling
/// paints in the theme it is mounted in instead of the terminal's
/// palette. A role the theme leaves to the terminal goes out as null.
pub fn paletteOf(t: *const Theme) wire.Palette {
    return .{
        .fg = wireColor(t.fg.fg),
        .bg = wireColor(t.bg.bg),
        .muted = wireColor(t.muted.fg),
        .accent = wireColor(t.accent.fg),
        .border = wireColor(t.border.fg),
        .panel_bg = wireColor(t.panel_bg.bg),
        .cursor_line = wireColor(t.cursor_line.bg),
        .chip_fg = wireColor(t.chip.fg),
        .chip_bg = wireColor(t.chip.bg),
        .chip_active_fg = wireColor(t.chip_active.fg),
        .chip_active_bg = wireColor(t.chip_active.bg),
        .red = wireColor(t.palette.red),
        .green = wireColor(t.palette.green),
        .yellow = wireColor(t.palette.yellow),
        .orange = wireColor(t.palette.orange),
        .blue = wireColor(t.palette.blue),
        .cyan = wireColor(t.palette.cyan),
        .purple = wireColor(t.palette.purple),
        .comment = wireColor(t.palette.comment),
    };
}

fn wireColor(c: vaxis.Color) ?wire.Color {
    return switch (c) {
        .default => null,
        .index => |i| .{ .index = i },
        .rgb => |v| .{ .rgb = v },
    };
}

pub fn draw(app: *App, ui: Ui, id: PaneId, p: *MountPane, rect: Rect) Allocator.Error!void {
    const focused = app.active == id and app.focus == .pane;
    if (app.active == id) {
        app.pane_rows = @max(rect.h, 1);
        app.pane_cols = @max(rect.w, 1);
    }
    if (rect.w > 0 and rect.h > 0 and (rect.w != p.cols or rect.h != p.rows)) {
        p.cols = rect.w;
        p.rows = rect.h;
        if (p.mount) |m| if (m.greeted) p.send(.{ .resize = .{ .geometry = .{ .cols = rect.w, .rows = rect.h } } });
    }
    if (p.mount) |m| if (m.greeted and p.focus_sent != focused) {
        p.send(.{ .focus = focused });
        p.focus_sent = focused;
    };
    const cursor = view.draw(ui, id, rect, &p.grid, .{
        .focused = focused,
        .waiting = !p.painted,
        .exit_label = p.exit,
        .cursor = p.cursor,
    });
    if (focused) if (cursor) |c| {
        app.cursor_pos = .{ .x = c.x, .y = c.y };
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Poll `tick` until `pred` holds or `ms` elapse.
fn waitFor(app: *App, ms: u32, ctx: anytype, comptime pred: fn (@TypeOf(ctx)) bool) !void {
    var waited: u32 = 0;
    while (waited <= ms) : (waited += 10) {
        try app.tick(App.nowMs(app.io));
        if (pred(ctx)) return;
        app.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return error.TimedOut;
}

fn screenText(app: *App) ![]u8 {
    try app.render();
    return @import("../ipc/screen.zig").toTestText(testing.allocator, &app.screen);
}

test "a mounted sample integration paints, answers keys and clicks, and leaves on q" {
    if (!supported) return error.SkipZigTest;
    const exe = build_options.sdk_example_exe;
    Io.Dir.cwd().access(testing.io, exe, .{}) catch return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = ws, .cols = 100, .rows = 14, .env = &env });
    defer app.deinit();
    app.tree.visible = false;
    // The command the sample fires on Enter / a click on the selected row.
    _ = try app.dyn_commands.register(.{ .id = "hello.pick", .runner = .ipc, .owner = .ipc });

    const id = try open(&app, .{ .argv = &.{exe}, .label = "hello" });
    const p = app.panes.get(id).?.asMount().?;
    const Ctx = struct {
        fn painted(mp: *MountPane) bool {
            return mp.painted;
        }
        fn exited(mp: *MountPane) bool {
            return mp.exit != null;
        }
    };
    try waitFor(&app, 15_000, p, Ctx.painted);
    var txt = try screenText(&app);
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "HELLO") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "▸ Alpha") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Epsilon") != null);
    try testing.expectEqualStrings("hello", app.panes.get(id).?.title());

    // A key: the selection moves.
    try testing.expect(try handleKey(&app, id, p, .{ .code = .down }));
    const Poll = struct {
        app: *App,
        needle: []const u8,
        fn has(self: @This()) bool {
            self.app.render() catch return false;
            const t = @import("../ipc/screen.zig").toTestText(testing.allocator, &self.app.screen) catch return false;
            defer testing.allocator.free(t);
            return std.mem.indexOf(u8, t, self.needle) != null;
        }
    };
    try waitFor(&app, 15_000, Poll{ .app = &app, .needle = "▸ Beta" }, Poll.has);

    // A click on the selected row fires the command; the count shows.
    // The sample paints its rows from `first_row`; the hit for that row
    // says where the pane put it on screen.
    const beta_row: u32 = 2 + 1;
    var rect: ?Rect = null;
    for (app.hits.items.items) |e| switch (e.target) {
        .script_hit => |sh| if (sh.pane == id and sh.id == beta_row) {
            rect = e.rect;
        },
        else => {},
    };
    try testing.expect(rect != null);
    try click(&app, id, p, beta_row, .{ .x = rect.?.x + 3, .y = rect.?.y, .kind = .press, .button = .left }, rect);
    const Picked = struct {
        fn has(a: *App) bool {
            return a.plugin_invocations.items.len > 0;
        }
    };
    try waitFor(&app, 15_000, &app, Picked.has);
    try testing.expectEqualStrings("hello.pick", app.plugin_invocations.items[0]);
    try waitFor(&app, 15_000, Poll{ .app = &app, .needle = "picks: 1" }, Poll.has);

    // q: bye → the banner; any key then closes the pane.
    try testing.expect(try handleKey(&app, id, p, .{ .code = .{ .char = 'q' } }));
    try waitFor(&app, 15_000, p, Ctx.exited);
    testing.allocator.free(txt);
    txt = try screenText(&app);
    try testing.expect(std.mem.indexOf(u8, txt, "[exited] — any key closes") != null);
    try testing.expect(try handleKey(&app, id, p, .{ .code = .{ .char = 'x' } }));
    try testing.expect(app.panes.get(id) == null);
}

/// A mount pane with no socket behind it: `send` drops on the floor,
/// which is all this test needs — what is asserted is the edge logic,
/// not the bytes.
fn paneOnly(app: *App, label: []const u8) Allocator.Error!*MountPane {
    const id = try app.panes.add(.{ .mount = .{
        .gpa = app.gpa,
        .mount = null,
        .label = try app.gpa.dupe(u8, label),
        .generation = 0,
    } });
    return app.panes.get(id).?.asMount().?;
}

fn seedSessions(app: *App, items: []const sessions_mod.Item) !void {
    const r = try sessions_mod.ScanResult.create(testing.allocator, app.sessions.generation);
    const a = r.arena.allocator();
    const rows = try a.alloc(sessions_mod.Item, items.len);
    for (items, 0..) |it, i| rows[i] = try sessions_mod.dupeItem(a, it);
    r.items = rows;
    r.at_s = @divFloor(app.now_ms, 1000);
    try sessions_mod.handle(app, r);
    app.sessions.scanned_once = true;
}

fn fakeSession(id: []const u8, state: sessions_mod.AgentState, cwd: []const u8, user: []const u8, said: ?[]const u8) sessions_mod.Item {
    return fakeSessionAt(id, state, 100, cwd, user, said);
}

fn fakeSessionAt(id: []const u8, state: sessions_mod.AgentState, at: i64, cwd: []const u8, user: []const u8, said: ?[]const u8) sessions_mod.Item {
    var it = sessions_mod.testItem(id, state, at, "ws", user);
    it.cwd = cwd;
    it.last_assistant_msg = said;
    return it;
}

test "a pane that watches a session it started is told when it runs, when it stops to ask, and when it ends" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/w/acme", .cols = 100, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    const p = try paneOnly(&app, "jira");

    // The pane names the button; the two names a dispatched `term`
    // line can carry are how the host finds the session.
    try addWatch(&app, p, "ENG-2\x1ftriage", "", "/w/acme", "/agents:developer ENG-2");
    const w = &p.watches.items[0];
    // Nothing has been scanned: nothing to say yet.
    notifySessionWatches(&app);
    try testing.expect(w.sent == null);

    try seedSessions(&app, &.{
        fakeSession("sid-1", .streaming, "/w/acme", "/agents:developer ENG-2 — go", null),
        // A session in the same directory with a different prompt is
        // not this button's.
        fakeSession("sid-other", .waiting, "/w/acme", "/agents:reviewer PR-9", "?"),
    });
    try testing.expectEqual(wire.SessionState.running, p.watches.items[0].sent.?);
    try testing.expectEqualStrings("sid-1", p.watches.items[0].matched);

    // The edge only: a second snapshot in the same state says nothing
    // new, and `sent` stays where it was.
    try seedSessions(&app, &.{fakeSession("sid-1", .tool_call, "/w/acme", "/agents:developer ENG-2 — go", null)});
    try testing.expectEqual(wire.SessionState.running, p.watches.items[0].sent.?);

    // It stops to ask something, then ends.
    try seedSessions(&app, &.{fakeSession("sid-1", .waiting, "/w/acme", "/agents:developer ENG-2 — go", "Shall I run the migration?\nmore")});
    try testing.expectEqual(wire.SessionState.waiting, p.watches.items[0].sent.?);
    try seedSessions(&app, &.{fakeSession("sid-1", .done, "/w/acme", "/agents:developer ENG-2 — go", "done")});
    try testing.expectEqual(wire.SessionState.done, p.watches.items[0].sent.?);

    // Once matched, the watch sticks to ITS session: a newer one
    // started later with the same prompt does not steal the button.
    try seedSessions(&app, &.{
        fakeSession("sid-1", .done, "/w/acme", "/agents:developer ENG-2 — go", "done"),
        // Newer, so the selector on its own would pick it: what keeps
        // the button on sid-1 is that the watch already matched.
        fakeSessionAt("sid-2", .streaming, 900, "/w/acme", "/agents:developer ENG-2 — go again", null),
    });
    try testing.expectEqualStrings("sid-1", p.watches.items[0].matched);
    try testing.expectEqual(wire.SessionState.done, p.watches.items[0].sent.?);

    // A second watch under the same key replaces the first — a button
    // pressed twice follows the newer session, and the list does not
    // grow.
    try addWatch(&app, p, "ENG-2\x1ftriage", "", "/w/acme", "/agents:developer ENG-2 — go again");
    try testing.expectEqual(@as(usize, 1), p.watches.items.len);
    try testing.expect(p.watches.items[0].sent == null);
    notifySessionWatches(&app);
    try testing.expectEqualStrings("sid-2", p.watches.items[0].matched);
    try testing.expectEqual(wire.SessionState.running, p.watches.items[0].sent.?);
}

test "the six states the scan derives become the four a button can wear; a line is its first line, clipped" {
    try testing.expectEqual(wire.SessionState.waiting, stateOf(.waiting));
    try testing.expectEqual(wire.SessionState.running, stateOf(.streaming));
    try testing.expectEqual(wire.SessionState.running, stateOf(.tool_call));
    try testing.expectEqual(wire.SessionState.running, stateOf(.idle));
    try testing.expectEqual(wire.SessionState.done, stateOf(.done));
    try testing.expectEqual(wire.SessionState.failed, stateOf(.failed));
    try testing.expectEqualStrings("first", firstLine("first\nsecond\nthird"));
    try testing.expectEqualStrings("", firstLine(""));
    try testing.expectEqual(@as(usize, 200), firstLine("x" ** 400).len);
}

test "a binary that does not exist fails at open with a diag, not a pane" {
    if (!supported) return error.SkipZigTest;
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 40, .rows = 8 });
    defer app.deinit();
    try testing.expectError(error.Failed, open(&app, .{ .argv = &.{"/nonexistent/mnml-nope"} }));
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "cannot run") != null);
    try testing.expectEqual(@as(usize, 0), app.panes.count());
}

/// A pane that exists but is in no leaf, with the active pane left
/// where it was — the state `open` hands to `place` (the mount is added
/// to `App.panes` and shown only by `place` itself).
fn unplacedPane(app: *App) !PaneId {
    const keep = app.active;
    const id = try app.openScratch();
    _ = app.layouts.current().removePane(id);
    app.setActive(keep);
    return id;
}

test "integrations.open_as: a mount lands beside the active pane and the splits even out; .tab keeps it in the leaf" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    const first = try app.openScratch();
    const layout = app.layouts.current();
    const home = layout.leafOf(first).?;

    // The shipped default is the Rust behaviour: side by side.
    try testing.expectEqual(@import("../config/Config.zig").IntegrationOpenAs.split, app.cfg.integrations.open_as);
    const second = try unplacedPane(&app);
    place(&app, second);
    const second_leaf = layout.leafOf(second).?;
    try testing.expect(second_leaf != home);
    try testing.expectEqual(second, app.active.?);
    // Side by side, not stacked — Rust's `SplitDir::Horizontal`, whose
    // name is its divider's.
    const pair = layout.findLeafPairSplit(first, second).?;
    try testing.expectEqual(@import("layout.zig").SplitDir.horizontal, pair.dir);

    // `equalize_on_open` evens them out even with `ui.auto_equalize_splits`
    // off, which is the "they auto adjust" the ask named.
    try testing.expect(!app.cfg.ui.auto_equalize_splits);
    const third = try unplacedPane(&app);
    place(&app, third);
    const rects = try layout.computeRects(Rect.init(0, 0, 120, 40), app.frame.allocator());
    try testing.expectEqual(@as(usize, 3), rects.panes.len);
    // Three equal columns, give or take the rounding a 120-cell row and
    // its two dividers cannot divide evenly.
    for (rects.panes) |pr| try testing.expect(pr.rect.w >= 38 and pr.rect.w <= 40);

    // `.tab`: the pane joins the active leaf instead.
    app.cfg.integrations.open_as = .tab;
    const fourth = try unplacedPane(&app);
    const before = layout.leafOf(app.active.?).?;
    place(&app, fourth);
    try testing.expectEqual(before, layout.leafOf(fourth).?);
}

test "findOpen matches the whole command line: the same integration command focuses its pane, a different one gets its own" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    const gpa = testing.allocator;
    const id = try app.panes.add(.{ .mount = .{
        .gpa = gpa,
        .mount = null,
        .label = try gpa.dupe(u8, "Bitbucket PRs"),
        .integration = try gpa.dupe(u8, "bitbucket_prs"),
        .cmdline = try gpa.dupe(u8, "bb --only prs"),
        .generation = 1,
    } });
    try testing.expectEqual(id, findOpen(&app, "bb --only prs").?);
    // The manifest's OTHER command shares the label and the id; it is a
    // different thing to look at, so it is not this pane.
    try testing.expect(findOpen(&app, "bb --only prs-mine") == null);
    // A pane built by hand with no command line matches nothing.
    try testing.expect(findOpen(&app, "") == null);
    // A dead pane is not a pane to go back to.
    app.panes.get(id).?.asMount().?.exit = try gpa.dupe(u8, "gone");
    try testing.expect(findOpen(&app, "bb --only prs") == null);
}

test "a deep link reaches the pane that is already open rather than a second one, and only for the same command" {
    if (!supported) return error.SkipZigTest;
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    const gpa = testing.allocator;
    const id = try app.panes.add(.{ .mount = .{
        .gpa = gpa,
        .mount = null,
        .label = try gpa.dupe(u8, "Bitbucket PRs"),
        .integration = try gpa.dupe(u8, "bitbucket_prs"),
        .cmdline = try gpa.dupe(u8, "bb --only prs"),
        .generation = 1,
    } });
    const before = app.panes.slots.items.len;
    // The hover row's press: the same command, plus which pull request.
    // `identity` is what the pane is KNOWN by, so the deep link does
    // not make it a different thing to look at — nothing is spawned
    // (the binary `bb` does not exist, so a spawn would fail loudly).
    try testing.expectEqual(id, try open(&app, .{
        .argv = &.{ "bb", "--only", "prs", "--focus", "api#1198" },
        .identity = &.{ "bb", "--only", "prs" },
        .focus = "api#1198",
    }));
    try testing.expectEqual(before, app.panes.slots.items.len);
    // A pane with no child cannot be told; the press still raises it.
    try testing.expect(!app.panes.get(id).?.asMount().?.focusItem("api#1198"));
    // And the manifest's OTHER command is still its own pane: a deep
    // link narrows a listing, it does not widen one.
    try testing.expect(findOpen(&app, "bb --only prs-mine") == null);
}

test "an integration inherits the profile's data root, so its caches and sync marks land under the dev root" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("MNML_PROFILE", "dev");
    var app = try App.initWith(testing.allocator, testing.io, .{
        .workspace = "/ws",
        // What `main` resolved for this profile (`config/data_root.zig`).
        .data_root = "/home/x/.config/mnml-dev",
        .cols = 40,
        .rows = 8,
        .env = &env,
    });
    defer app.deinit();
    try testing.expectEqual(profile.Profile.dev, app.profile());

    // The env a mount is spawned with — the same call `open` makes.
    var child = try host.envFor(testing.allocator, &app.env, .{
        .socket_path = "/s.sock",
        .workspace = app.workspace,
        .theme = app.theme.name,
        .ipc_dir = try ipcDir(&app),
        .data_root = app.data_root,
    });
    defer child.deinit();
    // The integration writes its config, cache, sync marks, etags and
    // request log under this — so the dev profile's Jira cache is not
    // the installed mnml's, without the integration knowing profiles
    // exist at all.
    try testing.expectEqualStrings("/home/x/.config/mnml-dev", child.get("MNML_DATA_ROOT").?);
    try testing.expectEqualStrings("dev", child.get("MNML_PROFILE").?);
}

test "the IPC channel an integration is told about exists even when the workspace is too deep for its socket" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = rbuf[0..try tmp.dir.realPath(testing.io, &rbuf)];
    var deep: std.ArrayListUnmanaged(u8) = .empty;
    defer deep.deinit(testing.allocator);
    try deep.appendSlice(testing.allocator, root);
    while (deep.items.len < 110) try deep.appendSlice(testing.allocator, "/deep");
    try Io.Dir.cwd().createDirPath(testing.io, deep.items);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = deep.items, .data_root = deep.items, .cols = 80, .rows = 24 });
    defer app.deinit();
    _ = app.env.swapRemove("MNML_IPC_DIR");
    const dir = try preparedIpcDir(&app);
    // The socket leaves the workspace for `/tmp`…
    const sock = try host.socketPath(testing.allocator, dir, 1);
    defer testing.allocator.free(sock);
    try testing.expect(std.mem.startsWith(u8, sock, "/tmp/"));
    // …and the channel is there anyway.
    try Io.Dir.cwd().access(testing.io, dir, .{});
    try testing.expect(std.mem.startsWith(u8, dir, deep.items));
}
