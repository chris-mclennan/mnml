//! `Pane.pty`: a child process on a pty, its ghostty-vt terminal, and the
//! grid the frame paints from. The session's reader thread rings bytes
//! and wakes the UI through `Wire` — a non-blocking post of
//! `.pty_readable{pane}` plus the queue's wake event — and `onReadable`
//! pumps exactly that pane. `tickAll` is the safety net: a pane whose
//! wakeup was lost (queue full) or whose child died without EOF (a
//! grandchild holding the slave) is caught on the next tick.
//!
//! Keys are encoded here (`encodeKey`): legacy xterm bytes by default,
//! kitty `CSI u` once the child has pushed a kitty keyboard flag set.
//! The chord chain in `dispatch.zig` decides which modified chords the
//! app keeps; everything that reaches `feedKey` goes to the child.
//!
//! The pty module picks its backend by target (openpty / fork on POSIX,
//! ConPTY on Windows); this file never names either.

const sessions = @import("../sessions.zig");
const ai = @import("ai.zig");
const std = @import("std");
/// The one "does this pane have the keys" (`render.paneFocused`).
const render = @import("render.zig");
const paneFocused = render.paneFocused;
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const event = @import("../core/event.zig");
const key_mod = @import("../core/key.zig");
const Key = key_mod.Key;
const Mouse = key_mod.Mouse;
const layout_mod = @import("layout.zig");
const arrange = @import("arrange.zig");
const command = @import("../core/command.zig");
const side = @import("side.zig");
const statusline = @import("statusline.zig");
const CommandError = command.CommandError;
const launch_profiles = @import("launch_profiles.zig");
const accent_color = @import("../ui/accent_color.zig");
const session_changes = @import("session_changes.zig");
const pane_accent = @import("pane_accent.zig");
const pane_rail = @import("../ui/pane_rail.zig");
const bufferline = @import("../ui/bufferline.zig");
const Theme = @import("../ui/theme.zig");
const pty_search = @import("pty_search.zig");

/// Every target has a pty backend now (openpty on POSIX, ConPTY on
/// Windows — `src/pty/root.zig`); the flag stays for the callers that
/// grew up gating on it.
pub const supported = true;
const pty = @import("pty");
const first_launch_install = @import("first_launch_install.zig");
const pty_env = @import("pty_env.zig");
const jobs = @import("jobs.zig");

pub const Session = pty.Session;
pub const Grid = pty.Grid;

/// How the child ended.
pub const Exit = union(enum) {
    code: u8,
    signal: u32,

    pub fn ok(self: Exit) bool {
        return self == .code and self.code == 0;
    }
};

/// What opened the pane — the statusline and `test.rerun` read it.
/// `scratch` is the one `term.scratch_toggle` strip per workspace: a
/// shell that hides instead of closing, and is never persisted.
pub const Kind = enum { shell, command, runner, task, scratch };

/// What to do once the child ends — the first-launch wizard's install
/// panes name one, so the terminal hint toasts on the pane's exit 0
/// and never before (`first_launch_install.afterExit`). A follow-up
/// must not open or close panes: it runs from inside the pane walk.
pub const AfterExit = enum { nerd_font_install, ai_cli_install, code_shim_install };

/// Where a new pane lands relative to the active one. `.detached`
/// opens the pane in no leaf at all: the caller hangs it in the tree
/// itself (the AI grid rewrites a cluster around it).
pub const Placement = enum { below, right, above, left, tab, detached };

pub const OpenOptions = struct {
    /// Empty → the user's login shell. Otherwise run as given (a bare
    /// name resolves on PATH).
    argv: []const []const u8 = &.{},
    /// Absolute; the workspace when null.
    cwd: ?[]const u8 = null,
    /// The tab label; the command line (or the shell's name) when null.
    label: ?[]const u8 = null,
    placement: Placement = .below,
    kind: Kind = .shell,
    after_exit: ?AfterExit = null,
    /// // changed (colors): a user-chosen accent to open with — a
    /// resumed session's remembered colour. Null takes the auto slot.
    accent_color: ?[]const u8 = null,
    /// // changed (sessions-worktree): `KEY=VALUE` lines laid over the
    /// app's environment for this child only (`MNML_WORKSPACE` pointing
    /// at a session worktree).
    env_extra: []const []const u8 = &.{},
    /// The label is the user's own (a restored rename): the child's
    /// title does not replace it.
    renamed: bool = false,
    /// Open the pane WITHOUT starting anything: the tab, the title and
    /// `[exited]`, waiting for a key to start it. What a restored
    /// session uses, so relaunching an editor never runs a shell (and
    /// its rc files, and whatever it was in the middle of) unasked.
    dormant: bool = false,
    /// // changed (sessiondiff): an AI session takes its record (the
    /// base `sessions.changes` diffs against) as it starts. A restore
    /// passes false and hands the saved base over instead
    /// (`session_changes.adopt`) — the session started then, not now.
    record_changes: bool = true,
};

/// The reader thread's way into the app: posts `.pty_readable{pane}`
/// without blocking (a full queue drops the post — `tickAll` covers it)
/// and sets the loop's wake event. Heap-allocated per pane and freed
/// after `Session.deinit`, which is when the callback is disarmed.
const Wire = struct {
    events: *event.EventQueue,
    io: Io,
    pane: PaneId,

    fn readable(ctx: ?*anyopaque) void {
        const w: *Wire = @ptrCast(@alignCast(ctx.?));
        _ = w.events.q.put(w.io, &.{.{ .pty_readable = w.pane }}, 0) catch 0;
        w.events.wake.set(w.io);
    }
};

pub const PtyPane = struct {
    /// The child and its pty — `null` on a DORMANT pane: one restored
    /// from `.mnml/session.zon`, which comes back with its tab, its
    /// title and `[exited]` rather than a shell that started itself.
    /// Neovim's `:mksession` does not bring `:terminal` buffers back as
    /// live processes either, and a shell that runs a workspace's rc
    /// files unasked at launch is a surprise nobody chose. Any key on
    /// the pane starts it (`restart`), which is where the session is
    /// filled in.
    session: ?*Session,
    grid: Grid = .{},
    wire: *Wire,
    /// The tab label. Owned. What the tab reads until the child names
    /// itself (OSC 0 / 2), and for good once the user renamed it.
    label: []u8,
    /// The label came from the user (`term.rename`, `:rename`): the
    /// child's own title no longer replaces it.
    renamed: bool = false,
    /// The command line, owned, for `term.restart`; empty = the shell.
    argv: [][]u8,
    cwd: ?[]u8,
    kind: Kind,
    exit: ?Exit = null,
    after_exit: ?AfterExit = null,
    /// The pane's child is blocked on a question — a permission prompt,
    /// a `(y/n)`, a numbered choice — as `sessions.evalNeedsYou` last
    /// read it (`sessions.trackNeedsYou` re-reads it at most every
    /// `sessions.needs_you_ttl_ms`). `sessions.needsYou` answers from
    /// here, for the tab mark, the SESSIONS card and the waiting jumps.
    needs_you: bool = false,
    /// When `needs_you` was last read (the awake clock), and the
    /// `fed_gen` / listing count it was read at: a pane whose output or
    /// listing moved since is read again once the throttle allows.
    needs_you_at_ms: i64 = 0,
    needs_you_gen: u64 = 0,
    needs_you_adopted: u32 = 0,
    /// `fed_gen` when the SESSIONS scan last adopted a listing: the
    /// scan's `waiting` for this pane's session holds only while the
    /// pane has printed nothing since — after that, the grid decides.
    needs_you_snap_gen: u64 = 0,
    /// The AI session's end was announced (`sessions.trackNeedsYou`):
    /// once per run — a restart clears it.
    needs_you_ended: bool = false,
    /// Neovim's terminal-normal mode (`:help CTRL-\_CTRL-N`): the keys
    /// are the app's — the leader, the `Ctrl-W` family, `i` / `a` back
    /// to the child — and nothing reaches the child. vim profile only.
    term_normal: bool = false,
    /// A `Ctrl-\` just arrived and may be the first half of
    /// `<C-\><C-n>`; any other key sends it on to the child first.
    ctrl_backslash_pending: bool = false,
    /// `Ctrl-W` in terminal-normal: the next key names the window verb.
    ctrl_w_pending: bool = false,
    /// // changed (hunt5): `]` / `[` in terminal-normal, waiting for the
    /// key that completes the pair (`]a` / `[a` step the session ring,
    /// as in an editor's normal mode). `true` is `]`.
    bracket_pending: ?bool = null,
    /// A count typed in terminal-normal (`2]a`), consumed by the pair.
    tn_count: u32 = 0,
    /// // changed (colors): the identity strip's colour — a palette name
    /// (`ui/accent_color.zig`): the user's pick, or the auto slot a new
    /// Claude session takes (Rust `PtySession.accent_color`). Owned;
    /// null on a shell and on every pane the user cleared to Auto that
    /// has no slot.
    accent_color: ?[]u8 = null,
    /// // changed (sessions-card): bumped every time `pump` feeds bytes
    /// — the SESSIONS card's cache key (Rust keyed its summary and sort
    /// caches on `bytes_processed`).
    fed_gen: u64 = 0,
    /// // changed (sessions-card): the awake clock when the exit was
    /// noticed; the card's grace window counts from here.
    exited_at_ms: ?i64 = null,
    /// The grid size the session was last fitted to.
    cols: u16,
    rows: u16,
    /// Where the grid was last painted, in screen cells — what a mouse
    /// position is read against.
    body: Body = .{},
    /// A mouse selection in flight (the press's anchor); the selection
    /// itself lives on the terminal's screen, where the grid reads it.
    select: ?Select = null,
    /// What the child was last told about its focus (or would have
    /// been, had it asked): `tickAll` reports the edges. A child is
    /// born into the focus its pane has at the spawn (`bornFocused`),
    /// so only a change after it is an edge.
    has_focus: bool = false,
    /// Restored from a saved session and never started: `session` is
    /// null, `exit` is set so every live-pane path already skips it, and
    /// the footer says a key restarts rather than closes.
    dormant: bool = false,
    /// // changed (codex-resume): the WALL clock when the child was
    /// spawned, in epoch seconds (`exited_at_ms` is the awake clock and
    /// cannot be compared with a file's timestamp). A Codex session
    /// takes no id on its command line, so this is half of what names
    /// it — the rollout opened in this pane's cwd at or after this
    /// second (`ai/codex_rollout.zig`). 0 on a pane that never started.
    started_at_s: i64 = 0,
    /// // changed (codex-resume): the Codex session this pane was found
    /// to be running. Owned; learned once and kept, because the window
    /// that identifies a session only narrows as later ones start — the
    /// first unambiguous answer is the one worth holding.
    codex_session_id: ?[]u8 = null,
    /// The child was a resume (`claude --resume <id>`, `codex resume
    /// <id>`) and exited saying there is no such conversation — a
    /// transcript deleted since the save, or one the CLI cannot see.
    /// The pane offers `Enter` = a new session in its place
    /// (`startFresh`) instead of closing, and its card says why.
    resume_missing: bool = false,
    /// The scrollback search (`pty_search.zig`): the query, its matches
    /// and the scan's place.
    search: pty_search.Search = .{},
    /// // changed (sessiondiff): an AI session's base and its latest
    /// set — what `sessions.changes` shows (`app/session_changes.zig`).
    /// Owned; null on a shell, and on a session outside any repository.
    changes: ?*session_changes.Record = null,

    pub fn deinit(self: *PtyPane, gpa: Allocator) void {
        if (self.changes) |c| c.destroy(gpa);
        if (self.session) |s| s.deinit();
        self.grid.deinit(gpa);
        self.search.deinit(gpa);
        gpa.destroy(self.wire);
        if (self.accent_color) |c| gpa.free(c);
        if (self.codex_session_id) |c| gpa.free(c);
        gpa.free(self.label);
        for (self.argv) |a| gpa.free(a);
        gpa.free(self.argv);
        if (self.cwd) |c| gpa.free(c);
    }

    /// Drain the ring into the terminal and notice an exit. The frame
    /// after this repaints the pane.
    pub fn pump(self: *PtyPane, app: *App) void {
        const session = self.session orelse return;
        const fed = session.pump();
        if (fed) self.fed_gen +%= 1;
        // The child copied (OSC 52): the text takes the path any copy
        // takes — the unnamed register and the OS clipboard.
        if (session.takeClipboard()) |text| {
            defer app.gpa.free(text);
            app.clipboard.setPendingRegister('+');
            app.clipboard.setYank(text, false) catch {};
        }
        // A bounded pump can leave bytes behind; the exit waits until the
        // last of the child's output is in the terminal.
        if (self.exit == null and !session.backlog()) {
            self.exit = exitOf(session.exited());
            if (self.exit != null) {
                self.exited_at_ms = app.now_ms;
                self.noticeExit(app);
            }
        }
        if (fed or self.exit != null) app.needs_render = true;
    }

    /// The Claude session this pane runs, off its command line: the
    /// `--session-id <id>` a new session is started with, or the
    /// `--resume <id>` of a resumed one. Null for a shell, Codex, and
    /// a bare `claude`.
    pub fn sessionId(self: *const PtyPane) ?[]const u8 {
        return sessionIdOfArgv(self.argv);
    }

    /// The exit just landed: note a resume that found nothing, and run
    /// the follow-up, once.
    fn noticeExit(self: *PtyPane, app: *App) void {
        self.resume_missing = self.resumeFoundNothing(app);
        const follow = self.after_exit orelse return;
        self.after_exit = null;
        first_launch_install.afterExit(app, follow, self.exit.?);
    }

    /// A resume line that failed with the CLI's "no such session" on
    /// screen (`resume_missing_marks`).
    fn resumeFoundNothing(self: *const PtyPane, app: *App) bool {
        const e = self.exit orelse return false;
        if (e.ok() or !isResumeArgv(@ptrCast(self.argv))) return false;
        const session = self.session orelse return false;
        const text = session.terminal().plainString(app.gpa) catch return false;
        defer app.gpa.free(text);
        for (resume_missing_marks) |m| if (std.mem.indexOf(u8, text, m) != null) return true;
        return false;
    }

    fn exitOf(e: ?pty.session.Exit) ?Exit {
        const x = e orelse return null;
        return switch (x) {
            .code => |c| .{ .code = c },
            .signal => |s| .{ .signal = s },
        };
    }

    /// Resize the pty and the terminal to the rect the layout gave the
    /// pane. Cheap when unchanged.
    pub fn fit(self: *PtyPane, cols: u16, rows: u16) void {
        if (cols == 0 or rows == 0) return;
        if (cols == self.cols and rows == self.rows) return;
        // A dormant pane has no pty to size; the grid it paints is empty
        // either way, and the fresh child takes these cells.
        if (self.session) |s| s.resize(cols, rows) catch return;
        self.cols = cols;
        self.rows = rows;
    }

    /// Queue bytes for the child. Never blocks: the session's own thread
    /// writes them as the child reads (`pty/outbox.zig`), so a paste into
    /// a build that is not reading its input leaves the app responsive.
    pub fn write(self: *PtyPane, bytes: []const u8) void {
        if (self.exit != null) return;
        const session = self.session orelse return;
        // Typing brings the live screen back, and lets go of a
        // selection (ghostty's `selection-clear-on-typing`).
        session.terminal().scrollViewport(.bottom);
        clearSelection(self);
        // Ctrl+C must not wait behind input the child is not reading.
        if (bytes.len == 1 and bytes[0] == 0x03) return session.interrupt();
        session.write(bytes);
    }

    pub fn scrollBy(self: *PtyPane, delta: isize) void {
        const session = self.session orelse return;
        session.terminal().scrollViewport(.{ .delta = delta });
    }

    pub fn scrollTo(self: *PtyPane, where: enum { top, bottom }) void {
        const session = self.session orelse return;
        session.terminal().scrollViewport(switch (where) {
            .top => .top,
            .bottom => .bottom,
        });
    }

    /// What the child has asked the terminal for — the encoders read it.
    pub fn encoding(self: *const PtyPane) Encoding {
        const session = self.session orelse return .{};
        const term = &session.term;
        const kitty = term.screens.active.kitty_keyboard.current();
        return .{
            .kitty = kitty.disambiguate or kitty.report_all,
            .cursor_keys_app = term.modes.get(.cursor_keys),
            .bracketed_paste = term.modes.get(.bracketed_paste),
            .mouse = switch (term.flags.mouse_event) {
                .none => .none,
                .x10 => .x10,
                .normal => .normal,
                .button => .button,
                .any => .any,
            },
            .mouse_sgr = term.flags.mouse_format == .sgr or term.flags.mouse_format == .sgr_pixels,
        };
    }

    /// The child's title (OSC 0/2), if it set one.
    pub fn childTitle(self: *const PtyPane) ?[]const u8 {
        const session = self.session orelse return null;
        return session.term.getTitle();
    }

    /// Where the shell says it is (OSC 7 — ghostty's shell integration,
    /// macOS's `update_terminal_cwd`, starship, fish, the mnml prompt):
    /// an absolute path on `arena`, or null when the child never said or
    /// said something that is not a local `file://` URL.
    pub fn liveCwd(self: *const PtyPane, arena: Allocator) Allocator.Error!?[]const u8 {
        const session = self.session orelse return null;
        return pwdPath(arena, session.term.getPwd() orelse return null);
    }

    /// What the tab reads, in the order every terminal's tab follows:
    /// the user's rename, then the title the child set (a shell prompt's
    /// cwd, vim's file, an ssh host), then the label it opened with.
    /// Borrowed from the terminal — valid until the child retitles.
    pub fn tabTitle(self: *const PtyPane) []const u8 {
        if (!self.renamed) if (self.childTitle()) |title| {
            // A Claude session titles its window `✳ <task>` while it
            // thinks: the spinner is state, not a name, and no reader of
            // the title (the tab, the card, the info view's header)
            // wants it. Only a leading spinner glyph is stripped, so a
            // shell's `~/proj` keeps its tilde.
            const trimmed = sessions.stripLeadingSpinnerOnly(std.mem.trim(u8, title, " \t"));
            if (trimmed.len > 0) return trimmed;
        };
        return self.label;
    }
};

// ─── open / close ───────────────────────────────────────────────────────

/// Spawn and show a pty pane. The new pane becomes active.
pub fn open(app: *App, opts: OpenOptions) CommandError!PaneId {
    if (!supported) return error.Unsupported;
    const gpa = app.gpa;
    // Once the pane is in the store, the store owns what these free:
    // an error after that (the placement, the spawn) closes the pane.
    var stored = false;
    const argv = try gpa.alloc([]u8, opts.argv.len);
    var filled: usize = 0;
    errdefer if (!stored) {
        for (argv[0..filled]) |a| gpa.free(a);
        gpa.free(argv);
    };
    for (opts.argv) |a| {
        argv[filled] = try gpa.dupe(u8, a);
        filled += 1;
    }
    const label = try labelFor(app, opts);
    errdefer if (!stored) gpa.free(label);
    const cwd: ?[]u8 = if (opts.cwd) |c| try gpa.dupe(u8, c) else null;
    errdefer if (!stored) if (cwd) |c| gpa.free(c);

    const guess = initialSize(app, opts);
    const id = app.panes.peekId();
    const wire = try gpa.create(Wire);
    errdefer if (!stored) gpa.destroy(wire);
    wire.* = .{ .events = app.events, .io = app.io, .pane = id };

    // // changed (accent-defaults): a remembered colour first; else the
    // kind's default while nothing of the kind wears it; else null, and
    // `PaneStore.add` hands out the next free ladder slot.
    const remembered: ?[]const u8 = if (opts.accent_color) |c| accent_color.canonical(c) else null;
    const chosen: ?[]const u8 = remembered orelse pane_accent.defaultFor(app, pane_accent.kindOfArgv(app, argv));
    const accent: ?[]u8 = if (chosen) |name| try gpa.dupe(u8, name) else null;
    errdefer if (!stored) if (accent) |c| gpa.free(c);

    // The pane goes into the store and the layout BEFORE its child
    // starts, so the child starts at the size the layout gives it
    // (`startChild`) rather than at a guess the first frame corrects:
    // a resize right after the spawn lands while the shell prints its
    // first prompt, and zsh's end-of-line `%` from the old width stays
    // on screen above it.
    const got = try app.panes.add(.{
        .pty = .{
            .session = null,
            .wire = wire,
            .label = label,
            .renamed = opts.renamed,
            .argv = argv,
            .cwd = cwd,
            .kind = opts.kind,
            // A dormant pane reads as exited from the first frame, so every
            // path that skips a dead child (`write`, the cursor, the
            // sessions card) skips it without learning a new state.
            .exit = if (opts.dormant) .{ .code = 0 } else null,
            .dormant = opts.dormant,
            .after_exit = opts.after_exit,
            .accent_color = accent,
            .cols = guess.cols,
            .rows = guess.rows,
        },
    });
    std.debug.assert(got == id);
    stored = true;
    place(app, id, opts.placement) catch |err| {
        app.panes.remove(id);
        return err;
    };
    if (!opts.dormant) startChild(app, id, opts.env_extra) catch |err| {
        app.forceClosePane(id) catch {};
        return err;
    };
    bornFocused(app, id);
    if (!opts.dormant and opts.record_changes) try session_changes.onSessionStart(app, id);
    app.needs_render = true;
    return id;
}

/// Spawn pane `id`'s child at the size the layout gives the pane
/// (`render.paneContentRect`); a pane in no leaf on screen (`.detached`
/// — its caller hangs it in the tree) keeps the guess it was added
/// with.
fn startChild(app: *App, id: PaneId, env_extra: []const []const u8) CommandError!void {
    const p = app.panes.pty(id).?;
    if (try render.paneContentRect(app, id, app.frame.allocator())) |r| if (r.w > 0 and r.h > 0) {
        p.cols = r.w;
        p.rows = r.h;
    };
    // The child's environment: the app's, the extras, and what it is
    // told about the pane it runs in (`pty_env.zig`).
    var launch: pty_env.Launch = .{};
    var child_env = try pty_env.build(app, env_extra, if (p.argv.len == 0) &launch else null);
    defer child_env.deinit();
    // // changed (codex-resume): read BEFORE the spawn. The child may
    // open its Codex rollout before this call returns, and a rollout
    // dated a second earlier than the pane would never match it.
    p.started_at_s = Io.Timestamp.now(app.io, .real).toSeconds();
    p.session = pty.Session.spawn(app.gpa, app.io, .{
        .cols = p.cols,
        .rows = p.rows,
        .env = &child_env,
        .argv = if (p.argv.len == 0) null else @ptrCast(p.argv),
        .shell_args = launch.args,
        .shell_login = launch.login,
        .cwd = p.cwd orelse app.workspace,
        .notify = .{ .ctx = p.wire, .fn_ptr = &Wire.readable },
        .scrollback_lines = app.cfg.terminal.scrollback_lines,
        .clipboard_write = app.cfg.terminal.osc52,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return app.diag.fail(app.frame.allocator(), "{s}: {s}", .{ p.label, @errorName(err) }),
    };
}

// ─── the accent (colors) ────────────────────────────────────────────────

/// The AI product this pane runs, by its command's first word (the bare
/// binary or one of its profile shims) — what the accent rules key on,
/// as Rust's `integration_id` did. Null for a shell and every other
/// command.
pub fn productOf(app: *const App, p: *const PtyPane) ?launch_profiles.Product {
    return productOfArgv(app, p.argv);
}

/// The same, for a command line that has no pane yet (the accent a
/// pane opens in is decided before it is in the store).
pub fn productOfArgv(app: *const App, argv: []const []const u8) ?launch_profiles.Product {
    if (argv.len == 0) return null;
    for (std.enums.values(launch_profiles.Product)) |product| {
        if (launch_profiles.isProductArgv(app, argv[0], product)) return product;
    }
    return null;
}

/// A pane with no colour takes the next free slot off the shared
/// ladder. // changed (pane-rail): `PaneStore.add` does this for every
/// pane it opens, whatever its kind — a shell is as much a pane as a
/// Claude session, and telling two shells apart is the point. This
/// stays as the way back after a colour was cleared.
pub fn assignAutoAccent(app: *App, id: PaneId) Allocator.Error!void {
    try pane_accent.assign(app, id);
}

/// `name` becomes the pane's accent; the `none` sentinel clears it and
/// the pane takes the next free slot (Rust `set_session_color`). An
/// unknown name is ignored.
pub fn setAccent(app: *App, id: PaneId, name: []const u8) Allocator.Error!void {
    try pane_accent.setName(app, id, name);
}

/// Anthropic's orange — one definition, in `ui/brand.zig`, shared with
/// the statusline chip and the tab-bar mark.
pub const claude_brand = @import("../ui/brand.zig").claude;

/// The colour of the pane's identity strip and tab glyph, in Rust's
/// precedence (`accent_color_for_pty`): the pane's own name first,
/// then the product's brand (Claude's coral, Codex in the theme's
/// cyan); null for a shell and every other command, which get no
/// strip.
pub fn accentOf(app: *const App, p: *const PtyPane, theme: *const Theme) ?Theme.Color {
    if (p.accent_color) |name| if (accent_color.resolve(name, theme)) |c| return c;
    return switch (productOf(app, p) orelse return null) {
        .claude => claude_brand,
        .codex => theme.palette.cyan,
    };
}

/// The name of the terminal mnml itself is running inside — what a
/// shell pane's tab goes by (`labelFor`). Only the name: the mark is
/// mnml's own whatever the emulator (`terminal_glyph.mark`).
pub fn hostTerminalName(app: *const App) []const u8 {
    return bufferline.terminalName(app.env.get("TERM_PROGRAM"), app.env.get("WT_SESSION"));
}

/// The shell's own name as the tab spells it: the binary's base
/// without the Windows suffix — `zsh`, `bash`, `fish`, `pwsh`.
pub fn shellName(app: *const App) []const u8 {
    // The same choice the session makes: `$SHELL` on POSIX, `%COMSPEC%`
    // on Windows (where `$SHELL`, if set at all, is Git Bash's fiction).
    const shell = if (pty.is_windows) pty.win_cmdline.defaultShell(&app.env) else app.env.get("SHELL") orelse "sh";
    const base = std.fs.path.basename(shell);
    return if (std.ascii.endsWithIgnoreCase(base, ".exe")) base[0 .. base.len - 4] else base;
}

fn labelFor(app: *App, opts: OpenOptions) Allocator.Error![]u8 {
    const gpa = app.gpa;
    if (opts.label) |l| return gpa.dupe(u8, l);
    // A shell reads `<terminal> (<shell>)`, as Rust's `BinaryProfile::
    // shell` spells it: the terminal mnml runs inside, then the child.
    if (opts.argv.len == 0) return std.fmt.allocPrint(gpa, "{s} ({s})", .{ hostTerminalName(app), shellName(app) });
    return std.mem.join(gpa, " ", opts.argv);
}

/// A guess at the pane's size, for a pane the layout does not place
/// (`.detached`) and for a dormant one; `startChild` asks the layout
/// for everything else. The guess counts no divider and the rail once,
/// so a split is off by a column or more — the first frame's `fit`
/// corrects it.
fn initialSize(app: *App, opts: OpenOptions) struct { cols: u16, rows: u16 } {
    const placement = opts.placement;
    // // changed (pane-rail): the rail takes a column off the pane, so
    // the child starts at the width it will really get. A width it has
    // to be resized off reflows the terminal on the first frame, and
    // the reflow costs whatever the child had already written — the
    // scrollback the wheel is there to scroll.
    const rail: u16 = if (railOnFor(app, opts)) pane_rail.width else 0;
    const body_w = app.screen.width -| (if (app.tree.visible) app.tree.width + 1 else 0) -| rail;
    const body_h = app.screen.height -| 2;
    const cols: u16 = switch (placement) {
        .right, .left, .detached => body_w / 2,
        else => body_w,
    };
    const rows: u16 = switch (placement) {
        .below, .above, .detached => body_h / 2,
        else => body_h,
    };
    return .{ .cols = @max(cols, 2), .rows = @max(rows, 1) };
}

/// Whether a pane opened with `opts` will wear a rail, which only
/// `ui.pane_rail` and — under `sessions` — the product the argv names
/// can answer before the pane exists.
fn railOnFor(app: *App, opts: OpenOptions) bool {
    return switch (app.cfg.ui.pane_rail) {
        .off => false,
        .all => true,
        .sessions => opts.argv.len > 0 and for (std.enums.values(launch_profiles.Product)) |product| {
            if (launch_profiles.isProductArgv(app, opts.argv[0], product)) break true;
        } else false,
    };
}

/// Put `id` where `placement` says. With no active leaf it simply
/// becomes the only one. Public for the scratch strip, which hides a
/// live pane and later puts it back below the active one.
pub fn place(app: *App, id: PaneId, placement: Placement) Allocator.Error!void {
    if (placement == .detached) return;
    if (placement == .tab) {
        app.showPane(id);
        return;
    }
    const dir: layout_mod.SplitDir = switch (placement) {
        .below, .above => .vertical,
        .right, .left => .horizontal,
        .tab, .detached => unreachable,
    };
    // `integrations.arrange` sizes it — the one rule every new pane
    // goes through (`app/arrange.zig`); `.fixed` is the half-the-active
    // -pane this used to do on its own.
    _ = try arrange.splitActive(app, id, .{
        .dir = dir,
        .before = placement == .above or placement == .left,
    });
}

/// Replace the child with a fresh one running the same command line.
pub fn restart(app: *App, id: PaneId) CommandError!void {
    return restartWith(app, id, .relaunch);
}

/// `Enter` on a pane whose resume found no conversation
/// (`PtyPane.resume_missing`): a NEW session in its place — Claude under
/// the same id, Codex under the one it picks (`freshInPlace`).
pub fn startFresh(app: *App, id: PaneId) CommandError!void {
    return restartWith(app, id, .fresh);
}

fn restartWith(app: *App, id: PaneId, how: enum { relaunch, fresh }) CommandError!void {
    if (!supported) return error.Unsupported;
    const pane = app.panes.get(id) orelse return error.NoActivePane;
    const p = switch (pane.*) {
        .pty => |*p| p,
        else => return error.NotAnEditor,
    };
    pty_search.onRestart(p);
    switch (how) {
        // A Claude session started with `--session-id` cannot be
        // started twice under that id once it has a transcript, and
        // cannot be resumed before it has one: the relaunch rule picks.
        .relaunch => try relaunchInPlace(app.gpa, p.argv, relaunchOf(app, @ptrCast(p.argv), p.cwd)),
        .fresh => try freshInPlace(app.gpa, &p.argv),
    }
    p.resume_missing = false;
    // // changed (codex-resume): before the spawn, as in `open`.
    const started_at_s = Io.Timestamp.now(app.io, .real).toSeconds();
    var launch: pty_env.Launch = .{};
    var child_env = try pty_env.build(app, &.{}, if (p.argv.len == 0) &launch else null);
    defer child_env.deinit();
    const fresh = pty.Session.spawn(app.gpa, app.io, .{
        .cols = p.cols,
        .rows = p.rows,
        .env = &child_env,
        .argv = if (p.argv.len == 0) null else @ptrCast(p.argv),
        .shell_args = launch.args,
        .shell_login = launch.login,
        .cwd = p.cwd orelse app.workspace,
        .notify = .{ .ctx = p.wire, .fn_ptr = &Wire.readable },
        .scrollback_lines = app.cfg.terminal.scrollback_lines,
        .clipboard_write = app.cfg.terminal.osc52,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return app.diag.fail(app.frame.allocator(), "{s}: {s}", .{ p.label, @errorName(err) }),
    };
    if (p.session) |old| old.deinit();
    p.grid.deinit(app.gpa);
    p.grid = .{};
    // The anchor was tracked in the old terminal's pages.
    p.select = null;
    p.session = fresh;
    p.exit = null;
    p.exited_at_ms = null;
    p.dormant = false;
    bornFocused(app, id);
    // // changed (codex-resume): a fresh child is a fresh window to
    // match a Codex rollout in, and the id the last one was found under
    // is not this one's unless the command line says `resume <id>`.
    p.started_at_s = started_at_s;
    if (p.codex_session_id) |c| app.gpa.free(c);
    p.codex_session_id = null;
    // sessiondiff: a pane restored dormant with no saved base starts
    // its record now; one that has a base keeps it — a resume is the
    // same session.
    try session_changes.onSessionStart(app, id);
    app.needs_render = true;
}

// ─── the event side ─────────────────────────────────────────────────────

/// `.pty_readable{id}` landed: pump that pane.
/// The live pane already running AI session `id`: a Claude pane whose
/// command line names it (`--session-id` / `--resume`), or a Codex
/// pane that resumed it or whose rollout was found to be it. Null when
/// no child that is still running holds it. A resume of an id this
/// answers for would be a SECOND process on one conversation — two
/// writers on one transcript, the spend doubled — so every resume path
/// (`session.restore`, the session picker) asks here first.
pub fn liveSessionPane(app: *App, id: []const u8) ?PaneId {
    if (id.len == 0) return null;
    var pid: PaneId = 0;
    while (pid < app.panes.capacity()) : (pid += 1) {
        const p = app.panes.pty(pid) orelse continue;
        if (p.exit != null) continue;
        const held = p.sessionId() orelse codexSessionIdOfArgv(p.argv) orelse p.codex_session_id orelse continue;
        if (std.mem.eql(u8, held, id)) return pid;
    }
    return null;
}

/// `--session-id <id>` / `--resume <id>` in a command line, if either.
pub fn sessionIdOfArgv(argv: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--session-id") or std.mem.eql(u8, argv[i], "--resume")) return argv[i + 1];
    }
    return null;
}

/// // changed (codex-resume): the Codex session a command line names.
/// Only one line ever does — `codex resume <id>`, as
/// `cli.codexResumeArgv` writes it for a restore — because Codex takes
/// no session id when it STARTS one. Null for every other line.
pub fn codexSessionIdOfArgv(argv: []const []const u8) ?[]const u8 {
    if (argv.len < 3) return null;
    if (!std.mem.eql(u8, argv[1], "resume")) return null;
    const id = argv[2];
    if (id.len == 0 or id[0] == '-') return null;
    return id;
}

/// How a saved or restarted Claude session starts again.
pub const Relaunch = enum {
    /// `--resume <id>`: Claude Code wrote a transcript for the id.
    resume_it,
    /// `--session-id <id>` again: it never did — nothing was typed into
    /// the session — so there is no conversation to resume, and the id
    /// is still free to start under.
    start_fresh,
};

/// The relaunch rule, the one place a saved or restarted AI session's
/// command line is decided. A Claude line resumes (`--resume <id>`) only
/// when a transcript for that id exists under the Claude data dir for
/// the pane's cwd (`claudeTranscriptExists`); otherwise it starts again
/// under the SAME id (`--session-id <id>`), so the card and the tab keep
/// their identity. `claude --resume` of an id with no transcript is a
/// hard error — `No conversation found with session ID` and exit 1 —
/// which is what a session the user never typed into used to come back
/// as. Any other line is left as it is.
pub fn relaunchOf(app: *App, argv: []const []const u8, cwd: ?[]const u8) Relaunch {
    const id = sessionIdOfArgv(argv) orelse return .resume_it;
    if (argv.len == 0 or !launch_profiles.isProductArgv(app, argv[0], .claude)) return .resume_it;
    return if (claudeTranscriptExists(app, id, cwd)) .resume_it else .start_fresh;
}

/// Whether Claude Code has a transcript for session `id` started in
/// `cwd` (the workspace when null): `<home>/.claude/projects/<cwd
/// encoded>/<id>.jsonl`, the file `claude --resume` looks for. The home
/// is the SESSIONS scan's (`sessions.homeFor`); the cwd is tried
/// resolved first — Claude names the directory for the cwd the OS
/// reports — then as given, each spelled the one way Claude Code spells
/// it (`ai.encodeWorkspace`: every byte that is not an ASCII letter or
/// digit becomes `-`).
pub fn claudeTranscriptExists(app: *App, id: []const u8, cwd: ?[]const u8) bool {
    if (id.len == 0) return false;
    // The scan already found it.
    if (app.sessions.itemOf(id)) |it| if (it.source == .claude and it.transcript_path.len > 0) {
        if (Io.Dir.cwd().statFile(app.io, it.transcript_path, .{})) |_| return true else |_| {}
    };
    const home = (sessions.homeFor(app) catch return false) orelse return false;
    const arena = app.frame.allocator();
    const dir = cwd orelse app.workspace;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved: []const u8 = if (Io.Dir.cwd().realPathFile(app.io, dir, &buf)) |n| buf[0..n] else |_| dir;
    const name = std.fmt.allocPrint(arena, "{s}.jsonl", .{id}) catch return false;
    for ([_][]const u8{ resolved, dir }) |spelling| {
        const enc = ai.encodeWorkspace(arena, spelling) catch return false;
        const path = std.fs.path.join(arena, &.{ home, ".claude", "projects", enc, name }) catch return false;
        if (Io.Dir.cwd().statFile(app.io, path, .{})) |_| return true else |_| {}
    }
    return false;
}

/// Spell the session flag of `argv` for `how`, in place — the flag's
/// cell is replaced on `gpa`. A line without the flag is untouched.
pub fn relaunchInPlace(gpa: Allocator, argv: [][]u8, how: Relaunch) Allocator.Error!void {
    const want = switch (how) {
        .resume_it => "--resume",
        .start_fresh => "--session-id",
    };
    for (argv) |*a| if (std.mem.eql(u8, a.*, "--session-id") or std.mem.eql(u8, a.*, "--resume")) {
        if (std.mem.eql(u8, a.*, want)) return;
        const fresh = try gpa.dupe(u8, want);
        gpa.free(a.*);
        a.* = fresh;
        return;
    };
}

/// `relaunchInPlace` on a copy: `argv` on `arena` with the flag the
/// relaunch rule picks for a line started in `cwd`.
pub fn relaunchArgv(app: *App, arena: Allocator, argv: []const []const u8, cwd: ?[]const u8) Allocator.Error![]const []const u8 {
    const want: []const u8 = switch (relaunchOf(app, argv, cwd)) {
        .resume_it => "--resume",
        .start_fresh => "--session-id",
    };
    const out = try arena.alloc([]const u8, argv.len);
    var done = false;
    for (argv, 0..) |a, i| {
        const flag = !done and (std.mem.eql(u8, a, "--session-id") or std.mem.eql(u8, a, "--resume"));
        if (flag) done = true;
        out[i] = if (flag) want else a;
    }
    return out;
}

/// A resume that found no conversation to continue: the CLI's own words
/// for it — Claude Code's `No conversation found with session ID`, and
/// Codex's `No saved session found with ID` — are on the pane's screen.
pub const resume_missing_marks = [_][]const u8{ "No conversation found", "No saved session found" };

/// Whether `argv` resumes a session: a Claude `--resume <id>`, or a
/// Codex `resume <id>`.
pub fn isResumeArgv(argv: []const []const u8) bool {
    if (codexSessionIdOfArgv(argv) != null) return true;
    var i: usize = 0;
    while (i + 1 < argv.len) : (i += 1) if (std.mem.eql(u8, argv[i], "--resume")) return true;
    return false;
}

/// The command line that starts a NEW session where a resume found
/// nothing, on `gpa`, replacing `argv`'s cells: Claude's `--resume <id>`
/// becomes `--session-id <id>` (the same id, so the card and the tab
/// keep their identity); Codex's `resume <id>` is dropped, and Codex
/// names the session it starts itself.
pub fn freshInPlace(gpa: Allocator, argv: *[][]u8) Allocator.Error!void {
    if (codexSessionIdOfArgv(argv.*) != null) {
        const old = argv.*;
        const out = try gpa.alloc([]u8, old.len - 2);
        out[0] = old[0];
        @memcpy(out[1..], old[3..]);
        gpa.free(old[1]);
        gpa.free(old[2]);
        gpa.free(old);
        argv.* = out;
        return;
    }
    try relaunchInPlace(gpa, argv.*, .start_fresh);
}

/// `argv` with `--session-id` spelled `--resume`, on `arena` (the
/// session file's copy). The spelling only: the restore decides the
/// flag again against the transcripts it finds (`relaunchArgv`).
pub fn resumeArgv(arena: Allocator, argv: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, argv.len);
    for (argv, 0..) |a, i| out[i] = if (std.mem.eql(u8, a, "--session-id")) "--resume" else a;
    return out;
}

pub fn onReadable(app: *App, id: PaneId) void {
    const pane = app.panes.get(id) orelse return;
    switch (pane.*) {
        .pty => |*p| {
            p.pump(app);
            settleSpawn(app, id, p);
        },
        else => {},
    }
}

/// `open` for an AI session. The spawn is a background job until the
/// child says something: a session that exits before its first byte (a
/// CLI that is not signed in, a profile naming a missing binary) FAILED
/// to start — which used to read as a pane that simply closed.
pub fn openSession(app: *App, opts: OpenOptions) CommandError!PaneId {
    const arena = app.frame.allocator();
    const label = try std.fmt.allocPrint(arena, "spawn {s}", .{opts.label orelse (if (opts.argv.len > 0) std.fs.path.basename(opts.argv[0]) else "session")});
    const id = open(app, opts) catch |err| {
        if (err != error.OutOfMemory) jobs.record(app, .{ .kind = .session, .label = label }, 0, jobs.Outcome.fail(app.diag.msg orelse @errorName(err)));
        return err;
    };
    _ = try jobs.begin(app, .{ .kind = .session, .key = id, .label = label, .pane = id });
    return id;
}

/// A session spawn's job ends with the first output, or with an exit
/// before any.
fn settleSpawn(app: *App, id: PaneId, p: *const PtyPane) void {
    if (!jobs.running(app, .session, id)) return;
    if (p.fed_gen != 0) return jobs.endKeyed(app, .session, id, jobs.Outcome.done("started"));
    const e = p.exit orelse return;
    const words = switch (e) {
        .code => |c| std.fmt.allocPrint(app.frame.allocator(), "exited {d} before any output", .{c}) catch "exited before any output",
        .signal => "killed before any output",
    };
    jobs.endKeyed(app, .session, id, jobs.Outcome.fail(words));
}

/// Every tick: a pane with ringed bytes whose wakeup was dropped, and a
/// child that died without closing the pty, are both picked up here.
pub fn tickAll(app: *App) void {
    if (!supported) return;
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*pane| switch (pane.*) {
        .pty => |*p| {
            if (p.exit != null) continue;
            const session = p.session orelse continue;
            reportFocus(app, p, @intCast(i));
            if (session.shared.ring.len() > 0 or session.eof()) {
                p.pump(app);
            } else if (session.exited()) |e| {
                p.exit = PtyPane.exitOf(e);
                p.exited_at_ms = app.now_ms;
                p.noticeExit(app);
                app.needs_render = true;
            }
            settleSpawn(app, @intCast(i), p);
        },
        else => {},
    };
}

/// A pane has output its last pump left in the ring (`Session.pump`
/// takes a bounded bite): the loop owes it another pass now, not after
/// the next wakeup — the reader posts only when it adds bytes, and a
/// child that has finished writing never does.
pub fn backlog(app: *const App) bool {
    for (app.panes.slots.items) |*slot| if (slot.*) |*pane| switch (pane.*) {
        .pty => |*p| if (p.session) |session| if (session.backlog()) return true,
        else => {},
    };
    return false;
}

/// Focus reports (DEC 1004): a child that asked hears `ESC [ I` when its
/// pane takes the focus and `ESC [ O` when it loses it — to another
/// pane, to the tree or an overlay, or because the host window itself
/// lost it — as ghostty sends them per surface and tmux per pane.
/// vim's FocusGained / FocusLost (`autoread`), neovim, helix and lazygit
/// rely on it.
fn reportFocus(app: *App, p: *PtyPane, id: PaneId) void {
    const focused = focusedNow(app, id);
    if (focused == p.has_focus) return;
    p.has_focus = focused;
    const session = p.session orelse return;
    if (!session.terminal().modes.get(.focus_event)) return;
    session.write(if (focused) "\x1b[I" else "\x1b[O");
}

fn focusedNow(app: *const App, id: PaneId) bool {
    return app.host_focused and paneFocused(app, id);
}

/// A fresh child starts out knowing its pane's focus: no report is owed
/// for a focus it was spawned into. Left at the default `false`, the
/// first `tickAll` saw a focus-in edge on every pane opened focused, and
/// sent `ESC [ I` or not depending on whether the child's `ESC [?1004h`
/// had been pumped yet — a race the child lost a spurious report to.
fn bornFocused(app: *App, id: PaneId) void {
    const p = app.panes.pty(id) orelse return;
    p.has_focus = focusedNow(app, id);
}

// ─── input ──────────────────────────────────────────────────────────────

/// Chords a terminal owns outright: job control and readline's clear.
/// The chord chain never sees these while a pty pane is focused.
pub fn childOwned(k: Key) bool {
    if (!k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    const c = switch (k.code) {
        .char => |c| c,
        else => return false,
    };
    return c == 'c' or c == 'd' or c == 'z' or c == 'l';
}

/// Terminal mode's way out (`:help CTRL-\_CTRL-N`; NvChad also maps
/// `<C-x>` in terminal mode to it — mappings.lua "terminal escape
/// terminal mode"). Returns true when the key was taken: `Ctrl-\`
/// arms, `Ctrl-N` after it (or `Ctrl-X` alone) enters terminal-normal;
/// any other key after `Ctrl-\` sends the `Ctrl-\` on and is not taken.
pub fn escapeKey(app: *App, p: *PtyPane, k: Key) bool {
    if (app.input_style != .vim) return false;
    const ctrl_only = k.mods.ctrl and !k.mods.alt and !k.mods.super and !k.mods.shift;
    const c: u21 = switch (k.code) {
        .char => |c| if (c < 0x80) std.ascii.toLower(@intCast(c)) else c,
        else => 0,
    };
    if (p.ctrl_backslash_pending) {
        p.ctrl_backslash_pending = false;
        if (ctrl_only and c == 'n') {
            enterTermNormal(app, p);
            return true;
        }
        feedKey(app, p, Key.ctrl('\\'));
        return false;
    }
    if (ctrl_only and c == '\\') {
        p.ctrl_backslash_pending = true;
        return true;
    }
    if (ctrl_only and c == 'x') {
        enterTermNormal(app, p);
        return true;
    }
    return false;
}

fn enterTermNormal(app: *App, p: *PtyPane) void {
    p.term_normal = true;
    p.ctrl_w_pending = false;
    p.bracket_pending = null;
    p.tn_count = 0;
    app.needs_render = true;
}

/// Terminal-normal mode's own keys: `i` / `a` / `I` / `A` back to the
/// child (`:help t_i`), the `Ctrl-W` family as any window has it.
/// Returns false for a key the chord chain should see.
pub fn termNormalKey(app: *App, p: *PtyPane, k: Key) Allocator.Error!bool {
    if (p.ctrl_w_pending) {
        p.ctrl_w_pending = false;
        if (side.ctrlWCommand(k)) |id| command.run(app, .{ .static = id }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
        return true;
    }
    if (side.isCtrlW(app, k)) {
        p.ctrl_w_pending = true;
        return true;
    }
    // `]a` / `[a` (with a count): the session ring, as an editor's
    // normal mode has it. The bracket waits for its second key; any
    // other second key cancels the pair, as Neovim does, rather than
    // being read on its own (`a` would leave terminal-normal).
    if (p.bracket_pending) |forward| {
        p.bracket_pending = null;
        const n = @max(p.tn_count, 1);
        p.tn_count = 0;
        const plain = !(k.mods.ctrl or k.mods.alt or k.mods.super);
        if (plain and k.code == .char and k.code.char == 'a') {
            const session_cycle = @import("session_cycle.zig");
            var i: u32 = 0;
            while (i < n) : (i += 1) session_cycle.step(app, if (forward) .next else .prev) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break,
            };
        }
        app.needs_render = true;
        return true;
    }
    if (k.mods.ctrl or k.mods.alt or k.mods.super) {
        p.tn_count = 0;
        return false;
    }
    if (k.code == .char) switch (k.code.char) {
        '1'...'9' => |d| {
            p.tn_count = p.tn_count *| 10 +| (d - '0');
            return true;
        },
        '0' => if (p.tn_count > 0) {
            p.tn_count = p.tn_count *| 10;
            return true;
        },
        ']', '[' => |c| {
            p.bracket_pending = c == ']';
            return true;
        },
        else => {},
    };
    p.tn_count = 0;
    switch (k.code) {
        .char => |c| switch (c) {
            'i', 'a', 'I', 'A' => {
                p.term_normal = false;
                app.needs_render = true;
                return true;
            },
            // A mouse selection yanks, as `y` does in an editor's Visual.
            'y' => {
                if (!try copySelection(app, p)) app.toast("nothing is selected — drag across the text first", .{});
                return true;
            },
            else => return false,
        },
        else => return false,
    }
}

/// The pane's own scrollback keys, Shift+PageUp/PageDown/Home/End: true
/// when `k` was one and the view moved.
pub fn scrollKey(app: *App, p: *PtyPane, k: Key) bool {
    if (!k.mods.shift or k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    const rows: isize = @intCast(@max(app.pane_rows, 2));
    switch (k.code) {
        .page_up => p.scrollBy(-(rows - 1)),
        .page_down => p.scrollBy(rows - 1),
        .home => p.scrollTo(.top),
        .end => p.scrollTo(.bottom),
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// A key for the child. Shift+PageUp/PageDown/Home/End scroll the
/// scrollback instead of being sent.
pub fn feedKey(app: *App, p: *PtyPane, k: Key) void {
    if (scrollKey(app, p, k)) return;
    var buf: [16]u8 = undefined;
    const bytes = encodeKey(k, p.encoding(), &buf);
    if (bytes.len > 0) p.write(bytes);
}

/// Paste: bracketed when the child asked for it, else the text with
/// newlines as carriage returns (what a keyboard would have sent) —
/// sanitized either way (`encodePaste`).
pub fn paste(app: *App, p: *PtyPane, text: []const u8) Allocator.Error!void {
    p.write(try encodePaste(app.frame.allocator(), text, p.encoding().bracketed_paste));
}

/// The bytes a paste sends. Pasted text is data, never commands: ESC and
/// every other C0 control but tab, CR and LF (and DEL) become spaces
/// BEFORE the bracketed-paste fences go on, so an `ESC[201~` hidden in
/// copied text cannot close the bracket early and type the rest at the
/// prompt, and an embedded ^C / ^U / ^W never reaches the line
/// discipline. xterm's rule (ghostty's `input/paste.zig` strips the same
/// family); the framing and the newline conversion are ghostty's own
/// encoder's.
pub fn encodePaste(arena: Allocator, text: []const u8, bracketed: bool) Allocator.Error![]u8 {
    const copy = try arena.dupe(u8, text);
    for (copy) |*b| switch (b.*) {
        '\t', '\n', '\r' => {},
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => b.* = ' ',
        else => {},
    };
    const parts = pty.vt.input.encodePaste(copy, .{ .bracketed = bracketed });
    return std.mem.concat(arena, u8, &parts);
}

/// The wheel over a pane whose child is not tracking the mouse, in
/// ghostty's order: on the alternate screen with alternate scroll (DEC
/// 1007, on by default) the notches become ↑ / ↓ keys, `lines` of them,
/// so a pager — less, man, git's, bat — scrolls; anywhere else the
/// wheel moves the scrollback `rows` rows. (A child tracking the mouse
/// gets the reports instead, `mouse`.)
pub fn wheel(app: *App, p: *PtyPane, down: bool, rows: usize, lines: usize) void {
    app.needs_render = true;
    const session = p.session orelse return;
    const term = session.terminal();
    if (p.exit == null and term.screens.active_key == .alternate and term.modes.get(.mouse_alternate_scroll)) {
        const app_keys = term.modes.get(.cursor_keys);
        const seq: []const u8 = if (down)
            (if (app_keys) "\x1bOB" else "\x1b[B")
        else
            (if (app_keys) "\x1bOA" else "\x1b[A");
        var i: usize = 0;
        while (i < lines) : (i += 1) session.write(seq);
        return;
    }
    const delta: isize = @intCast(rows);
    p.scrollBy(if (down) delta else -delta);
}

/// A mouse event inside the pane's rect: a report to the child when it
/// tracks the mouse, else the wheel follows `wheel`'s rule.
pub fn mouse(app: *App, p: *PtyPane, m: Mouse, origin: struct { x: u16, y: u16 }) void {
    const enc = p.encoding();
    if (enc.mouse == .none) {
        switch (m.kind) {
            .scroll_up => wheel(app, p, false, 3, 3),
            .scroll_down => wheel(app, p, true, 3, 3),
            else => {},
        }
        return;
    }
    var buf: [32]u8 = undefined;
    const bytes = encodeMouse(m, m.x -| origin.x, m.y -| origin.y, enc, &buf);
    if (bytes.len > 0) p.write(bytes);
}

// ─── what the shell reports ─────────────────────────────────────────────

/// `file://host/some%20dir` → `/some dir`. OSC 7 carries a URL whose
/// host is the machine the shell runs on; the path is what a saved
/// session reopens in, so anything else (another scheme, a relative
/// path) is refused rather than guessed at.
pub fn pwdPath(arena: Allocator, url: []const u8) Allocator.Error!?[]const u8 {
    const scheme = "file://";
    if (!std.ascii.startsWithIgnoreCase(url, scheme)) return null;
    const rest = url[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const raw = rest[slash..];
    var out = try arena.alloc(u8, raw.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '%' and i + 2 < raw.len) {
            if (std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16)) |b| {
                out[n] = b;
                n += 1;
                i += 2;
                continue;
            } else |_| {}
        }
        out[n] = raw[i];
        n += 1;
    }
    return out[0..n];
}

/// `term.prev_prompt` / `term.next_prompt`: the view jumps to the
/// previous / next prompt the shell marked (OSC 133), as ghostty's
/// `jump_to_prompt` does. False when the child never marked one.
pub fn jumpPrompt(app: *App, p: *PtyPane, delta: isize) bool {
    const session = p.session orelse return false;
    const screen = session.terminal().screens.active;
    const before = screen.pages.getTopLeft(.viewport);
    screen.scroll(.{ .delta_prompt = delta });
    app.needs_render = true;
    return !screen.pages.getTopLeft(.viewport).eql(before);
}

/// The URL an OSC 8 hyperlink puts under the screen cell (`x`, `y`),
/// borrowed from the terminal; null when the cell carries none.
pub fn linkAt(p: *PtyPane, x: u16, y: u16) ?[]const u8 {
    const b = p.body;
    if (x < b.x or y < b.y or x >= b.x + b.w or y >= b.y + b.h) return null;
    const pin = pinAt(p, x, y) orelse return null;
    const page = pin.node.page();
    const cell = pin.rowAndCell().cell;
    const id = page.lookupHyperlink(cell) orelse return null;
    return page.hyperlink_set.get(page.memory, id).uri.slice(page.memory);
}

// ─── selection ──────────────────────────────────────────────────────────

/// A cell rectangle on the screen.
pub const Body = struct { x: u16 = 0, y: u16 = 0, w: u16 = 0, h: u16 = 0 };

/// A drag-select in flight: the pressed cell, tracked in the page list
/// of the screen it was pressed on (so output scrolling past keeps it on
/// its character), and the granularity the click count chose.
pub const Select = struct {
    anchor: *pty.vt.Pin,
    screen: pty.vt.ScreenSet.Key,
    generation: usize,
    unit: app_mod.SelectUnit,
};

/// What a double-click treats as the edge of a word — ghostty's default
/// `selection-word-chars`, so a path or a URL comes out whole.
const word_boundaries = [_]u21{ 0, ' ', '\t', '\'', '"', '│', '`', '|', ':', ';', ',', '(', ')', '[', ']', '{', '}', '<', '>', '$' };

/// The press still belongs to the screen on show: the child has not
/// switched screens (a pager starting, vim quitting) since.
fn anchorLive(term: *pty.vt.Terminal, s: Select) bool {
    return s.screen == term.screens.active_key and term.screens.generation(s.screen) == s.generation;
}

/// Let go of the press. The pin is untracked only while its screen is
/// the one it was tracked in; a recycled screen already freed it.
fn endGesture(p: *PtyPane) void {
    const s = p.select orelse return;
    p.select = null;
    const session = p.session orelse return;
    const term = session.terminal();
    if (term.screens.generation(s.screen) != s.generation) return;
    const screen = term.screens.get(s.screen) orelse return;
    screen.pages.untrackPin(s.anchor);
}

pub fn clearSelection(p: *PtyPane) void {
    const session = p.session orelse return;
    session.terminal().screens.active.clearSelection();
}

pub fn hasSelection(p: *const PtyPane) bool {
    const session = p.session orelse return false;
    return session.term.screens.active.selection != null;
}

/// The viewport cell under the screen position (`x`, `y`), clamped into
/// the pane so a drag past an edge still selects to that edge.
fn pinAt(p: *PtyPane, x: u16, y: u16) ?pty.vt.Pin {
    const session = p.session orelse return null;
    const b = p.body;
    if (b.w == 0 or b.h == 0) return null;
    const cx = std.math.clamp(x, b.x, b.x + b.w - 1) - b.x;
    const cy = std.math.clamp(y, b.y, b.y + b.h - 1) - b.y;
    return session.terminal().screens.active.pages.pin(.{ .viewport = .{ .x = cx, .y = cy } });
}

/// The selection `unit` makes of the one cell at `pin`: nothing for a
/// char (a click is not a selection), the word under it, its line.
fn unitAt(screen: *pty.vt.Screen, unit: app_mod.SelectUnit, pin: pty.vt.Pin) ?pty.vt.Selection {
    return switch (unit) {
        .char => null,
        .word => screen.selectWord(pin, &word_boundaries),
        .line => screen.selectLine(.{ .pin = pin }),
    };
}

/// A left press in the pane (the child is not tracking the mouse, or
/// Shift overrides it): any old selection goes, and the cell anchors a
/// drag. Two presses select the word, three the line, as in ghostty.
pub fn selectPress(app: *App, p: *PtyPane, x: u16, y: u16, clicks: u8) Allocator.Error!void {
    endGesture(p);
    clearSelection(p);
    app.needs_render = true;
    const session = p.session orelse return;
    const term = session.terminal();
    const pin = pinAt(p, x, y) orelse return;
    const screen = term.screens.active;
    const unit: app_mod.SelectUnit = switch (clicks) {
        0, 1 => .char,
        2 => .word,
        else => .line,
    };
    p.select = .{
        .anchor = try screen.pages.trackPin(pin),
        .screen = term.screens.active_key,
        .generation = term.screens.generation(term.screens.active_key),
        .unit = unit,
    };
    if (unitAt(screen, unit, pin)) |sel| try screen.select(sel);
}

/// The pointer moved with the button down: the selection runs from the
/// anchor to the cell under it, both ends included (a word or line press
/// extends by words or lines). Past the top or bottom edge the view
/// scrolls a row, so a drag can reach into the scrollback.
pub fn selectDrag(app: *App, p: *PtyPane, x: u16, y: u16) Allocator.Error!void {
    const s = p.select orelse return;
    const session = p.session orelse return;
    const term = session.terminal();
    if (!anchorLive(term, s)) return endGesture(p);
    app.needs_render = true;
    if (y < p.body.y) term.scrollViewport(.{ .delta = -1 }) else if (y >= p.body.y + p.body.h) term.scrollViewport(.{ .delta = 1 });
    const cur = pinAt(p, x, y) orelse return;
    const screen = term.screens.active;
    const anchor = s.anchor.*;
    if (s.unit == .char) {
        if (cur.eql(anchor)) return screen.clearSelection();
        return screen.select(.init(anchor, cur, false));
    }
    const a = unitAt(screen, s.unit, anchor) orelse pty.vt.Selection.init(anchor, anchor, false);
    const b = unitAt(screen, s.unit, cur) orelse pty.vt.Selection.init(cur, cur, false);
    const a_tl = a.topLeft(screen);
    const b_tl = b.topLeft(screen);
    const a_br = a.bottomRight(screen);
    const b_br = b.bottomRight(screen);
    try screen.select(.init(if (b_tl.before(a_tl)) b_tl else a_tl, if (a_br.before(b_br)) b_br else a_br, false));
}

/// The button came up: a selection that has text is copied, and stays
/// on show until a click or a key.
pub fn selectRelease(app: *App, p: *PtyPane, x: u16, y: u16) Allocator.Error!void {
    if (p.select == null) return;
    try selectDrag(app, p, x, y);
    endGesture(p);
    if (app.cfg.ui.copy_on_select) _ = try copySelection(app, p);
}

/// Ctrl+C (or Ctrl+Shift+C) over a selection is the selection's, never
/// the child's: it copies — unless `ui.copy_on_select` already did on
/// the release (Ctrl+Shift+C, the explicit copy, copies either way) —
/// lets the selection go and sends nothing. True when it took the key;
/// with no selection Ctrl+C goes on to the child as its interrupt.
pub fn selectionCopyKey(app: *App, p: *PtyPane, k: Key) Allocator.Error!bool {
    if (!k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    const c: u21 = switch (k.code) {
        .char => |c| c,
        else => return false,
    };
    if (c != 'c' and c != 'C') return false;
    if (!hasSelection(p)) return false;
    const explicit = k.mods.shift or c == 'C';
    if (explicit or !app.cfg.ui.copy_on_select) _ = try copySelection(app, p);
    clearSelection(p);
    app.needs_render = true;
    return true;
}

/// The selection's text to the clipboard: the unnamed register (a `p`
/// in an editor pastes it) and the OS clipboard, the way the standard
/// profile's copy goes (`"+`). False when nothing is selected.
pub fn copySelection(app: *App, p: *PtyPane) Allocator.Error!bool {
    const session = p.session orelse return false;
    const screen = session.terminal().screens.active;
    const sel = screen.selection orelse return false;
    const text = try screen.selectionString(app.frame.allocator(), .{ .sel = sel, .trim = true });
    if (text.len == 0) return false;
    app.clipboard.setPendingRegister('+');
    try app.clipboard.setYank(text, false);
    app.toast("copied the selection", .{});
    return true;
}

// ─── encoders ───────────────────────────────────────────────────────────

pub const MouseMode = enum { none, x10, normal, button, any };

/// What the child has switched on; both encoders read it.
pub const Encoding = struct {
    /// Kitty keyboard protocol (disambiguate or report-all) is active.
    kitty: bool = false,
    /// DECCKM: arrows as `ESC O A` instead of `CSI A`.
    cursor_keys_app: bool = false,
    bracketed_paste: bool = false,
    mouse: MouseMode = .none,
    /// SGR (1006) reports; else the X10 byte form.
    mouse_sgr: bool = false,
};

fn modParam(m: key_mod.Mods) u8 {
    var v: u8 = 1;
    if (m.shift) v += 1;
    if (m.alt) v += 2;
    if (m.ctrl) v += 4;
    if (m.super) v += 8;
    return v;
}

/// The bytes a terminal sends for `k`. Empty for keys with no encoding.
pub fn encodeKey(k: Key, enc: Encoding, buf: *[16]u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    encodeKeyInto(&w, k, enc) catch return buf[0..0];
    return w.buffered();
}

fn encodeKeyInto(w: *Io.Writer, k: Key, enc: Encoding) Io.Writer.Error!void {
    const mods = k.mods;
    const modified = mods.ctrl or mods.alt or mods.super;
    const mp = modParam(mods);
    switch (k.code) {
        .char => |c| {
            if (enc.kitty and modified) {
                // Kitty: the unshifted codepoint carries the modifiers.
                const lower: u21 = if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
                const shift_of_upper = c >= 'A' and c <= 'Z';
                var m = mods;
                if (shift_of_upper) m.shift = true;
                return w.print("\x1b[{d};{d}u", .{ lower, modParam(m) });
            }
            if (mods.alt) try w.writeByte(0x1b);
            if (mods.ctrl) {
                const lower: u21 = if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
                const ctl: ?u8 = switch (lower) {
                    'a'...'z' => @intCast(lower - 'a' + 1),
                    ' ', '@' => 0,
                    '[' => 0x1b,
                    '\\' => 0x1c,
                    ']' => 0x1d,
                    '^' => 0x1e,
                    '_', '?' => 0x1f,
                    else => null,
                };
                if (ctl) |b| return w.writeByte(b);
            }
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &utf8) catch return;
            try w.writeAll(utf8[0..n]);
        },
        .enter => {
            if (enc.kitty and mp != 1) return w.print("\x1b[13;{d}u", .{mp});
            if (mods.alt) try w.writeByte(0x1b);
            try w.writeByte('\r');
        },
        .tab => {
            if (enc.kitty and mp != 1) return w.print("\x1b[9;{d}u", .{mp});
            if (mods.alt) try w.writeByte(0x1b);
            try w.writeByte('\t');
        },
        .backtab => {
            if (enc.kitty) return w.writeAll("\x1b[9;2u");
            try w.writeAll("\x1b[Z");
        },
        .backspace => {
            if (enc.kitty and mp != 1) return w.print("\x1b[127;{d}u", .{mp});
            if (mods.alt) try w.writeByte(0x1b);
            try w.writeByte(0x7f);
        },
        .esc => {
            if (enc.kitty) return if (mp != 1) w.print("\x1b[27;{d}u", .{mp}) else w.writeAll("\x1b[27u");
            try w.writeByte(0x1b);
        },
        .up, .down, .right, .left, .home, .end => {
            const final: u8 = switch (k.code) {
                .up => 'A',
                .down => 'B',
                .right => 'C',
                .left => 'D',
                .home => 'H',
                .end => 'F',
                else => unreachable,
            };
            if (mp != 1) return w.print("\x1b[1;{d}{c}", .{ mp, final });
            // DECCKM's `ESC O` form is the legacy encoding's; under the
            // kitty protocol an arrow, Home or End is always `CSI`
            // (ghostty's `key_encode.kitty`), whatever DECCKM says.
            if (enc.cursor_keys_app and !enc.kitty) return w.print("\x1bO{c}", .{final});
            try w.print("\x1b[{c}", .{final});
        },
        .insert, .delete, .page_up, .page_down => {
            const n: u8 = switch (k.code) {
                .insert => 2,
                .delete => 3,
                .page_up => 5,
                .page_down => 6,
                else => unreachable,
            };
            if (mp != 1) return w.print("\x1b[{d};{d}~", .{ n, mp });
            try w.print("\x1b[{d}~", .{n});
        },
        .f => |n| switch (n) {
            1...4 => {
                const final: u8 = 'P' + (n - 1);
                if (mp != 1) return w.print("\x1b[1;{d}{c}", .{ mp, final });
                try w.print("\x1bO{c}", .{final});
            },
            5...12 => {
                const code: u8 = switch (n) {
                    5 => 15,
                    6 => 17,
                    7 => 18,
                    8 => 19,
                    9 => 20,
                    10 => 21,
                    11 => 23,
                    12 => 24,
                    else => unreachable,
                };
                if (mp != 1) return w.print("\x1b[{d};{d}~", .{ code, mp });
                try w.print("\x1b[{d}~", .{code});
            },
            else => {},
        },
    }
}

/// A mouse report for a cell-relative event. `x`/`y` are 0-based cells
/// inside the pane. Empty when the mode does not report this event.
pub fn encodeMouse(m: Mouse, x: u16, y: u16, enc: Encoding, buf: *[32]u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    encodeMouseInto(&w, m, x, y, enc) catch return buf[0..0];
    return w.buffered();
}

fn encodeMouseInto(w: *Io.Writer, m: Mouse, x: u16, y: u16, enc: Encoding) Io.Writer.Error!void {
    var btn: u32 = switch (m.kind) {
        .scroll_up => 64,
        .scroll_down => 65,
        else => switch (m.button) {
            .left => 0,
            .middle => 1,
            .right => 2,
            .none => 3,
        },
    };
    switch (m.kind) {
        .drag => {
            if (enc.mouse != .button and enc.mouse != .any) return;
            btn += 32;
        },
        .motion => {
            if (enc.mouse != .any) return;
            btn += 32;
        },
        .release => if (enc.mouse == .x10) return,
        .press, .scroll_up, .scroll_down => {},
    }
    if (enc.mouse != .x10) {
        if (m.mods.shift) btn += 4;
        if (m.mods.alt) btn += 8;
        if (m.mods.ctrl) btn += 16;
    }
    if (enc.mouse_sgr) {
        const final: u8 = if (m.kind == .release) 'm' else 'M';
        return w.print("\x1b[<{d};{d};{d}{c}", .{ btn, x + 1, y + 1, final });
    }
    // X10 bytes: 32 + value, cells 1-based, clamped to what fits a byte.
    const b: u8 = @intCast(32 + (if (m.kind == .release) 3 else btn));
    try w.writeAll("\x1b[M");
    try w.writeByte(b);
    try w.writeByte(@intCast(@min(32 + x + 1, 255)));
    try w.writeByte(@intCast(@min(32 + y + 1, 255)));
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn encoded(k: Key, e: Encoding) []const u8 {
    const S = struct {
        var buf: [16]u8 = undefined;
    };
    return encodeKey(k, e, &S.buf);
}

test "legacy key encoding: text, control bytes, alt prefix, arrows with and without modifiers" {
    try t.expectEqualStrings("a", encoded(Key.char('a'), .{}));
    try t.expectEqualStrings("é", encoded(Key.char('é'), .{}));
    try t.expectEqualStrings("\x03", encoded(Key.ctrl('c'), .{}));
    try t.expectEqualStrings("\x1b", encoded(Key.ctrl('['), .{}));
    try t.expectEqualStrings("\x00", encoded(Key.ctrl(' '), .{}));
    try t.expectEqualStrings("\x1bb", encoded(.{ .code = .{ .char = 'b' }, .mods = .{ .alt = true } }, .{}));
    try t.expectEqualStrings("\x1b\x02", encoded(.{ .code = .{ .char = 'b' }, .mods = .{ .alt = true, .ctrl = true } }, .{}));
    try t.expectEqualStrings("\r", encoded(Key.named(.enter), .{}));
    try t.expectEqualStrings("\x7f", encoded(Key.named(.backspace), .{}));
    try t.expectEqualStrings("\x1b[Z", encoded(Key.named(.backtab), .{}));
    try t.expectEqualStrings("\x1b", encoded(Key.named(.esc), .{}));
    try t.expectEqualStrings("\x1b[A", encoded(Key.named(.up), .{}));
    try t.expectEqualStrings("\x1bOA", encoded(Key.named(.up), .{ .cursor_keys_app = true }));
    try t.expectEqualStrings("\x1b[1;5C", encoded(.{ .code = .right, .mods = .{ .ctrl = true } }, .{}));
    try t.expectEqualStrings("\x1b[1;2H", encoded(.{ .code = .home, .mods = .{ .shift = true } }, .{}));
    try t.expectEqualStrings("\x1b[3~", encoded(Key.named(.delete), .{}));
    try t.expectEqualStrings("\x1b[5;3~", encoded(.{ .code = .page_up, .mods = .{ .alt = true } }, .{}));
    try t.expectEqualStrings("\x1bOP", encoded(Key.named(.{ .f = 1 }), .{}));
    try t.expectEqualStrings("\x1b[15~", encoded(Key.named(.{ .f = 5 }), .{}));
    try t.expectEqualStrings("\x1b[24;5~", encoded(.{ .code = .{ .f = 12 }, .mods = .{ .ctrl = true } }, .{}));
    try t.expectEqualStrings("", encoded(Key.named(.{ .f = 13 }), .{}));
}

test "the navigation keys reach the child as ghostty itself would send them, in every mode the child can ask for" {
    // PageUp / PageDown / Home / End, the arrows, Insert / Delete, bare and
    // with each modifier, against libghostty-vt's own encoder — the oracle
    // for "what does this child expect". Legacy, DECCKM, and the kitty
    // protocol with and without DECCKM (a child that turns both on gets
    // `CSI H`, not `ESC O H`).
    const gi = pty.vt.input;
    const Pair = struct { m: key_mod.KeyCode, g: gi.Key };
    const keys = [_]Pair{
        .{ .m = .page_up, .g = .page_up }, .{ .m = .page_down, .g = .page_down }, .{ .m = .home, .g = .home },
        .{ .m = .end, .g = .end },         .{ .m = .up, .g = .arrow_up },         .{ .m = .down, .g = .arrow_down },
        .{ .m = .left, .g = .arrow_left }, .{ .m = .right, .g = .arrow_right },   .{ .m = .insert, .g = .insert },
        .{ .m = .delete, .g = .delete },
    };
    const modsets = [_]key_mod.Mods{ .{}, .{ .shift = true }, .{ .ctrl = true }, .{ .alt = true }, .{ .ctrl = true, .shift = true }, .{ .ctrl = true, .alt = true } };
    const Mode = struct { enc: Encoding, opts: gi.KeyEncodeOptions };
    const modes = [_]Mode{
        .{ .enc = .{}, .opts = .{} },
        .{ .enc = .{ .cursor_keys_app = true }, .opts = .{ .cursor_key_application = true } },
        .{ .enc = .{ .kitty = true }, .opts = .{ .kitty_flags = .{ .disambiguate = true } } },
        .{ .enc = .{ .kitty = true, .cursor_keys_app = true }, .opts = .{ .cursor_key_application = true, .kitty_flags = .{ .disambiguate = true } } },
        .{ .enc = .{ .kitty = true }, .opts = .{ .kitty_flags = .{ .disambiguate = true, .report_alternates = true, .report_all = true, .report_associated = true } } },
    };
    for (modes) |md| for (keys) |kp| for (modsets) |ms| {
        var mine_buf: [16]u8 = undefined;
        const mine = encodeKey(.{ .code = kp.m, .mods = ms }, md.enc, &mine_buf);
        var theirs_buf: [64]u8 = undefined;
        var w: Io.Writer = .fixed(&theirs_buf);
        try gi.encodeKey(&w, .{ .key = kp.g, .mods = .{ .shift = ms.shift, .ctrl = ms.ctrl, .alt = ms.alt } }, md.opts);
        t.expectEqualStrings(w.buffered(), mine) catch |err| {
            std.debug.print("{t} {any} kitty={} decckm={}\n", .{ kp.m, ms, md.enc.kitty, md.enc.cursor_keys_app });
            return err;
        };
    };
}

test "kitty key encoding: CSI u for modified and ambiguous keys, plain text stays text" {
    const k: Encoding = .{ .kitty = true };
    try t.expectEqualStrings("a", encoded(Key.char('a'), k));
    try t.expectEqualStrings("A", encoded(Key.char('A'), k));
    try t.expectEqualStrings("\x1b[99;5u", encoded(Key.ctrl('c'), k));
    try t.expectEqualStrings("\x1b[99;6u", encoded(Key.ctrl('C'), k));
    try t.expectEqualStrings("\x1b[98;3u", encoded(.{ .code = .{ .char = 'b' }, .mods = .{ .alt = true } }, k));
    try t.expectEqualStrings("\x1b[27u", encoded(Key.named(.esc), k));
    try t.expectEqualStrings("\x1b[27;5u", encoded(.{ .code = .esc, .mods = .{ .ctrl = true } }, k));
    try t.expectEqualStrings("\r", encoded(Key.named(.enter), k));
    try t.expectEqualStrings("\x1b[13;2u", encoded(.{ .code = .enter, .mods = .{ .shift = true } }, k));
    try t.expectEqualStrings("\x1b[9;2u", encoded(Key.named(.backtab), k));
    try t.expectEqualStrings("\x1b[127;3u", encoded(.{ .code = .backspace, .mods = .{ .alt = true } }, k));
    try t.expectEqualStrings("\x1b[B", encoded(Key.named(.down), k));
    try t.expectEqualStrings("\x1b[1;5B", encoded(.{ .code = .down, .mods = .{ .ctrl = true } }, k));
}

test "mouse reports: SGR press/release/drag/wheel, modes gate motion, x10 bytes" {
    var buf: [32]u8 = undefined;
    const sgr_any: Encoding = .{ .mouse = .any, .mouse_sgr = true };
    try t.expectEqualStrings("\x1b[<0;5;3M", encodeMouse(.{ .x = 4, .y = 2, .kind = .press, .button = .left }, 4, 2, sgr_any, &buf));
    try t.expectEqualStrings("\x1b[<0;5;3m", encodeMouse(.{ .x = 4, .y = 2, .kind = .release, .button = .left }, 4, 2, sgr_any, &buf));
    try t.expectEqualStrings("\x1b[<32;1;1M", encodeMouse(.{ .x = 0, .y = 0, .kind = .drag, .button = .left }, 0, 0, sgr_any, &buf));
    try t.expectEqualStrings("\x1b[<35;1;1M", encodeMouse(.{ .x = 0, .y = 0, .kind = .motion }, 0, 0, sgr_any, &buf));
    try t.expectEqualStrings("\x1b[<64;1;1M", encodeMouse(.{ .x = 0, .y = 0, .kind = .scroll_up }, 0, 0, sgr_any, &buf));
    try t.expectEqualStrings("\x1b[<18;1;1M", encodeMouse(.{ .x = 0, .y = 0, .kind = .press, .button = .right, .mods = .{ .ctrl = true } }, 0, 0, sgr_any, &buf));
    // Normal mode: presses only, no motion.
    const sgr_normal: Encoding = .{ .mouse = .normal, .mouse_sgr = true };
    try t.expectEqualStrings("", encodeMouse(.{ .x = 0, .y = 0, .kind = .motion }, 0, 0, sgr_normal, &buf));
    try t.expectEqualStrings("", encodeMouse(.{ .x = 0, .y = 0, .kind = .drag, .button = .left }, 0, 0, sgr_normal, &buf));
    // Button mode reports drags, not bare motion.
    const sgr_button: Encoding = .{ .mouse = .button, .mouse_sgr = true };
    try t.expectEqualStrings("\x1b[<32;1;1M", encodeMouse(.{ .x = 0, .y = 0, .kind = .drag, .button = .left }, 0, 0, sgr_button, &buf));
    try t.expectEqualStrings("", encodeMouse(.{ .x = 0, .y = 0, .kind = .motion }, 0, 0, sgr_button, &buf));
    // X10 byte form.
    const x10: Encoding = .{ .mouse = .normal };
    try t.expectEqualStrings("\x1b[M\x20\x21\x21", encodeMouse(.{ .x = 0, .y = 0, .kind = .press, .button = .left }, 0, 0, x10, &buf));
    try t.expectEqualStrings("\x1b[M\x23\x21\x21", encodeMouse(.{ .x = 0, .y = 0, .kind = .release, .button = .left }, 0, 0, x10, &buf));
}

test "claudeTranscriptExists: the cwd is spelled as Claude Code names the directory — every byte not a letter or digit is `-`, `_` and spaces too" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "my_app v2.0");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    const cwd = try std.fs.path.join(t.allocator, &.{ root, "my_app v2.0" });
    defer t.allocator.free(cwd);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    app.sessions.home = try std.fs.path.join(t.allocator, &.{ root, "home" });
    // The fixture spells the directory by Claude Code's rule on its own,
    // so a narrower encoder in the code cannot agree with it by symmetry.
    const wide = try t.allocator.dupe(u8, cwd);
    defer t.allocator.free(wide);
    for (wide) |*c| if (!std.ascii.isAlphanumeric(c.*)) {
        c.* = '-';
    };
    // Only `/` and `.` rewritten: the old spelling, which Claude never writes.
    const narrow = try t.allocator.dupe(u8, cwd);
    defer t.allocator.free(narrow);
    for (narrow) |*c| if (c.* == '/' or c.* == '.') {
        c.* = '-';
    };
    for ([_][2][]const u8{ .{ wide, "sid-wide" }, .{ narrow, "sid-narrow" } }) |pair| {
        const dir = try std.fs.path.join(t.allocator, &.{ "home", ".claude", "projects", pair[0] });
        defer t.allocator.free(dir);
        try tmp.dir.createDirPath(t.io, dir);
        const file = try std.fmt.allocPrint(t.allocator, "{s}/{s}.jsonl", .{ dir, pair[1] });
        defer t.allocator.free(file);
        try tmp.dir.writeFile(t.io, .{ .sub_path = file, .data = "{\"type\":\"user\"}\n" });
    }
    try t.expect(claudeTranscriptExists(&app, "sid-wide", cwd));
    try t.expect(!claudeTranscriptExists(&app, "sid-narrow", cwd));
    try t.expect(!claudeTranscriptExists(&app, "sid-none", cwd));
}

test "sessionIdOfArgv reads --session-id and --resume; resumeArgv spells the first as the second; relaunchInPlace sets either; freshInPlace undoes a resume" {
    try t.expectEqualStrings("abc", sessionIdOfArgv(&.{ "claude", "--session-id", "abc" }).?);
    try t.expectEqualStrings("r1", sessionIdOfArgv(&.{ "claude", "--resume", "r1" }).?);
    try t.expect(sessionIdOfArgv(&.{"claude"}) == null);
    try t.expect(sessionIdOfArgv(&.{ "claude", "--session-id" }) == null);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const saved = try resumeArgv(arena_state.allocator(), &.{ "claude", "--session-id", "abc" });
    try t.expectEqualStrings("--resume", saved[1]);
    try t.expectEqualStrings("abc", saved[2]);
    var argv = try t.allocator.alloc([]u8, 3);
    defer {
        for (argv) |a| t.allocator.free(a);
        t.allocator.free(argv);
    }
    argv[0] = try t.allocator.dupe(u8, "claude");
    argv[1] = try t.allocator.dupe(u8, "--session-id");
    argv[2] = try t.allocator.dupe(u8, "abc");
    try relaunchInPlace(t.allocator, argv, .resume_it);
    try t.expectEqualStrings("--resume", argv[1]);
    try t.expect(isResumeArgv(@ptrCast(argv)));
    try relaunchInPlace(t.allocator, argv, .start_fresh);
    try t.expectEqualStrings("--session-id", argv[1]);
    try t.expectEqualStrings("abc", argv[2]);
    try t.expect(!isResumeArgv(@ptrCast(argv)));
    try relaunchInPlace(t.allocator, argv, .resume_it);
    try freshInPlace(t.allocator, &argv);
    try t.expectEqualStrings("--session-id", argv[1]);
    try t.expectEqual(@as(usize, 3), argv.len);

    // Codex: `resume <id>` is dropped; the options stay.
    var cdx = try t.allocator.alloc([]u8, 5);
    defer {
        for (cdx) |a| t.allocator.free(a);
        t.allocator.free(cdx);
    }
    for (cdx, [_][]const u8{ "codex", "resume", "cdx-1", "-m", "o4" }) |*c, v| c.* = try t.allocator.dupe(u8, v);
    try t.expect(isResumeArgv(@ptrCast(cdx)));
    try freshInPlace(t.allocator, &cdx);
    try t.expectEqual(@as(usize, 3), cdx.len);
    try t.expectEqualStrings("codex", cdx[0]);
    try t.expectEqualStrings("-m", cdx[1]);
    try t.expectEqualStrings("o4", cdx[2]);
    try t.expect(!isResumeArgv(@ptrCast(cdx)));
}

test "childOwned: ctrl+c/d/z/l only" {
    try t.expect(childOwned(Key.ctrl('c')));
    try t.expect(childOwned(Key.ctrl('l')));
    try t.expect(!childOwned(Key.ctrl('p')));
    try t.expect(!childOwned(Key.char('c')));
    try t.expect(!childOwned(.{ .code = .{ .char = 'c' }, .mods = .{ .ctrl = true, .alt = true } }));
}

// ─── the pane end to end ───────────────────────────────────────────────

const screen_mod = @import("../ipc/screen.zig");
const Rect = @import("../ui/rect.zig");

/// Tick + render until `needle` is on screen or `ms` elapse.
/// Tick until `needle` is on screen `n` times: for output that arrives
/// in pieces, the first piece is not the state the test asserts on.
fn tickUntilScreenCount(app: *App, needle: []const u8, n: usize, ms: u32) !bool {
    var waited: u32 = 0;
    while (waited <= ms) : (waited += 10) {
        try app.tick(App.nowMs(app.io));
        try app.render();
        const txt = try screen_mod.toTestText(app.gpa, &app.screen);
        defer app.gpa.free(txt);
        if (std.mem.count(u8, txt, needle) >= n) return true;
        app.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

/// Tick until the child has switched the pane's input encoding to
/// bracketed paste (state, not a beat of wall time); the deadline only
/// fails.
fn tickUntilBracketedPaste(app: *App, id: PaneId, ms: u32) !bool {
    var waited: u32 = 0;
    while (waited <= ms) : (waited += 10) {
        try app.tick(App.nowMs(app.io));
        if (app.panes.pty(id).?.encoding().bracketed_paste) return true;
        app.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

pub fn tickUntilScreen(app: *App, needle: []const u8, ms: u32) !bool {
    var waited: u32 = 0;
    while (waited <= ms) : (waited += 10) {
        try app.tick(App.nowMs(app.io));
        try app.render();
        const txt = try screen_mod.toTestText(app.gpa, &app.screen);
        defer app.gpa.free(txt);
        if (std.mem.indexOf(u8, txt, needle) != null) return true;
        app.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

test "a scripted child's coloured line reaches the cells, the exit is noticed, a key then closes the pane" {
    // A POSIX shell script drives this one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    const id = try open(&app, .{
        .argv = &.{ "/bin/sh", "-c", "printf '\\033[32mgreen\\033[0m plain\\n'; exit 4" },
        .label = "script",
        .kind = .command,
    });
    try t.expectEqual(id, app.active.?);
    try t.expectEqualStrings("script", app.panes.get(id).?.title());
    try t.expect(try tickUntilScreen(&app, "green plain", 5000));
    // The "g" of "green" carries palette 2; "plain" does not.
    var found = false;
    var y: u16 = 0;
    while (y < 12 and !found) : (y += 1) {
        var x: u16 = 0;
        while (x < 60) : (x += 1) {
            const cell = app.screen.readCell(x, y) orelse continue;
            if (std.mem.eql(u8, cell.char.grapheme, "g")) {
                try t.expectEqual(@as(u8, 2), cell.style.fg.index);
                const p = app.screen.readCell(x + 6, y).?;
                try t.expectEqualStrings("p", p.char.grapheme);
                try t.expect(p.style.fg != .index);
                found = true;
                break;
            }
        }
    }
    try t.expect(found);
    try t.expect(try tickUntilScreen(&app, "[exited 4]", 5000));
    try t.expectEqual(Exit{ .code = 4 }, app.panes.pty(id).?.exit.?);
    // Enter closes an exited pane.
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.panes.get(id) == null);
    try t.expect(app.active == null);
}

test "an exited pane stays for reading back: its scroll keys scroll, a letter or the vim leader leaves it, Enter or Esc closes it" {
    // A POSIX shell script drives this one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    try app.setInputStyle(.vim);
    const id = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "seq 1 300" }, .label = "seq" });
    try t.expect(try tickUntilScreen(&app, "[exited 0]", 5000));
    try app.handle(.{ .key = .{ .code = .page_up, .mods = .{ .shift = true } } });
    try t.expect(app.panes.get(id) != null);
    try app.render();
    const txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "300") == null);
    try app.handle(.{ .key = .{ .code = .home, .mods = .{ .shift = true } } });
    try t.expect(try tickUntilScreen(&app, "▌1 ", 2000));
    try app.handle(.{ .key = Key.char('x') });
    try t.expect(app.panes.get(id) != null);
    try app.handle(.{ .key = Key.char(' ') });
    try t.expect(app.panes.get(id) != null);
    // Esc lets go of the leader, the next one closes the pane.
    try app.handle(.{ .key = Key.named(.esc) });
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.panes.get(id) == null);
}

test "keys reach the child: typed text and ctrl+d end a cat that echoes back" {
    // A POSIX shell script drives this one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    const id = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "stty -echo; echo ready; cat | tr a-z A-Z" }, .label = "cat" });
    // The tty is set up (echo off) once the child says so; then type.
    try t.expect(try tickUntilScreen(&app, "ready", 5000));
    for ("shout") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(try tickUntilScreen(&app, "SHOUT", 5000));
    // What was typed reached the child and only the child: no echo.
    const txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "shout") == null);
    try app.handle(.{ .key = Key.ctrl('d') });
    try t.expect(try tickUntilScreen(&app, "[exited 0]", 5000));
    try t.expect(app.panes.pty(id).?.exit.?.ok());
}

test "PageUp / PageDown / Home / End and their Ctrl forms reach the child in both profiles; Shift+ them stay the pane's scrollback" {
    // A POSIX shell script drives this one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    for ([_]@import("../input/mod.zig").Style{ .vim, .standard }) |style| {
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
        defer app.deinit();
        app.tree.visible = false;
        try app.setInputStyle(style);
        _ = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "stty -echo -icanon; echo ready; cat -v" }, .label = "catv" });
        try t.expect(try tickUntilScreen(&app, "ready", 5000));
        for ([_]Key{
            Key.named(.page_up),                               Key.named(.page_down),
            Key.named(.home),                                  Key.named(.end),
            .{ .code = .home, .mods = .{ .ctrl = true } },     .{ .code = .end, .mods = .{ .ctrl = true } },
            .{ .code = .page_up, .mods = .{ .shift = true } }, .{ .code = .home, .mods = .{ .shift = true } },
        }) |k| try app.handle(.{ .key = k });
        try app.handle(.{ .key = Key.named(.enter) });
        // The Shift forms scrolled mnml's view and sent nothing.
        try t.expect(try tickUntilScreen(&app, "▌^[[5~^[[6~^[[H^[[F^[[1;5H^[[1;5F ", 5000));
    }
}

/// A `cat -v` child with a line to select: the key tests below read what
/// reached it back off the screen.
fn openSelectable(app: *App, style: @import("../input/mod.zig").Style) !*PtyPane {
    app.tree.visible = false;
    try app.setInputStyle(style);
    const id = try open(app, .{ .argv = &.{ "/bin/sh", "-c", "stty -echo -icanon -isig; echo 'ready SELECTME'; cat -v" }, .label = "sel" });
    try t.expect(try tickUntilScreen(app, "ready SELECTME", 5000));
    return app.panes.pty(id).?;
}

/// Tick until the child has read everything typed so far: a Ctrl+C
/// discards input the child has not read yet (`Session.interrupt`), so a
/// key sequence that must arrive whole waits for each key to land.
fn drained(app: *App, p: *PtyPane) !void {
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 5) {
        try app.tick(App.nowMs(app.io));
        if (p.session.?.pendingInput() == 0) return;
        app.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

/// Drag across `SELECTME` (cells 6..13 of the child's first line).
fn dragSelectMe(app: *App, p: *PtyPane) !void {
    const b = p.body;
    for ([_]struct { x: u16, kind: key_mod.MouseKind }{ .{ .x = 6, .kind = .press }, .{ .x = 13, .kind = .drag }, .{ .x = 13, .kind = .release } }) |ev|
        try app.handle(.{ .mouse = .{ .x = b.x + ev.x, .y = b.y, .kind = ev.kind, .button = .left } });
}

test "Ctrl+C over a selection, copy on select ON: the release copied, Ctrl+C lets the selection go and sends nothing; with none it is ^C" {
    // A POSIX shell script drives this one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    for ([_]@import("../input/mod.zig").Style{ .vim, .standard }) |style| {
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
        defer app.deinit();
        try t.expect(app.cfg.ui.copy_on_select);
        const p = try openSelectable(&app, style);
        try dragSelectMe(&app, p);
        try t.expectEqualStrings("SELECTME", app.clipboard.text());
        try t.expect(hasSelection(p));
        try app.clipboard.setYank("elsewhere", false);
        try app.handle(.{ .key = Key.ctrl('c') });
        try t.expect(!hasSelection(p));
        // Not copied a second time: the clipboard keeps what came after.
        try t.expectEqualStrings("elsewhere", app.clipboard.text());
        try app.handle(.{ .key = Key.char('a') });
        try drained(&app, p);
        try app.handle(.{ .key = Key.ctrl('c') });
        try drained(&app, p);
        try app.handle(.{ .key = Key.char('b') });
        try app.handle(.{ .key = Key.named(.enter) });
        // Only the second Ctrl+C reached the child, as 0x03 (`cat -v`'s ^C).
        try t.expect(try tickUntilScreen(&app, "▌a^Cb ", 5000));
    }
}

test "Ctrl+C over a selection, copy on select OFF: the release only selects, Ctrl+C copies, lets go and sends nothing; Ctrl+Shift+C copies too" {
    // A POSIX shell script drives this one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    for ([_]@import("../input/mod.zig").Style{ .vim, .standard }) |style| {
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
        defer app.deinit();
        app.cfg.ui.copy_on_select = false;
        const p = try openSelectable(&app, style);
        try app.clipboard.setYank("before", false);
        try dragSelectMe(&app, p);
        try t.expect(hasSelection(p));
        try t.expectEqualStrings("before", app.clipboard.text());
        try app.handle(.{ .key = Key.ctrl('c') });
        try t.expect(!hasSelection(p));
        try t.expectEqualStrings("SELECTME", app.clipboard.text());
        // Ctrl+Shift+C is the explicit copy: it copies over a selection
        // whatever the setting, and sends nothing either.
        try app.clipboard.setYank("before", false);
        try dragSelectMe(&app, p);
        try app.handle(.{ .key = .{ .code = .{ .char = 'c' }, .mods = .{ .ctrl = true, .shift = true } } });
        try t.expect(!hasSelection(p));
        try t.expectEqualStrings("SELECTME", app.clipboard.text());
        try app.handle(.{ .key = Key.char('a') });
        try drained(&app, p);
        try app.handle(.{ .key = Key.ctrl('c') });
        try drained(&app, p);
        try app.handle(.{ .key = Key.char('b') });
        try app.handle(.{ .key = Key.named(.enter) });
        try t.expect(try tickUntilScreen(&app, "▌a^Cb ", 5000));
    }
}

test "vim: <C-\\><C-n> leaves the child for terminal-normal, where the leader and Ctrl-W work and i returns; <C-x> too; a lone <C-\\> reaches the child" {
    // A POSIX shell script drives this one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    // `-isig`: a `Ctrl-\` that reaches the child is a byte, not SIGQUIT;
    // `tr` paints it as `#`.
    const id = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "stty -echo -isig; echo ready; cat | tr '\\034a-z' '#A-Z'" }, .label = "cat" });
    try t.expect(try tickUntilScreen(&app, "ready", 5000));
    const p = app.panes.pty(id).?;
    // Terminal mode: `space v` is the child's, not the leader's.
    for (" v") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(try tickUntilScreen(&app, " V", 5000));
    try t.expectEqual(@as(usize, 1), (try app.layouts.current().leaves(app.frame.allocator())).len);
    // `<C-\><C-n>`: terminal-normal. Nothing typed reaches the child now.
    try app.handle(.{ .key = Key.ctrl('\\') });
    try t.expect(p.ctrl_backslash_pending and !p.term_normal);
    try app.handle(.{ .key = Key.ctrl('n') });
    try t.expect(p.term_normal);
    try t.expectEqualStrings("T-NORMAL", statusline.modeOf(&app).label);
    for ("xyz") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(!(try tickUntilScreen(&app, "XYZ", 300)));
    // The leader works: `space v` splits a second shell to the right.
    try app.handle(.{ .key = Key.char(' ') });
    try app.handle(.{ .key = Key.char('v') });
    try t.expectEqual(@as(usize, 2), (try app.layouts.current().leaves(app.frame.allocator())).len);
    // The new shell opens in terminal mode (as Neovim's does): NvChad's
    // `<C-x>` escapes it, then `Ctrl-W h` goes back to the cat pane;
    // `i` there re-enters terminal mode.
    try t.expect(app.active.? != id);
    try app.handle(.{ .key = Key.ctrl('x') });
    try t.expect(app.panes.pty(app.active.?).?.term_normal);
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('h') });
    try t.expectEqual(id, app.active.?);
    try app.handle(.{ .key = Key.char('i') });
    try t.expect(!p.term_normal);
    try t.expectEqualStrings("TERMINAL", statusline.modeOf(&app).label);
    for ("abc") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(try tickUntilScreen(&app, "ABC", 5000));
    // NvChad's `<C-x>` is the same door; `a` is the way back too.
    try app.handle(.{ .key = Key.ctrl('x') });
    try t.expect(p.term_normal);
    try app.handle(.{ .key = Key.char('a') });
    try t.expect(!p.term_normal);
    // A `Ctrl-\` followed by anything else is sent on to the child
    // with that key: the child sees both bytes (`#`, then `Q`).
    try app.handle(.{ .key = Key.ctrl('\\') });
    try t.expect(p.ctrl_backslash_pending);
    try app.handle(.{ .key = Key.char('q') });
    try t.expect(!p.ctrl_backslash_pending and !p.term_normal);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(try tickUntilScreen(&app, "#Q", 5000));
}

test "encodePaste: ESC and the tty controls become spaces before the fences go on; tab, CR and LF survive" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The paste-jacking payload: a fence closer, then a command line.
    const evil = "echo harmless\x1b[201~\necho PWNED > pwned.txt\n";
    const out = try encodePaste(arena, evil, true);
    try t.expectEqualStrings("\x1b[200~echo harmless [201~\necho PWNED > pwned.txt\n\x1b[201~", out);
    // Exactly one closer, and it is the last thing sent.
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\x1b[201~"));
    // ^C ^U ^W ^Z NUL DEL are spaces — and ^A, which xterm's own list
    // leaves alone and readline reads as "start of line"; tab is kept.
    try t.expectEqualStrings("\x1b[200~a b c d e f g\th\x1b[201~", try encodePaste(arena, "a\x03b\x15c\x17d\x1ae\x00f\x01g\th", true));
    // Unbracketed: the same strip, and LF as CR.
    try t.expectEqualStrings("one\rtwo  x\r", try encodePaste(arena, "one\ntwo\x1b\x03x\n", false));
}

test "paste is bracketed only when the child asked; a newline becomes a carriage return otherwise" {
    // A POSIX shell script drives this one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    // The child switches bracketed paste on, then dumps what it reads as octal.
    const id = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "stty raw -echo; printf '\\033[?2004h'; dd bs=1 count=12 2>/dev/null | od -An -c" }, .label = "od" });
    try t.expect(try tickUntilBracketedPaste(&app, id, 5000));
    try t.expect(app.panes.pty(id).?.encoding().bracketed_paste);
    const text = try app.gpa.dupe(u8, "ab");
    try app.handle(.{ .paste = text });
    try t.expect(try tickUntilScreen(&app, "2   0   0   ~   a   b", 5000));
}

test "selecting in a terminal pane: a drag copies the cells it crossed (a wide char whole), two clicks a word, three the line; a key lets go" {
    // A POSIX shell script drives this one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    const id = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "printf 'COPYME-alpha-beta \\344\\275\\240\\345\\245\\275 end\\n'; sleep 30" }, .label = "sel" });
    try t.expect(try tickUntilScreen(&app, "COPYME-alpha-beta", 5000));
    const p = app.panes.pty(id).?;
    const b = p.body;
    try t.expect(b.w > 0);
    const row = b.y; // the line the child printed
    const press = struct {
        fn at(a: *App, x: u16, y: u16, kind: key_mod.MouseKind) !void {
            try a.handle(.{ .mouse = .{ .x = x, .y = y, .kind = kind, .button = .left } });
        }
    }.at;
    // Cells 0..16 are `COPYME-alpha-beta`; 18..21 the two wide chars.
    try press(&app, b.x, row, .press);
    try press(&app, b.x + 21, row, .drag);
    try press(&app, b.x + 21, row, .release);
    try t.expect(app.drag == null);
    try t.expectEqualStrings("COPYME-alpha-beta \u{4f60}\u{597d}", app.clipboard.text());
    // The painted cells carry the selection's ground.
    try app.render();
    try t.expect(p.grid.rowSelection(0) != null);
    try t.expectEqual(app.theme.selection.bg, app.screen.readCell(b.x + 3, row).?.style.bg);

    // A press elsewhere lets it go; a second one on the spot is a word.
    app.now_ms += 5000;
    try press(&app, b.x + 8, row, .press);
    try press(&app, b.x + 8, row, .release);
    try press(&app, b.x + 8, row, .press);
    try press(&app, b.x + 8, row, .release);
    try t.expectEqualStrings("COPYME-alpha-beta", app.clipboard.text());
    // A third is the line.
    try press(&app, b.x + 8, row, .press);
    try press(&app, b.x + 8, row, .release);
    try t.expectEqualStrings("COPYME-alpha-beta \u{4f60}\u{597d} end", app.clipboard.text());
    try t.expect(hasSelection(p));
    // A key for the child lets go of it.
    try app.handle(.{ .key = Key.char('x') });
    try t.expect(!hasSelection(p));
}

test "pwdPath: OSC 7's file URL to a path, percent escapes decoded; anything else refused" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expectEqualStrings("/Users/me/deep dir/sub", (try pwdPath(arena, "file://my-mac.local/Users/me/deep%20dir/sub")).?);
    try t.expectEqualStrings("/tmp", (try pwdPath(arena, "file:///tmp")).?);
    try t.expect(try pwdPath(arena, "kitty-shell-cwd://host/tmp") == null);
    try t.expect(try pwdPath(arena, "file://host-only") == null);
}

test "what a shell reports: OSC 7 is the pane's live cwd, OSC 133 prompts are jumped between, an OSC 8 link is found under its cell" {
    // A POSIX shell script drives this one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    const script =
        \\printf '\033]8;;https://example.com/x\033\\link\033]8;;\033\\\n'
        \\printf '\033]7;file://h/tmp/some%%20where\007'
        \\printf '\033]133;A\007$ one\n\033]133;C\007'; seq 1 40
        \\printf '\033]133;A\007$ two\n\033]133;C\007'; seq 41 80
        \\echo done; sleep 30
    ;
    const id = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", script }, .label = "report" });
    // Each prompt line is followed by the output mark (133;C) a shell
    // sends: a prompt left open is cleared on resize for the shell to
    // redraw (`shell_redraws_prompt`), and printf redraws nothing.
    try t.expect(try tickUntilScreen(&app, "done", 5000));
    const p = app.panes.pty(id).?;
    try t.expectEqualStrings("/tmp/some where", (try p.liveCwd(app.frame.allocator())).?);
    // Up to "$ two", then to "$ one"; a third jump has nowhere to go.
    try t.expect(jumpPrompt(&app, p, -1));
    try t.expect(try tickUntilScreen(&app, "$ two", 1000));
    try t.expect(jumpPrompt(&app, p, -1));
    try t.expect(try tickUntilScreen(&app, "$ one", 1000));
    // At the top the link line is in view again.
    p.scrollTo(.top);
    try app.render();
    try t.expectEqualStrings("https://example.com/x", linkAt(p, p.body.x + 1, p.body.y).?);
    try t.expect(linkAt(p, p.body.x + 6, p.body.y) == null);
}

test "focus reports: a child that enabled DEC 1004 hears ESC [ O when its pane loses the focus and ESC [ I when it comes back" {
    // A POSIX shell script drives this one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 16 });
    defer app.deinit();
    app.tree.visible = false;
    const ed = try app.openScratch();
    const id = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "stty raw -echo; printf '\\033[?1004h'; echo ready; dd bs=1 count=6 2>/dev/null | od -An -c; sleep 30" }, .label = "focus" });
    // The child's `ESC [?1004h` is pumped BEFORE the first tick — the
    // order a slow first frame gives. The pane was focused from the
    // spawn, so that tick owes the child nothing: a phantom `ESC [ I`
    // would eat half of what `dd` reads.
    var waited: u32 = 0;
    while (!app.panes.pty(id).?.session.?.terminal().modes.get(.focus_event)) : (waited += 10) {
        if (waited > 5000) return error.TestUnexpectedResult;
        onReadable(&app, id);
        app.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(try tickUntilScreen(&app, "ready", 5000));
    app.showPane(ed);
    try app.tick(App.nowMs(app.io));
    app.showPane(id);
    try t.expect(try tickUntilScreen(&app, "033   [   O 033   [   I", 5000));
}

test "the wheel over a pager: on the alternate screen with no mouse tracking the notches reach the child as arrow keys" {
    // A POSIX shell script drives this one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    // What less does: the alternate screen, no mouse mode. The child
    // dumps the next six bytes it reads as octal.
    const id = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "printf '\\033[?1049h'; stty raw -echo; echo ready; dd bs=1 count=6 2>/dev/null | od -An -c; sleep 30" }, .label = "pager" });
    try t.expect(try tickUntilScreen(&app, "ready", 5000));
    try t.expect(app.panes.pty(id).?.encoding().mouse == .none);
    var rect: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .pane and h.target.pane == id) {
        rect = h.rect;
    };
    const r = rect.?;
    app.now_ms += 1000;
    try app.handle(.{ .mouse = .{ .x = r.x + 5, .y = r.y + 3, .kind = .scroll_down } });
    try t.expect(try tickUntilScreen(&app, "033   [   B 033   [   B", 5000));
}

test "the wheel over a pty: a child tracking the mouse gets every event of a batch as its report; one that is not scrolls the scrollback a line per event" {
    // A POSIX shell script drives this one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    // The child asks for every motion (1003) in SGR form; the tty's
    // echo (ECHOCTL) then paints what the child is sent, so the
    // reports read back on the screen as `^[[<65;…`.
    const id = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "printf '\\033[?1003h\\033[?1006h'; echo ready; sleep 30" }, .label = "track" });
    try t.expect(try tickUntilScreen(&app, "ready", 5000));
    try t.expect(app.panes.pty(id).?.encoding().mouse == .any);
    var rect: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .pane and h.target.pane == id) {
        rect = h.rect;
    };
    const r = rect.?;
    app.now_ms += 1000;
    for (0..3) |_| try app.handle(.{ .mouse = .{ .x = r.x + 5, .y = r.y + 3, .kind = .scroll_down } });
    try app.tick(app.now_ms);
    // All three echoes, not the first: they can arrive in pieces.
    try t.expect(try tickUntilScreenCount(&app, "<65;", 3, 5000));
    const txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expectEqual(@as(usize, 3), std.mem.count(u8, txt, "<65;"));
    // A child that does not track: the wheel scrolls the scrollback,
    // a line per event — five events up show five earlier lines.
    const id2 = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "seq 1 100; sleep 30" }, .label = "seq" });
    try t.expect(try tickUntilScreen(&app, "100", 5000));
    try t.expect(app.panes.pty(id2).?.encoding().mouse == .none);
    var rect2: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .pane and h.target.pane == id2) {
        rect2 = h.rect;
    };
    const r2 = rect2.?;
    app.now_ms += 1000;
    for (0..5) |_| try app.handle(.{ .mouse = .{ .x = r2.x + 5, .y = r2.y + 3, .kind = .scroll_up } });
    try app.tick(app.now_ms);
    try app.render();
    const txt2 = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt2);
    // The split's three rows held 98..100; five lines up they hold 93..95.
    try t.expect(std.mem.indexOf(u8, txt2, "100") == null);
    try t.expect(std.mem.indexOf(u8, txt2, "95") != null);
}

// ─── the accent (colors) ───────────────────────────────────────────────

const Config = @import("../config/Config.zig");
const font_scan = @import("font_scan.zig");
const pty_view = @import("../ui/pty_view.zig");
const TestRect = @import("../ui/rect.zig");
var color_profiles = [_]Config.LaunchProfile{.{ .name = "t", .product = .claude, .binary = "claude" }};

/// A Claude launch-profile shim on disk — `mnml-ai-t`, a script that
/// sleeps — so a pane opened on it is a Claude session to
/// `isProductArgv` without a real `claude` on PATH.
fn writeClaudeShim(dir: std.Io.Dir, root: []const u8) ![]u8 {
    try dir.writeFile(t.io, .{ .sub_path = "mnml-ai-t", .data = "#!/bin/sh\nsleep 30\n" });
    const path = try std.fs.path.join(t.allocator, &.{ root, "mnml-ai-t" });
    errdefer t.allocator.free(path);
    const res = try std.process.run(t.allocator, t.io, .{ .argv = &.{ "chmod", "+x", path } });
    t.allocator.free(res.stdout);
    t.allocator.free(res.stderr);
    return path;
}

/// The pane's rect and its tab's, from the hit map of the last frame.
const Rects = struct { pane: ?TestRect = null, tab: ?TestRect = null };

fn rectsOf(app: *App, id: PaneId) Rects {
    var out: Rects = .{};
    for (app.hits.items.items) |h| switch (h.target) {
        .pane => |p| if (p == id) {
            out.pane = h.rect;
        },
        .tab => |tb| {
            const leaf = app.layouts.current().leaf(tb.leaf) orelse continue;
            if (tb.idx < leaf.tabs.items.len and leaf.tabs.items[tb.idx] == id) out.tab = h.rect;
        },
        else => {},
    };
    return out;
}

test "the accent: the first Claude pane opens in Claude's orange and the first shell in white, every further pane takes the first free ladder slot; the user's pick wins, Auto re-asks the rule, an unknown name is ignored" {
    // A POSIX shell script stands in for the CLI.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const shim = try writeClaudeShim(tmp.dir, root);
    defer t.allocator.free(shim);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 80, .rows = 20 });
    defer app.deinit();
    app.cfg.ai.launch_profiles = &color_profiles;
    app.tree.visible = false;
    const c1 = try open(&app, .{ .argv = &.{shim}, .label = "claude", .kind = .command, .placement = .tab });
    const c2 = try open(&app, .{ .argv = &.{shim}, .label = "claude", .kind = .command, .placement = .tab });
    const sh = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" }, .label = "sh", .kind = .command, .placement = .tab });
    const c3 = try open(&app, .{ .argv = &.{shim}, .label = "claude", .kind = .command, .placement = .tab });
    // // changed (accent-defaults): the first of a kind opens in its
    // kind's colour — Claude's orange, a terminal's white — and every
    // further pane takes the ladder in its order, so two terminals
    // open at once are never the same colour.
    try t.expectEqualStrings(accent_color.claude_orange, app.panes.pty(c1).?.accent_color.?);
    try t.expectEqualStrings("green", app.panes.pty(c2).?.accent_color.?);
    try t.expectEqualStrings(accent_color.white, app.panes.pty(sh).?.accent_color.?);
    try t.expectEqualStrings("blue", app.panes.pty(c3).?.accent_color.?);
    try t.expect(productOf(&app, app.panes.pty(c1).?) == .claude);
    try t.expect(productOf(&app, app.panes.pty(sh).?) == null);
    try t.expect(Theme.Color.eql(accentOf(&app, app.panes.pty(sh).?, &app.theme).?, app.theme.palette.fg));
    try t.expect(Theme.Color.eql(accentOf(&app, app.panes.pty(c1).?, &app.theme).?, claude_brand));
    try t.expect(Theme.Color.eql(accentOf(&app, app.panes.pty(c2).?, &app.theme).?, app.theme.palette.green));
    // The user's pick wins; Auto gives the pane the first colour
    // nobody else is wearing (green is free the moment it lets go of
    // it, and the orange is c1's); an unknown name changes nothing.
    try setAccent(&app, c2, "red");
    try t.expectEqualStrings("red", app.panes.pty(c2).?.accent_color.?);
    try t.expect(Theme.Color.eql(accentOf(&app, app.panes.pty(c2).?, &app.theme).?, app.theme.palette.red));
    try setAccent(&app, c2, "mauve");
    try t.expectEqualStrings("red", app.panes.pty(c2).?.accent_color.?);
    try setAccent(&app, c2, accent_color.none);
    try t.expectEqualStrings("green", app.panes.pty(c2).?.accent_color.?);
    // A shell takes a pick like any other pane, and Auto asks the rule
    // again: it is the only shell, so it is white again.
    try setAccent(&app, sh, "pink");
    try t.expectEqualStrings("pink", app.panes.pty(sh).?.accent_color.?);
    try setAccent(&app, sh, accent_color.none);
    try t.expectEqualStrings(accent_color.white, app.panes.pty(sh).?.accent_color.?);
    // Opening with a remembered colour keeps it over the rule; a bogus
    // one goes through the rule — the orange is worn, so the ladder.
    const c4 = try open(&app, .{ .argv = &.{shim}, .label = "claude", .kind = .command, .placement = .tab, .accent_color = "purple" });
    try t.expectEqualStrings("purple", app.panes.pty(c4).?.accent_color.?);
    const c5 = try open(&app, .{ .argv = &.{shim}, .label = "claude", .kind = .command, .placement = .tab, .accent_color = "bogus" });
    try t.expectEqualStrings("yellow", app.panes.pty(c5).?.accent_color.?);
    // A closed pane gives its colour back: the next pane to open takes it.
    try app.closePane(c5, true);
    const c6 = try open(&app, .{ .argv = &.{shim}, .label = "claude", .kind = .command, .placement = .tab });
    try t.expectEqualStrings("yellow", app.panes.pty(c6).?.accent_color.?);
    // And the first Claude pane closing frees the orange: the next
    // Claude pane is the first again and takes it, while a shell that
    // opens beside it — the white one still open — takes the ladder.
    try app.closePane(c1, true);
    const c7 = try open(&app, .{ .argv = &.{shim}, .label = "claude", .kind = .command, .placement = .tab });
    try t.expectEqualStrings(accent_color.claude_orange, app.panes.pty(c7).?.accent_color.?);
    const sh2 = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" }, .label = "sh", .kind = .command, .placement = .tab });
    try t.expectEqualStrings("orange", app.panes.pty(sh2).?.accent_color.?);
}

test "the pane rail: a pane's left column is the `▌` in its accent, its grid is a cell narrower, and its tab glyph is the same colour — a shell's too" {
    // A POSIX shell script stands in for the CLI.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const shim = try writeClaudeShim(tmp.dir, root);
    defer t.allocator.free(shim);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 80, .rows = 20 });
    defer app.deinit();
    // A narrow screen with the column docked: this test is about
    // what sits beside it, not the width rule (`ui.sidebar_auto_below`).
    app.cfg.ui.sidebar_auto_below = 0;
    app.cfg.ai.launch_profiles = &color_profiles;
    app.tree.visible = false;
    const c1 = try open(&app, .{ .argv = &.{shim}, .label = "claude", .kind = .command, .placement = .tab });
    try setAccent(&app, c1, "blue");
    try app.render();
    const r1 = rectsOf(&app, c1);
    const pane = r1.pane orelse return error.TestUnexpectedResult;
    // The pane's hit covers its tab strip too: the strip's first row is
    // the body's first, and it runs to the pane's last.
    const bar = app.screen.readCell(pane.x, pane.y + 1).?;
    try t.expectEqualStrings("\u{258c}", bar.char.grapheme);
    try t.expect(Theme.Color.eql(bar.style.fg, app.theme.palette.blue));
    const bar_low = app.screen.readCell(pane.x, pane.y + pane.h - 1).?;
    try t.expectEqualStrings("\u{258c}", bar_low.char.grapheme);
    try t.expect(Theme.Color.eql(bar_low.style.fg, app.theme.palette.blue));
    // The child's grid is one cell narrower than the pane.
    try t.expectEqual(pane.w - 1, app.panes.pty(c1).?.cols);
    // The tab's glyph, at the chip's second cell, carries the accent.
    const tab = r1.tab orelse return error.TestUnexpectedResult;
    const glyph = app.screen.readCell(tab.x + 1, tab.y).?;
    try t.expect(Theme.Color.eql(glyph.style.fg, app.theme.palette.blue));
    // // changed (pane-rail): a shell wears one too, in the slot it
    // took when it opened — that is the whole point, two terminals you
    // can tell apart. Its grid is a cell narrower, like the session's.
    const sh = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" }, .label = "sh", .kind = .command, .placement = .tab });
    try app.render();
    const r2 = rectsOf(&app, sh);
    const pane2 = r2.pane orelse return error.TestUnexpectedResult;
    const shell_accent = accentOf(&app, app.panes.pty(sh).?, &app.theme) orelse return error.TestUnexpectedResult;
    try t.expect(!Theme.Color.eql(shell_accent, app.theme.palette.blue));
    var yy: u16 = pane2.y + 1;
    while (yy < pane2.y + pane2.h) : (yy += 1) {
        const edge = app.screen.readCell(pane2.x, yy).?;
        try t.expectEqualStrings("\u{258c}", edge.char.grapheme);
        try t.expect(Theme.Color.eql(edge.style.fg, shell_accent));
    }
    try t.expectEqual(pane2.w - 1, app.panes.pty(sh).?.cols);
    const tab2 = r2.tab orelse return error.TestUnexpectedResult;
    const glyph2 = app.screen.readCell(tab2.x + 1, tab2.y).?;
    try t.expect(Theme.Color.eql(glyph2.style.fg, shell_accent));
}

test "a shell pane reads `<terminal> (<shell>)`; its tab wears mnml's own terminal mark, and so does a command pane" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 120, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    // The shell's name is the binary's base, the Windows suffix off.
    try app.env.put("SHELL", "/usr/local/bin/zsh");
    try t.expectEqualStrings("zsh", shellName(&app));
    try app.env.put("SHELL", "/opt/PowerShell/pwsh.exe");
    try t.expectEqualStrings("pwsh", shellName(&app));
    // The terminal is the one `$TERM_PROGRAM` names.
    try app.env.put("TERM_PROGRAM", "ghostty");
    try t.expectEqualStrings("ghostty", hostTerminalName(&app));
    // A shell pane's label is the pair; the tab's mark is mnml's own,
    // not the emulator's. // changed (pane-rail): a shell takes a slot
    // off the ladder like every other pane, so its mark is tinted —
    // the first terminal open wears white (accent-defaults).
    try app.env.put("SHELL", "/bin/sh");
    const sh = try open(&app, .{ .placement = .tab });
    try t.expectEqualStrings("ghostty (sh)", app.panes.pty(sh).?.label);
    try t.expect(Theme.Color.eql(accentOf(&app, app.panes.pty(sh).?, &app.theme).?, app.theme.palette.fg));
    try app.render();
    const tab = (rectsOf(&app, sh)).tab orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings(bufferline.ghost_glyph, app.screen.readCell(tab.x + 1, tab.y).?.char.grapheme);
    // An unknown terminal changes the label, never the mark; a command
    // pane wears the same mark a shell does.
    try app.env.put("TERM_PROGRAM", "Hyper");
    const sh2 = try open(&app, .{ .placement = .tab });
    try t.expectEqualStrings("terminal (sh)", app.panes.pty(sh2).?.label);
    try app.render();
    const tab2 = (rectsOf(&app, sh2)).tab orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings(bufferline.ghost_glyph, app.screen.readCell(tab2.x + 1, tab2.y).?.char.grapheme);
    const cmd = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" }, .kind = .command, .placement = .tab });
    try t.expectEqualStrings("/bin/sh -c sleep 30", app.panes.pty(cmd).?.label);
    try app.render();
    const tab3 = (rectsOf(&app, cmd)).tab orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings(bufferline.ghost_glyph, app.screen.readCell(tab3.x + 1, tab3.y).?.char.grapheme);
    // `ui.terminal_glyph = .terminal` is the codicon — and it is the
    // codicon whatever `$TERM_PROGRAM` says. The per-emulator marks are
    // gone: which terminal mnml was launched from decided the icon, and
    // none of those glyphs was the product's own logo.
    app.cfg.ui.terminal_glyph = .terminal;
    try app.env.put("TERM_PROGRAM", "ghostty");
    try app.render();
    const tab_t = (rectsOf(&app, sh)).tab orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings(bufferline.term_glyph, app.screen.readCell(tab_t.x + 1, tab_t.y).?.char.grapheme);
    try app.env.put("TERM_PROGRAM", "Hyper");
    try app.render();
    const tab_u = (rectsOf(&app, sh)).tab orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings(bufferline.term_glyph, app.screen.readCell(tab_u.x + 1, tab_u.y).?.char.grapheme);
    app.cfg.ui.terminal_glyph = .ghostty;
    // `--ascii`: the `$` twin, not a Nerd Font codepoint.
    app.cfg.ui.ascii_icons = true;
    try app.render();
    const tab4 = (rectsOf(&app, sh)).tab orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings(bufferline.ghost_ascii, app.screen.readCell(tab4.x + 1, tab4.y).?.char.grapheme);
}

test "an AI pane's tab wears its product's mark: two Claude panes, the same glyph in two accents; Codex its own glyph in the theme's cyan" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const shim = try writeClaudeShim(tmp.dir, root);
    defer t.allocator.free(shim);
    // A binary literally called `codex` is a Codex session to
    // `isProductArgv`, no profile needed.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "codex", .data = "#!/bin/sh\nsleep 30\n" });
    const codex = try std.fs.path.join(t.allocator, &.{ root, "codex" });
    defer t.allocator.free(codex);
    const res = try std.process.run(t.allocator, t.io, .{ .argv = &.{ "chmod", "+x", codex } });
    t.allocator.free(res.stdout);
    t.allocator.free(res.stderr);

    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 120, .rows = 20 });
    defer app.deinit();
    app.cfg.ai.launch_profiles = &color_profiles;
    app.tree.visible = false;
    const c1 = try open(&app, .{ .argv = &.{shim}, .label = "claude", .kind = .command, .placement = .tab });
    const c2 = try open(&app, .{ .argv = &.{shim}, .label = "claude", .kind = .command, .placement = .tab });
    const cx = try open(&app, .{ .argv = &.{codex}, .label = "codex", .kind = .command, .placement = .tab });
    try app.render();
    // Both Claude tabs carry the Claude mark; each is painted in its
    // own auto accent — the same colour as its identity strip and its
    // sessions card — so two sessions never read as one.
    const t1 = (rectsOf(&app, c1)).tab orelse return error.TestUnexpectedResult;
    const t2 = (rectsOf(&app, c2)).tab orelse return error.TestUnexpectedResult;
    const g1 = app.screen.readCell(t1.x + 1, t1.y).?;
    const g2 = app.screen.readCell(t2.x + 1, t2.y).?;
    try t.expectEqualStrings(bufferline.claude_glyph, g1.char.grapheme);
    try t.expectEqualStrings(bufferline.claude_glyph, g2.char.grapheme);
    // // changed (accent-defaults): the first Claude pane wears the
    // brand's orange, the mark's own colour; the second the ladder's
    // first slot.
    try t.expect(Theme.Color.eql(g1.style.fg, claude_brand));
    try t.expect(Theme.Color.eql(g2.style.fg, app.theme.palette.green));
    try t.expect(!Theme.Color.eql(g1.style.fg, g2.style.fg));
    // Codex has its own mark, in the cyan its chip wears — the first
    // Codex pane's default. A second one would take a ladder slot: two
    // Codex panes both in cyan is the thing the rail exists to stop.
    const t3 = (rectsOf(&app, cx)).tab orelse return error.TestUnexpectedResult;
    const g3 = app.screen.readCell(t3.x + 1, t3.y).?;
    try t.expectEqualStrings(bufferline.codex_glyph, g3.char.grapheme);
    try t.expect(Theme.Color.eql(g3.style.fg, app.theme.palette.cyan));
    try t.expect(!Theme.Color.eql(g3.style.fg, g1.style.fg));
    try t.expect(!Theme.Color.eql(g3.style.fg, g2.style.fg));
    // `--ascii`: each product's twin, not its Nerd Font codepoint.
    app.cfg.ui.ascii_icons = true;
    try app.render();
    const a1 = (rectsOf(&app, c1)).tab orelse return error.TestUnexpectedResult;
    const a3 = (rectsOf(&app, cx)).tab orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings(bufferline.claude_ascii, app.screen.readCell(a1.x + 1, a1.y).?.char.grapheme);
    try t.expectEqualStrings(bufferline.codex_ascii, app.screen.readCell(a3.x + 1, a3.y).?.char.grapheme);
    app.cfg.ui.ascii_icons = false;
    // The user's pick still wins over the brand.
    try setAccent(&app, c1, "red");
    try app.render();
    const t1b = (rectsOf(&app, c1)).tab orelse return error.TestUnexpectedResult;
    try t.expect(Theme.Color.eql(app.screen.readCell(t1b.x + 1, t1b.y).?.style.fg, app.theme.palette.red));
}

/// The screen cell just past `needle`, which is where a shell that has
/// printed it leaves its cursor. Null when the text is not on screen.
fn cellAfter(app: *App, needle: []const u8) ?struct { x: u16, y: u16 } {
    var y: u16 = 0;
    while (y < app.screen.height) : (y += 1) {
        var x: u16 = 0;
        while (x + needle.len <= app.screen.width) : (x += 1) {
            var i: usize = 0;
            while (i < needle.len) : (i += 1) {
                const c = app.screen.readCell(x + @as(u16, @intCast(i)), y) orelse break;
                if (c.char.grapheme.len != 1 or c.char.grapheme[0] != needle[i]) break;
            } else return .{ .x = x + @as(u16, @intCast(needle.len)), .y = y };
        }
    }
    return null;
}

test "two terminals in a split: one filled cursor on the focused pane, a hollow one on the other" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 80, .rows = 16 });
    defer app.deinit();
    app.tree.visible = false;
    const left = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "printf LL; sleep 30" }, .label = "left", .kind = .command });
    const right = try open(&app, .{ .argv = &.{ "/bin/sh", "-c", "printf RR; sleep 30" }, .label = "right", .kind = .command, .placement = .right });
    try t.expect(try tickUntilScreen(&app, "LL", 5000));
    try t.expect(try tickUntilScreen(&app, "RR", 5000));
    app.active = right;
    app.focus = .{ .pane = right };
    try app.render();
    const th = &app.theme;

    // The focused pane: a filled block — the cursor colour is the
    // ground, the cell's own ground the ink.
    const hot = cellAfter(&app, "RR") orelse return error.TestUnexpectedResult;
    const hot_cell = app.screen.readCell(hot.x, hot.y).?;
    try t.expect(Theme.Color.eql(th.fg.fg, hot_cell.style.bg));
    // And the host's own cursor is put on that same cell.
    try t.expect(app.screen.cursor_vis);
    try t.expectEqual(hot.x, app.screen.cursor.col);
    try t.expectEqual(hot.y, app.screen.cursor.row);
    try t.expect(app.screen.cursor_shape == .block);

    // The other pane: hollow — the outline in the cursor colour, on the
    // pane's own ground, never filled. No MnmlSymbols has been scanned
    // here (nothing fires the startup hook), which is the same state a
    // user without the face is in, so the mark is the fallback `▯`.
    try t.expect(app.fonts.mnml_glyphs == null);
    const cold = cellAfter(&app, "LL") orelse return error.TestUnexpectedResult;
    const cold_cell = app.screen.readCell(cold.x, cold.y).?;
    try t.expectEqualStrings("\u{25af}", cold_cell.char.grapheme);
    try t.expect(Theme.Color.eql(th.fg.fg, cold_cell.style.fg));
    try t.expect(!Theme.Color.eql(th.fg.fg, cold_cell.style.bg));

    // With the face installed and carrying it, the SAME cell paints the
    // baked full-cell outline instead — the one wire from the scan to
    // the painter (`render.zig`'s `.mnml_font`), which no other test
    // crosses.
    var baked: font_scan.CpSet = .empty;
    try baked.put(app.gpa, pty_view.cursor_hollow_cp, {});
    app.fonts.mnml_glyphs = baked; // `App.deinit` frees it
    try app.render();
    try t.expectEqualStrings("\u{F2001}", app.screen.readCell(cold.x, cold.y).?.char.grapheme);
    // An installed face that PREDATES the glyph is the fallback again.
    _ = app.fonts.mnml_glyphs.?.remove(pty_view.cursor_hollow_cp);
    try app.render();
    try t.expectEqualStrings("\u{25af}", app.screen.readCell(cold.x, cold.y).?.char.grapheme);

    // Focus the other way round and the two swap.
    app.active = left;
    app.focus = .{ .pane = left };
    try app.render();
    try t.expect(Theme.Color.eql(th.fg.fg, app.screen.readCell(cold.x, cold.y).?.style.bg));
    try t.expectEqualStrings("\u{25af}", app.screen.readCell(hot.x, hot.y).?.char.grapheme);
    try t.expectEqual(cold.x, app.screen.cursor.col);

    // `.none` leaves the unfocused pane's cell alone; the focused one
    // is unchanged.
    app.cfg.ui.pty_cursor.unfocused = .none;
    try app.render();
    try t.expectEqualStrings(" ", app.screen.readCell(hot.x, hot.y).?.char.grapheme);
    try t.expect(Theme.Color.eql(th.fg.fg, app.screen.readCell(cold.x, cold.y).?.style.bg));

    // With a real terminal drawing it, the focused cell stays the
    // pane's own ground — the host's cursor is what is seen.
    app.term_cursor = true;
    try app.render();
    try t.expect(!Theme.Color.eql(th.fg.fg, app.screen.readCell(cold.x, cold.y).?.style.bg));
    try t.expect(app.screen.cursor_vis);
    try t.expectEqual(cold.x, app.screen.cursor.col);
}

/// Open a child that prints the size its pty has, then waits.
fn openSized(app: *App, placement: Placement) !PaneId {
    return open(app, .{ .argv = &.{ "/bin/sh", "-c", "stty size; sleep 30" }, .label = "sized", .kind = .command, .placement = placement });
}

/// The pane's child was born at the size the first frame gives it: the
/// frame's `fit` changes nothing, and the child's own `stty size` says
/// the same.
fn expectBornFitted(app: *App, id: PaneId, cols: u16, rows: u16) !void {
    const p = app.panes.pty(id).?;
    try t.expectEqual(cols, p.cols);
    try t.expectEqual(rows, p.rows);
    try app.render();
    try t.expectEqual(cols, p.cols);
    try t.expectEqual(rows, p.rows);
    const r = rectsOf(app, id).pane orelse return error.TestUnexpectedResult;
    // The hit covers the strip row and the rail column.
    try t.expectEqual(cols + pane_rail.width, r.w);
    try t.expectEqual(rows + 1, r.h);
    var buf: [16]u8 = undefined;
    try t.expect(try tickUntilScreen(app, try std.fmt.bufPrint(&buf, "{d} {d}", .{ rows, cols }), 5000));
}

test "a new terminal pane's child starts at the size the layout gives it: a right split, a down split, a split inside a split — the first frame resizes nothing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    // 120x40 with the tree open: the panes get columns 31..119 (89)
    // and rows 1..37 (37). Every pane wears a rail and a strip row.
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    app.cfg.ui.pane_rail = .all;
    const first = try openSized(&app, .tab);
    try expectBornFitted(&app, first, 88, 36);
    // Right: 89 = 44 + the divider + 44, less the rail. The old guess
    // halved the area less ONE rail and no divider: 44.
    const right = try openSized(&app, .right);
    try expectBornFitted(&app, right, 43, 36);
    // Down, inside the right half: 37 = 18 + the divider + 18, less
    // the strip row.
    const down = try openSized(&app, .below);
    try expectBornFitted(&app, down, 43, 17);
    // Right again, inside that: 44 = 22 + the divider + 21.
    const nested = try openSized(&app, .right);
    try expectBornFitted(&app, nested, 20, 17);

    // A down split of a lone pane.
    var solo = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer solo.deinit();
    solo.cfg.ui.pane_rail = .all;
    _ = try openSized(&solo, .tab);
    try solo.render();
    const below = try openSized(&solo, .below);
    try expectBornFitted(&solo, below, 88, 17);
}
