//! The session — `<workspace>/.mnml/session.zon` (E1: persisted state is
//! ZON). What the workspace looked like when mnml last ran: the open
//! panes (path, cursor, scroll, wrap, folds, marks; a pty's command
//! line), every tab page's split tree (and its zoom), the active pane, the tree rail,
//! the right panel, zen, the theme, the harpoon pins, the `:` history,
//! the recent files, the recent commands, the closed-buffer list and
//! the toast log.
//!
//! // changed (session-kinds): a review in progress survives a restart
//! too. Beside the editors, the previews and the terminals, the file
//! keeps the QUERY-SHAPED panes — a git status, a workspace Search
//! (its query, its case / whole-word / regex options and the row it
//! was on), a commit graph, a worktree / HEAD / staged / per-file diff
//! and an image. None of them stores a RESULT: each comes back by
//! re-running its query against today's repo and today's files, so a
//! restored Search shows what matches now and a restored status shows
//! what is changed now. A pane whose subject is gone — the directory
//! is not a repo any more, the file was deleted — is skipped, quietly:
//! no toast, and never an empty shell pane. What each kind writes
//! down is on `Pane` below.
//!
//! A terminal pane comes back the way `session.restore_terminals` says
//! (`terminalRestore`): on the default `.running` a plain shell restarts
//! in its cwd and an AI session pane resumes its session — Claude off
//! the id on its command line, Codex off the one `paneSessionId` looked
//! up when the file was written (`ai/codex_rollout.zig`) — while
//! anything that cannot be re-run safely waits for a key; `.dormant`
//! makes every one of them wait.
//!
//! Saved on quit (the `exit` hook) and every `autosave_ms` from `tick`;
//! restored from the `startup` hook when `session.restore` is on. A
//! file for another workspace, from another format version, or one
//! that does not parse is ignored with one toast — never a crash, never
//! a half-restored layout.
//!
//! The `.test` runner and the headless loop never emit `startup`, so a
//! test never autosaves into its temp dir unless it asks
//! (`session.save`). The `Loaded` rules apply on the way in: the file is
//! parsed into an arena and every string that lands in `App` is duped
//! onto the gpa by the owner that keeps it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Config = app_mod.Config;
const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;
const pty_pane = @import("pty_pane.zig");
const mount_pane = @import("mount_pane.zig");
const integrations_app = @import("integrations.zig");
const launch_profiles = @import("launch_profiles.zig");
const cli = @import("../ai/cli.zig");
const codex_rollout = @import("../ai/codex_rollout.zig");
const sessions = @import("../sessions.zig");
const md_preview = @import("md_preview.zig");
const pane_accent = @import("pane_accent.zig");
const hooks = @import("../core/hooks.zig");
const side_mod = @import("side.zig");
const Section = @import("../ui/activity_bar.zig").Section;
const theme_mod = @import("../ui/theme.zig");
const zen = @import("zen.zig");
const command = @import("../core/command.zig");
const dock = @import("dock.zig");
const config_profile = @import("../config/profile.zig");
const git_app = @import("git.zig");
const git_client = @import("../git/client.zig");
const grep = @import("grep.zig");
const image_pane = @import("image_pane.zig");
const http_app = @import("http.zig");
const http_parse = @import("../http/parse.zig");
const browser_pane = @import("browser_pane.zig");
const session_changes = @import("session_changes.zig");
const Profile = config_profile.Profile;

pub const format_version: u32 = 1;
pub const rel_path = ".mnml/session.zon";
/// The dev profile's own file, so daily-driving a workspace and
/// developing in it do not overwrite each other's layout. The two
/// profiles share `.mnml/`; they do not share this
/// (`src/config/profile.zig`).
pub const rel_path_dev = ".mnml/session-dev.zon";

/// The session file for `p`.
pub fn relPath(p: Profile) []const u8 {
    return switch (p) {
        .stable => rel_path,
        .dev => rel_path_dev,
    };
}
pub const autosave_ms: i64 = 30_000;
/// A pane index the file names that did not come back; swept out of
/// the rebuilt tree before it is installed.
const sentinel: PaneId = std.math.maxInt(PaneId);

// ─── the on-disk shape ───────────────────────────────────────────────────

pub const Level = enum { info, warn, err };
pub const Mark = struct { letter: u8, row: usize, col: usize };
pub const Fold = struct { start: usize, end: usize };
/// // changed (session-kinds): the query-shaped panes joined the
/// three original kinds — a git status, a workspace Search, a commit
/// graph, a diff and an image all come back by RE-RUNNING what made
/// them, never by replaying a saved result.
///
/// Adding a variant here is one-way: an older build reading a file
/// that names one cannot parse the enum, so it ignores the whole file
/// with the "does not parse" toast rather than crashing. Every other
/// change to `Pane` stays additive — new fields carry defaults, and
/// `ignore_unknown_fields` lets an older field set read a newer file.
/// // changed (layouts): `request` and `browser` joined for the named
/// layouts, which write them; the session itself never does
/// (`CaptureOpts.extra_kinds`), so a session file stays readable by a
/// build that does not know them.
/// // changed (session-mount): `mount` — an integration pane (Jira,
/// Bitbucket) — is one the session writes; a file that holds one does
/// not parse on a build without it, and gets the toast.
pub const PaneKind = enum { editor, md_preview, pty, git_status, grep, git_graph, diff, image, request, browser, mount };

pub const Pane = struct {
    kind: PaneKind = .editor,
    /// Absolute. Editors and previews; a scratch buffer is not saved.
    path: []const u8 = "",
    cursor: usize = 0,
    scroll_line: u32 = 0,
    scroll_col: u32 = 0,
    wrap: ?bool = null,
    folds: []const Fold = &.{},
    marks: []const Mark = &.{},
    /// `buffer.pin_toggle`.
    pinned: bool = false,
    /// pty: the command line (empty = the shell), its cwd and tab label.
    argv: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    label: ?[]const u8 = null,
    /// pty: the label is the user's rename, which a restored child's own
    /// title does not replace.
    renamed: bool = false,
    /// The pane rail's colour, a palette name (`ui/accent_color.zig`).
    /// // changed (pane-rail): every kind carries one now, not just a
    /// pty — a restored pane comes back the colour it was.
    accent: ?[]const u8 = null,
    /// pty: the AI session this pane runs, which is what a `.running`
    /// restore RESUMES (never a second session under the same id).
    /// Claude's is read off the argv the way SESSIONS reads it
    /// (`pty_pane.sessionIdOfArgv` — `Card.session_id` is the same
    /// value); a file from before this field still resumes, off its
    /// argv. // changed (codex-resume): Codex's is not on any command
    /// line, so `paneSessionId` looks it up here and this field is the
    /// only place it is written down. Null for a shell, for a bare
    /// `claude`, and for a Codex pane whose session could not be named
    /// without guessing.
    session_id: ?[]const u8 = null,
    /// pty (sessiondiff): the base `sessions.changes` diffs an AI session
    /// against — its repo root, the wall clock it started at (ms), that
    /// repo's `HEAD` then (null: an unborn branch) and the paths dirty
    /// then. A restored session keeps the base it STARTED with, so the
    /// review after a restart still covers everything it did. Absent on
    /// a shell, on a session outside any repository, and on a file from
    /// before the field (that session takes a fresh base).
    changes_repo: ?[]const u8 = null,
    changes_since_ms: i64 = 0,
    changes_head: ?[]const u8 = null,
    changes_dirty: []const []const u8 = &.{},

    // ─── the query-shaped kinds (session-kinds) ──────────────────────
    // Each names its SUBJECT, not its answer: a repo root, a search
    // query, a diff's scope. The restore re-runs the query; a subject
    // that is gone (the repo is not a repo any more, the file was
    // deleted) is skipped without a pane and without a toast.

    /// git_status / git_graph / diff: the repo's absolute root, which
    /// is what survives a restart — `Repo.id` is per-process.
    repo: ?[]const u8 = null,
    /// grep: the Search pane's query. An empty one is not saved.
    query: ?[]const u8 = null,
    /// grep: the three search options, as `grep.Flags`.
    grep_case: bool = false,
    grep_word: bool = false,
    grep_regex: bool = false,
    /// diff: which diff this is. The scopes whose subject cannot be
    /// checked without asking git (`.commit`, `.range`, `.orig`,
    /// `.conflict`) are not saved.
    diff_scope: ?git_client.DiffScope = null,
    /// diff: the revision the scope names, when it names one.
    rev: ?[]const u8 = null,
    /// request: the `### name` block of `path` it shows; `""` a bare
    /// `###`, null the file's leading block.
    block: ?[]const u8 = null,
    /// request: that block's position among the file's blocks — what
    /// tells two blocks of one name (two bare `###`) apart.
    block_index: ?u32 = null,
    /// browser: the page it was on.
    url: ?[]const u8 = null,
    /// mount: the manifest id of the integration the pane runs
    /// (`jira_work`). With `argv` (the command line it was opened with,
    /// deep link cut off) and `label`, what reopens it: the binary is
    /// resolved through today's manifest, its settings re-read, and a
    /// manifest that is gone is skipped.
    integration: ?[]const u8 = null,
};

/// The split tree as the node pool it is in memory: leaves name pane
/// indices into `Saved.panes`, splits name node indices.
pub const Node = union(enum) {
    leaf: struct { active: u32 = 0, tabs: []const u32 = &.{} },
    split: struct { dir: layout_mod.SplitDir = .horizontal, ratio: u16 = 50, first: u32 = 0, second: u32 = 0 },
};
pub const Tab = struct {
    nodes: []const Node = &.{},
    root: ?u32 = null,
    /// `view.toggle_zoom`: the zoomed pane, an index into `panes` —
    /// the page comes back zoomed on it. Null (and left out of the
    /// file) for a page that was not zoomed; a pane that did not come
    /// back leaves the page un-zoomed.
    zoomed: ?u32 = null,
};
pub const Closed = struct { path: []const u8 = "", cursor: usize = 0 };
pub const Message = struct { level: Level = .info, age_ms: i64 = 0, text: []const u8 = "" };
/// SESSIONS: a display name for a session id.
pub const SessionAlias = struct { id: []const u8 = "", name: []const u8 = "" };
/// SESSIONS: a chosen accent colour for a session id (`colors`).
pub const SessionColor = struct { id: []const u8 = "", color: []const u8 = "" };
/// SESSIONS: a worktree mnml made for a session (`worktrees`); `id` is
/// the session's transcript id once known, else empty.
pub const SessionWorktree = struct { id: []const u8 = "", path: []const u8 = "", name: []const u8 = "", branch: []const u8 = "", repo: []const u8 = "" };

pub const Saved = struct {
    version: u32 = format_version,
    workspace: []const u8 = "",
    panes: []const Pane = &.{},
    tabs: []const Tab = &.{},
    active_tab: usize = 0,
    /// Index into `panes`.
    active: ?u32 = null,
    tree_visible: bool = true,
    tree_width: u16 = 30,
    tree_show_hidden: bool = false,
    tree_expanded: []const []const u8 = &.{},
    /// The right column's width; `tree_width` is the left's.
    right_panel_width: u16 = 32,
    /// // changed (bottom-dock): the dock's height in rows.
    bottom_panel_height: u16 = 12,
    /// What each host shows (`tree_visible` stays the explorer's own
    /// flag, as in Rust). // changed (section-side): replaces `right_panel`.
    /// // changed (bottom-dock): `bottom` joins the two columns —
    /// `null` is a closed dock, which is how its `visible` flag rides.
    left: ?Section = null,
    right: ?Section = null,
    bottom: ?Section = null,
    /// Where every section with a column surface lives.
    sides: Config.SectionSide = .{},
    zen: bool = false,
    theme: []const u8 = "",
    /// The branches panel lists every repo (`git_palette.State.all`).
    git_all: bool = false,
    /// Nine entries; `""` is an empty slot.
    harpoon: []const []const u8 = &.{},
    ex_history: []const []const u8 = &.{},
    /// Oldest first, as `App.recent`.
    recent: []const []const u8 = &.{},
    /// Newest first, as `App.recent_commands`.
    recent_commands: []const []const u8 = &.{},
    closed: []const Closed = &.{},
    messages: []const Message = &.{},
    /// SESSIONS: the manual order (session ids, first on top) and the aliases.
    sessions_order: []const []const u8 = &.{},
    sessions_aliases: []const SessionAlias = &.{},
    /// // changed (colors): the per-session colour overrides, by id.
    sessions_colors: []const SessionColor = &.{},
    /// // changed (sessions-worktree): the session worktrees, by path.
    sessions_worktrees: []const SessionWorktree = &.{},
    /// // changed (sessions-card): the history chip's toggle — the ended
    /// sessions listed under ENDED.
    sessions_show_ended: bool = false,
    /// The dock widgets and whether the dock is hidden.
    dock: []const dock.SavedWidget = &.{},
    dock_hidden: bool = false,
    /// // changed (launcher-dock): the LAUNCHER dock's session pin
    /// (`app/launcher_dock.zig`) — its mode lives in `ui.dock.mode`,
    /// but a pin is a "for now" the config is not asked to remember.
    launcher_dock_pinned: bool = false,
};

// ─── app-side state ──────────────────────────────────────────────────────

pub const State = struct {
    /// Set by the `startup` hook: the terminal loop is running, so the
    /// timer and the exit hook may write. `session.clear` turns it off.
    autosave: bool = false,
    last_save_ms: i64 = 0,
    /// The file came back on this launch.
    restored: bool = false,
    /// Saved AI sessions the last restore found still running in a pane
    /// and kept there instead of resuming a second time.
    kept_live: u16 = 0,
};

pub fn onStartup(app: *App, _: hooks.HookArgs) void {
    app.session.autosave = true;
    app.session.last_save_ms = app.now_ms;
    if (!app.cfg.session.restore) return;
    restore(app) catch |err| app.toast("session: {s}", .{@errorName(err)});
}

pub fn onExit(app: *App, _: hooks.HookArgs) void {
    if (!app.session.autosave) return;
    save(app) catch {};
}

/// The 30 s timer.
pub fn tick(app: *App, now: i64) void {
    if (!app.session.autosave) return;
    if (now - app.session.last_save_ms < autosave_ms) return;
    save(app) catch {};
}

pub fn path(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    return std.fs.path.join(arena, &.{ app.workspace, relPath(app.profile()) });
}

// ─── save ────────────────────────────────────────────────────────────────

pub const SaveError = Allocator.Error || error{WriteFailed};

/// Serialize the app into the session file. Best-effort by design —
/// the caller decides whether a failure is worth a toast.
pub fn save(app: *App) SaveError!void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const saved = try capture(app, arena);
    const text = try render(arena, saved);
    const file = try path(app, arena);
    const dir = std.fs.path.dirname(file) orelse return error.WriteFailed;
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(app.io, dir) catch return error.WriteFailed;
    cwd.writeFile(app.io, .{ .sub_path = file, .data = text }) catch return error.WriteFailed;
    app.session.last_save_ms = app.now_ms;
}

/// `Saved` as ZON text on `arena`.
pub fn render(arena: Allocator, saved: Saved) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("// mnml session — written on quit and every 30 s; delete it (or `session.clear`) to start clean.\n") catch return error.OutOfMemory;
    std.zon.stringify.serialize(saved, .{ .emit_default_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.written();
}

/// The AI session a pty pane is running, for the file to write down.
///
/// Claude wears its id on its command line, so that is the whole answer
/// for a Claude pane. Codex does not: `codex` picks its own id and
/// names it only in the rollout it opens, so the id is looked up by
/// the pane's cwd and the second it started
/// (`ai/codex_rollout.discover`) and then REMEMBERED on the pane — the
/// window that identifies a session only narrows as later Codex
/// sessions start in the same directory, so the first unambiguous
/// answer is the one to keep. A lookup that is not unique gives
/// nothing, and the pane falls to the dormant rule rather than
/// resuming a conversation that might be somebody else's.
///
/// The walk is paid for only while a Codex pane has no id yet, and one
/// `stat` per rollout rules out the years of them a machine keeps.
fn paneSessionId(app: *App, arena: Allocator, pt: *pty_pane.PtyPane, argv: []const []const u8) Allocator.Error!?[]const u8 {
    if (pty_pane.sessionIdOfArgv(argv)) |id| return id;
    if (argv.len == 0 or !launch_profiles.isProductArgv(app, argv[0], .codex)) return null;
    if (pt.codex_session_id) |id| return id;
    if (pt.started_at_s > 0) find: {
        const home = (try sessions.homeFor(app)) orelse break :find;
        const cwd = pt.cwd orelse app.workspace;
        const found = codex_rollout.discover(app.gpa, app.io, arena, home, cwd, pt.started_at_s) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => break :find,
        };
        if (found) |id| {
            pt.codex_session_id = try app.gpa.dupe(u8, id);
            return id;
        }
    }
    // A pane this restore already resumed keeps naming its session on
    // its command line, whether or not the lookup can see it again.
    return pty_pane.codexSessionIdOfArgv(argv);
}

/// What `capturePane` may write down beyond the session's own kinds.
pub const CaptureOpts = struct {
    /// A request pane (its `.http` file and block) and a browser pane
    /// (its URL). The session leaves them out — a restart that
    /// relaunched Chrome behind the user's back is not a restore — and
    /// a named layout, which is loaded on purpose, keeps them
    /// (`app/named_layouts.zig`).
    extra_kinds: bool = false,
};

/// One pane as the file writes it down, or null when it is not a kind
/// that can come back (a scratch buffer, a list, a runner's pty). The
/// strings are the pane's own or `arena`'s — good for as long as the
/// pane and the arena are.
pub fn capturePane(app: *App, arena: Allocator, i: PaneId, p: *app_mod.Pane, opts: CaptureOpts) Allocator.Error!?Pane {
    return switch (p.*) {
        .editor => |*e| blk: {
            const file = e.buf.doc.path orelse break :blk null;
            var folds: std.ArrayListUnmanaged(Fold) = .empty;
            for (e.buf.editor.folds.keys(), e.buf.editor.folds.values()) |s, en| try folds.append(arena, .{ .start = s, .end = en });
            var marks: std.ArrayListUnmanaged(Mark) = .empty;
            var it = e.buf.doc.marks.keyIterator();
            while (it.next()) |letter| {
                const pos = e.buf.doc.markPos(letter.*).?;
                try marks.append(arena, .{ .letter = letter.*, .row = pos.row, .col = pos.col });
            }
            break :blk .{
                .kind = .editor,
                .path = file,
                .cursor = e.buf.editor.cursor,
                .scroll_line = e.view.scroll_line,
                .scroll_col = e.view.scroll_col,
                .wrap = e.wrap,
                .folds = folds.items,
                .marks = marks.items,
                .pinned = e.pinned,
                // // changed (pane-rail): the pane's rail colour,
                // so a restored window comes back the colour it
                // was rather than re-rolling off the ladder.
                .accent = app.panes.accent(i),
            };
        },
        .md_preview => |*m| .{ .kind = .md_preview, .path = m.path, .accent = app.panes.accent(i) },
        // // changed (session-kinds): the query-shaped panes. Each
        // writes down what it was ASKED, never what came back — a
        // restore re-runs the query against today's repo and
        // today's files.
        .image => |*im| .{ .kind = .image, .path = im.path, .accent = app.panes.accent(i) },
        .git_status => |*st| blk: {
            const repo = app.git.repoById(st.repo) orelse break :blk null;
            break :blk .{ .kind = .git_status, .repo = repo.path, .cursor = st.cursor, .scroll_line = @intCast(@min(st.scroll, std.math.maxInt(u32))), .accent = app.panes.accent(i) };
        },
        .git_graph => |*g| blk: {
            const repo = app.git.repoById(g.repo) orelse break :blk null;
            break :blk .{ .kind = .git_graph, .repo = repo.path, .accent = app.panes.accent(i) };
        },
        .diff => |*d| blk: {
            const repo = app.git.repoById(d.repo) orelse break :blk null;
            // A scope whose subject is a revision cannot be checked
            // for reachability without running git, and a diff pane
            // that opens onto an error is worse than one that does
            // not come back at all.
            switch (d.scope) {
                .file, .worktree, .head, .staged => {},
                .commit, .range, .orig, .conflict => break :blk null,
            }
            break :blk .{ .kind = .diff, .repo = repo.path, .diff_scope = d.scope, .path = d.path orelse "", .rev = d.rev, .accent = app.panes.accent(i) };
        },
        .grep => |*g| blk: {
            if (g.query.len == 0) break :blk null;
            break :blk .{
                .kind = .grep,
                .query = g.query,
                .grep_case = g.flags.case_sensitive,
                .grep_word = g.flags.whole_word,
                .grep_regex = g.flags.regex,
                .cursor = g.cursor,
                .accent = app.panes.accent(i),
            };
        },
        .pty => |*pt| blk: {
            // Runner and task ptys are re-created by their owners.
            if (pt.kind != .shell and pt.kind != .command) break :blk null;
            // A Claude session started under `--session-id` comes
            // back with `--resume`: the id is taken once.
            const argv = try pty_pane.resumeArgv(arena, pt.argv);
            var sp: Pane = .{ .kind = .pty, .argv = argv, .cwd = (try pt.liveCwd(arena)) orelse pt.cwd, .label = pt.label, .renamed = pt.renamed, .accent = pt.accent_color, .session_id = try paneSessionId(app, arena, pt, argv) };
            // sessiondiff: the session's base, once it has one.
            if (pt.changes) |rec| if (rec.base == .ready) {
                sp.changes_repo = rec.root;
                sp.changes_since_ms = rec.since_ms;
                sp.changes_head = rec.head;
                const dirty = try arena.alloc([]const u8, rec.dirty0.len);
                for (dirty, rec.dirty0) |*d, src| d.* = src;
                sp.changes_dirty = dirty;
            };
            break :blk sp;
        },
        .request => |*rp| blk: {
            if (!opts.extra_kinds) break :blk null;
            const file = rp.source_path orelse break :blk null;
            break :blk .{ .kind = .request, .path = file, .block = rp.block_name, .block_index = rp.block_index, .accent = app.panes.accent(i) };
        },
        .browser => |*b| if (opts.extra_kinds) .{ .kind = .browser, .url = b.url, .accent = app.panes.accent(i) } else null,
        // An integration pane: what opened it, not what it showed —
        // the child fetches today's rows. One showing its exit
        // banner, or a bare `mount.open` of a binary, is not kept.
        .mount => |*mp| blk: {
            const id = mp.integration orelse break :blk null;
            if (mp.exit != null or mp.argv.len == 0) break :blk null;
            break :blk .{ .kind = .mount, .integration = id, .argv = mp.argv, .label = mp.label };
        },
        else => null,
    };
}

/// The app as a `Saved`, every slice on `arena`.
pub fn capture(app: *App, arena: Allocator) Allocator.Error!Saved {
    var saved: Saved = .{ .workspace = try canonicalWorkspace(app, arena) };

    // Panes: every slot that can come back, remembering which index it got.
    const slot_count = app.panes.slots.items.len;
    const index_of = try arena.alloc(?u32, slot_count);
    @memset(index_of, null);
    var panes: std.ArrayListUnmanaged(Pane) = .empty;
    for (app.panes.slots.items, 0..) |*slot, i| {
        const p = &(slot.* orelse continue);
        const sp: ?Pane = try capturePane(app, arena, @intCast(i), p, .{});
        const sp_val = sp orelse continue;
        index_of[i] = @intCast(panes.items.len);
        try panes.append(arena, sp_val);
    }
    saved.panes = panes.items;
    if (app.active) |a| if (a < slot_count) {
        saved.active = index_of[a];
    };

    // Tab pages: the node pools, compacted (free slots dropped).
    var tabs: std.ArrayListUnmanaged(Tab) = .empty;
    for (app.layouts.layouts.items) |*l| try tabs.append(arena, try captureLayout(arena, l, index_of));
    saved.tabs = tabs.items;
    saved.active_tab = app.layouts.active;

    // Chrome.
    saved.tree_visible = app.tree.visible;
    saved.tree_width = @import("git_palette.zig").restingSize(app, .left);
    saved.tree_show_hidden = app.tree.show_hidden;
    var expanded: std.ArrayListUnmanaged([]const u8) = .empty;
    var kit = app.tree.expanded.keyIterator();
    while (kit.next()) |k| try expanded.append(arena, k.*);
    std.mem.sort([]const u8, expanded.items, {}, lessThan);
    saved.tree_expanded = expanded.items;
    saved.right_panel_width = @import("git_palette.zig").restingSize(app, .right);
    saved.bottom_panel_height = app.side.bottom_height;
    saved.left = app.side.open.get(.left);
    saved.right = app.side.open.get(.right);
    saved.bottom = app.side.open.get(.bottom);
    inline for (@typeInfo(Config.SectionSide).@"struct".fields) |f| {
        @field(saved.sides, f.name) = app.side.of.get(@field(Section, f.name));
    }
    saved.zen = app.zen;
    saved.theme = app.theme.name;
    saved.git_all = app.git_palette.all;

    // Lists.
    const pins = try arena.alloc([]const u8, app.harpoon.paths.len);
    for (app.harpoon.paths, 0..) |p, i| pins[i] = p orelse "";
    saved.harpoon = pins;
    saved.ex_history = try dupeList(arena, app.cmd_history.items);
    saved.recent = try dupeList(arena, app.recent.items);
    saved.recent_commands = try dupeList(arena, app.recent_commands.items);
    const closed = try arena.alloc(Closed, app.closed.items.len);
    for (app.closed.items, 0..) |c, i| closed[i] = .{ .path = c.path, .cursor = c.cursor };
    saved.closed = closed;
    const msgs = try arena.alloc(Message, app.messages.items.items.len);
    for (app.messages.items.items, 0..) |m, i| msgs[i] = .{
        .level = switch (m.level) {
            .info => .info,
            .warn => .warn,
            .err => .err,
        },
        .age_ms = @max(app.now_ms - m.at_ms, 0),
        .text = m.text,
    };
    saved.messages = msgs;
    saved.sessions_order = try dupeList(arena, app.sessions.order.items);
    const aliases = try arena.alloc(SessionAlias, app.sessions.aliases.items.len);
    for (app.sessions.aliases.items, 0..) |a, i| aliases[i] = .{ .id = a.id, .name = a.name };
    saved.sessions_aliases = aliases;
    const colors = try arena.alloc(SessionColor, app.sessions.colors.items.len);
    for (app.sessions.colors.items, 0..) |c, i| colors[i] = .{ .id = c.id, .color = c.name };
    saved.sessions_colors = colors;
    const trees = try arena.alloc(SessionWorktree, app.sessions.worktrees.items.items.len);
    for (app.sessions.worktrees.items.items, 0..) |w, i| trees[i] = .{ .id = w.session_id orelse "", .path = w.path, .name = w.name, .branch = w.branch, .repo = w.repo };
    saved.sessions_worktrees = trees;
    saved.sessions_show_ended = app.sessions.show_ended;
    saved.dock = try dock.capture(app, arena);
    saved.dock_hidden = app.dock.hidden;
    saved.launcher_dock_pinned = app.launcher_dock.pinned;
    return saved;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn dupeList(arena: Allocator, items: []const []u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, items.len);
    for (items, 0..) |s, i| out[i] = s;
    return out;
}

pub fn captureLayout(arena: Allocator, l: *const Layout, index_of: []const ?u32) Allocator.Error!Tab {
    // Compact node ids: free slots go, the rest renumber in order.
    const remap = try arena.alloc(?u32, l.nodes.items.len);
    var next: u32 = 0;
    for (l.nodes.items, 0..) |n, i| {
        remap[i] = if (n == .free) null else next;
        if (n != .free) next += 1;
    }
    var nodes: std.ArrayListUnmanaged(Node) = .empty;
    for (l.nodes.items) |n| switch (n) {
        .free => {},
        // The AI grid's placeholder: a leaf of no tabs, which the
        // restore sweeps like a pane that did not come back.
        .empty => try nodes.append(arena, .{ .leaf = .{} }),
        .leaf => |lf| {
            var tabs: std.ArrayListUnmanaged(u32) = .empty;
            var active: ?u32 = null;
            for (lf.tabs.items) |pid| {
                const idx = (if (pid < index_of.len) index_of[pid] else null) orelse continue;
                try tabs.append(arena, idx);
                if (pid == lf.active) active = idx;
            }
            try nodes.append(arena, .{ .leaf = .{ .active = active orelse (if (tabs.items.len > 0) tabs.items[0] else 0), .tabs = tabs.items } });
        },
        .split => |s| try nodes.append(arena, .{ .split = .{
            .dir = s.dir,
            .ratio = s.ratio,
            .first = remap[s.first] orelse 0,
            .second = remap[s.second] orelse 0,
        } }),
    };
    const zoomed: ?u32 = if (l.zoomed) |z| (if (z < index_of.len and l.leafOf(z) != null) index_of[z] else null) else null;
    return .{ .nodes = nodes.items, .root = if (l.root) |r| remap[r] else null, .zoomed = zoomed };
}

// ─── restore ─────────────────────────────────────────────────────────────

pub const RestoreError = Allocator.Error;

/// Read the file and rebuild the app from it. A missing file is
/// nothing; a foreign / stale / unreadable one is one toast.
pub fn restore(app: *App) RestoreError!void {
    app.session.kept_live = 0;
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const file = try path(app, arena);
    const src: [:0]u8 = Io.Dir.cwd().readFileAllocOptions(app.io, file, arena, .limited(32 * 1024 * 1024), .of(u8), 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return,
        else => {
            app.toast("session: cannot read {s}: {s}", .{ relPath(app.profile()), @errorName(err) });
            return;
        },
    };
    const saved = parse(arena, src) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            app.toast("session: {s} does not parse — ignored", .{relPath(app.profile())});
            return;
        },
    };
    if (saved.version != format_version) {
        app.toast("session: {s} is format v{d}, this build writes v{d} — ignored", .{ relPath(app.profile()), saved.version, format_version });
        return;
    }
    if (!sameWorkspace(app.io, saved.workspace, app.workspace)) {
        app.toast("session: {s} belongs to {s} — ignored", .{ relPath(app.profile()), saved.workspace });
        return;
    }
    try apply(app, arena, saved);
    app.session.restored = true;
}

/// Whether `saved` names the workspace `actual`. `main.zig` resolves
/// the workspace with realpath (`/tmp/x` is `/private/tmp/x` on
/// macOS), but a session file can hold the path as typed — by hand, by
/// a tool, or by a launch through a symlink — so both sides go through
/// the same resolution before the compare. When either side no longer
/// resolves (a deleted path) the literal compare is all there is.
pub fn sameWorkspace(io: Io, saved: []const u8, actual: []const u8) bool {
    if (std.mem.eql(u8, saved, actual)) return true;
    var sbuf: [std.fs.max_path_bytes]u8 = undefined;
    var abuf: [std.fs.max_path_bytes]u8 = undefined;
    const s = Io.Dir.cwd().realPathFile(io, saved, &sbuf) catch return false;
    const a = Io.Dir.cwd().realPathFile(io, actual, &abuf) catch return false;
    return std.mem.eql(u8, sbuf[0..s], abuf[0..a]);
}

/// `app.workspace` as the file stores it: resolved, so a session written
/// from an unresolved spelling is canonical the next time it is read.
/// Falls back to the spelling in hand when the path does not resolve.
pub fn canonicalWorkspace(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(app.io, app.workspace, &buf) catch return app.workspace;
    return arena.dupe(u8, buf[0..n]);
}

pub fn parse(arena: Allocator, src: [:0]const u8) error{ OutOfMemory, ParseZon }!Saved {
    // The parser is instantiated per field of `Saved`; the default quota
    // ran out when the SESSIONS lists joined the file.
    @setEvalBranchQuota(8000);
    return std.zon.parse.fromSliceAlloc(Saved, arena, src, null, .{ .ignore_unknown_fields = true, .free_on_error = false });
}

/// Close every open pane but a dirty editor — its unsaved work is not
/// the restore's to throw away (it stays open, and a saved pane on the
/// same file finds it) — and a live AI session the saved set resumes:
/// that pane IS the session, kept in place rather than killed and
/// resumed a second time (`openSaved`'s resume rule then hands it
/// back). A terminal's child is hung up on and reaped.
fn closeReplaced(app: *App, arena: Allocator, saved: Saved) Allocator.Error!void {
    var keep: std.ArrayListUnmanaged(PaneId) = .empty;
    for (saved.panes) |sp| {
        if (sp.kind != .pty) continue;
        const id = switch (terminalRestore(app, sp)) {
            .resumed => |id| id,
            else => continue,
        };
        if (pty_pane.liveSessionPane(app, id)) |live| try keep.append(arena, live);
    }
    var ids: std.ArrayListUnmanaged(PaneId) = .empty;
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| {
        const pid: PaneId = @intCast(i);
        if (p.dirty() or std.mem.indexOfScalar(PaneId, keep.items, pid) != null) continue;
        try ids.append(arena, pid);
    };
    for (ids.items) |id| try app.forceClosePane(id);
}

/// Rebuild the app from `saved`. Panes are opened first (each lands in
/// whatever leaf the openers pick), then the layouts are replaced
/// wholesale with the saved trees, then the chrome and the lists.
pub fn apply(app: *App, arena: Allocator, saved: Saved) RestoreError!void {
    const gpa = app.gpa;
    // The saved tabs replace the layouts wholesale, so the panes open now
    // are the ones this restore replaces: close them first. Left open
    // they were in no layout but still running — every restore in a live
    // instance added a hidden shell per terminal (21 children became 41).
    if (saved.tabs.len > 0) try closeReplaced(app, arena, saved);
    // Panes → ids.
    const ids = try arena.alloc(?PaneId, saved.panes.len);
    for (saved.panes, 0..) |sp, i| ids[i] = openSaved(app, sp, ids[0..i]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };

    // Layouts: the saved trees replace whatever the opens built.
    if (saved.tabs.len > 0) {
        var fresh: std.ArrayListUnmanaged(Layout) = .empty;
        errdefer {
            for (fresh.items) |*l| l.deinit();
            fresh.deinit(gpa);
        }
        for (saved.tabs) |tab| try fresh.append(gpa, try buildLayout(gpa, tab, ids));
        // A pane other than an editor lives in one leaf of one page
        // (`LayoutState.holders`): a file naming one on two pages (only a
        // hand-edited one does) keeps it on the first. An editor — a
        // buffer — may be on several, as vim's tab pages share one.
        for (fresh.items, 0..) |*l, i| for (try l.allPanes(arena)) |pid| {
            if (app.sharedAcrossPages(pid)) continue;
            for (fresh.items[0..i]) |*prev| if (prev.leafOf(pid) != null) {
                _ = l.removePane(pid);
                break;
            };
        };
        app.setActive(null);
        const ls = &app.layouts;
        for (ls.layouts.items) |*l| l.deinit();
        ls.layouts.deinit(gpa);
        ls.layouts = fresh;
        ls.active = @min(saved.active_tab, ls.layouts.items.len - 1);
    }
    // The active pane, or the first leaf's.
    const want: ?PaneId = if (saved.active) |a| (if (a < ids.len) ids[a] else null) else null;
    if (want) |id| {
        app.showPane(id);
    } else {
        const layout = app.layouts.current();
        app.setActive(layout.landing());
    }

    // Chrome.
    app.tree.visible = saved.tree_visible;
    app.tree.width = std.math.clamp(saved.tree_width, Config.tree_width_min, Config.tree_width_max);
    app.tree.show_hidden = saved.tree_show_hidden;
    // The saved set replaces what is open (Rust's `set_expanded_dirs`),
    // and the top-level directories it leaves shut stay shut — a
    // restored tree is not a first sight.
    {
        var it = app.tree.expanded.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        app.tree.expanded.clearRetainingCapacity();
    }
    for (saved.tree_expanded) |rel| {
        if (app.tree.expanded.contains(rel)) continue;
        const key = try gpa.dupe(u8, rel);
        errdefer gpa.free(key);
        try app.tree.expanded.put(gpa, key, {});
    }
    app.tree.restored = true;
    app.tree.loaded = false; // re-listed on the next frame with the expansions applied
    app.side.right_width = @max(saved.right_panel_width, 8);
    app.side.bottom_height = std.math.clamp(saved.bottom_panel_height, Config.bottom_panel_height_min, Config.bottom_panel_height_max);
    inline for (@typeInfo(Config.SectionSide).@"struct".fields) |f| {
        if (@field(saved.sides, f.name)) |s| app.side.of.set(@field(Section, f.name), s);
    }
    // A column shows a section only if the section lives there (a
    // hand-edited file cannot put TODOS in both columns).
    for ([_]Config.Side{ .left, .right, .bottom }, [_]?Section{ saved.left, saved.right, saved.bottom }) |s, sec| {
        const ok = if (sec) |x| side_mod.surface(x) != null and side_mod.sideOf(app, x) == s else false;
        app.side.open.set(s, if (ok) sec else null);
        app.side.last.set(s, if (ok) sec else null);
    }
    // An older file has no `left`: the explorer is where `tree_visible`
    // says. The tree is on screen only when its column shows it.
    const es = side_mod.sideOf(app, .explorer);
    if (saved.tree_visible and app.side.open.get(es) == null) app.side.open.set(es, .explorer);
    if (app.side.open.get(es) != .explorer) app.tree.visible = false;
    zen.set(app, saved.zen);
    app.git_palette.all = saved.git_all;
    if (saved.theme.len > 0) if (theme_mod.byName(saved.theme)) |th| {
        if (!std.mem.eql(u8, th.name, app.theme.name)) app.setTheme(th);
    };

    // Lists.
    for (saved.harpoon, 0..) |p, i| {
        if (i >= app.harpoon.paths.len or p.len == 0) continue;
        try app.harpoon.set(gpa, i, p);
    }
    for (saved.ex_history) |line| try app.noteCmdLine(line);
    // Newest first in the file; noting each puts it in front, so the
    // oldest goes first.
    var rc = saved.recent_commands.len;
    while (rc > 0) : (rc -= 1) if (saved.recent_commands[rc - 1].len > 0) try app.noteRecentCommand(saved.recent_commands[rc - 1]);
    for (saved.sessions_order) |id| {
        if (id.len == 0 or app.sessions.orderIndex(id) != null) continue;
        const owned = try gpa.dupe(u8, id);
        errdefer gpa.free(owned);
        try app.sessions.order.append(gpa, owned);
    }
    for (saved.sessions_aliases) |a| if (a.id.len > 0) try app.sessions.setAlias(gpa, a.id, a.name);
    for (saved.sessions_colors) |c| if (c.id.len > 0) try app.sessions.setColor(gpa, c.id, c.color);
    for (saved.sessions_worktrees) |w| if (w.path.len > 0 and w.name.len > 0) try app.sessions.worktrees.add(gpa, w.path, w.name, if (w.branch.len > 0) w.branch else w.name, w.repo, w.id);
    app.sessions.show_ended = saved.sessions_show_ended;
    try dock.apply(app, saved.dock, saved.dock_hidden);
    app.launcher_dock.pinned = saved.launcher_dock_pinned;
    for (saved.recent) |p| try app.noteRecent(p);
    for (saved.closed) |c| {
        if (c.path.len == 0) continue;
        const copy = try gpa.dupe(u8, c.path);
        errdefer gpa.free(copy);
        if (app.closed.items.len >= App.max_closed) gpa.free(app.closed.orderedRemove(0).path);
        try app.closed.append(gpa, .{ .path = copy, .cursor = c.cursor });
    }
    for (saved.messages) |m| try app.messages.record(gpa, m.text, switch (m.level) {
        .info => .info,
        .warn => .warn,
        .err => .err,
    }, app.now_ms - m.age_ms);
    app.messages.markRead();
    app.needs_render = true;
}

pub const OpenError = Allocator.Error || error{Skipped};

/// One saved pane back into the store. `Skipped` for anything that
/// cannot be reopened (a file that went away, a pty where there is none).
/// `opened` is what this restore has brought back so far: a file already
/// among them was saved from two windows, and gets its second one.
fn openSaved(app: *App, sp: Pane, opened: []const ?PaneId) OpenError!?PaneId {
    return openSavedWith(app, sp, opened, .{});
}

/// How `openSavedWith` treats what it opens.
pub const OpenOpts = struct {
    /// A terminal with a command line comes back running it, not
    /// dormant. The session's rule 3 exists because a restart is not
    /// the user asking for their build again; loading a named layout
    /// is — and whether this workspace may run it at all was decided
    /// before (`app/named_layouts.zig`'s trust rule).
    run_commands: bool = false,
};

/// `openSaved` with options — the named layouts' door into the same
/// per-kind reopening the session uses.
pub fn openSavedWith(app: *App, sp: Pane, opened: []const ?PaneId, opts: OpenOpts) OpenError!?PaneId {
    const id = try openSavedPane(app, sp, opened, opts);
    // // changed (pane-rail): the colour the pane wore is put back over
    // the slot `PaneStore.add` just handed it. A pty holds its own
    // (`accent_color` on the pane, passed to `open`), so this is for
    // every other kind.
    if (id) |got| if (sp.kind != .pty) if (sp.accent) |name| try app.panes.setAccent(got, name);
    return id;
}

/// What a saved terminal pane comes back as.
pub const TerminalRestore = union(enum) {
    /// Rule 1 — a plain shell: a fresh one, in the cwd it was saved in.
    shell,
    /// Rule 2 — an AI session pane whose id was saved: `--resume <id>`
    /// when the session has a transcript, else `--session-id <id>`
    /// (`pty_pane.relaunchOf`).
    resumed: []const u8,
    /// Rule 3 — everything else: the tab, the title and
    /// `[exited] — any key restarts <name>`, starting nothing.
    dormant,
};

/// Whether `argv` carries `flag` with a value after it.
fn hasFlag(argv: []const []const u8, flag: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < argv.len) : (i += 1) if (std.mem.eql(u8, argv[i], flag)) return true;
    return false;
}

/// The restore rule for one saved pty pane.
///
/// A restart is meant to hand the workspace back the way it was left,
/// so the default is to bring the terminals back working:
///
///  1. A plain shell pane (no command line) comes back RUNNING — a
///     fresh shell in the saved cwd, which is cheap and harmless.
///  2. An AI session pane whose session id was saved RESUMES that
///     session — `claude --resume <id>`, `codex resume <id>`. Never a
///     NEW one: an id that did not survive the save is rule 3, not a
///     fresh billed session started behind the user's back. A Claude
///     session the user never typed into has no transcript to resume
///     (`claude --resume` of it is a hard error), so it starts again
///     under the same id — `--session-id <id>` — which is the session
///     it was, not a new one (`pty_pane.relaunchOf`).
///     // changed (codex-resume): Codex is in this rule now. Its id is
///     not on its command line — `codex` names itself only in the
///     rollout it writes — so `paneSessionId` looks it up at save time
///     (`ai/codex_rollout.zig`: the rollout opened in the pane's cwd at
///     or after the second the pane started, and ONLY when exactly one
///     answers to that). `codex resume --last` is never the fallback:
///     "the newest session on the machine" is not "this pane's
///     session".
///  3. Anything else — an arbitrary command line, a bare `claude` with
///     no id, a Codex pane whose session could not be named — comes
///     back DORMANT, waiting for a key. Re-running someone's build,
///     deploy or test command at launch is not a restore.
///
/// `session.restore_terminals = .dormant` is the one switch that puts
/// every pane in bucket 3, which is what mnml did for the day this rule
/// was the other way around.
pub fn terminalRestore(app: *const App, sp: Pane) TerminalRestore {
    if (app.cfg.session.restore_terminals == .dormant) return .dormant;
    if (sp.argv.len == 0) return .shell;
    // The field, or the argv it was read off — a file older than the
    // field still carries `--resume <id>`, and a restored Codex pane
    // carries `resume <id>`.
    const id = sp.session_id orelse pty_pane.sessionIdOfArgv(sp.argv) orelse pty_pane.codexSessionIdOfArgv(sp.argv) orelse return .dormant;
    if (id.len == 0) return .dormant;
    const claude = launch_profiles.isProductArgv(app, sp.argv[0], .claude);
    const codex = launch_profiles.isProductArgv(app, sp.argv[0], .codex);
    if (!claude and !codex) return .dormant;
    return .{ .resumed = id };
}

fn openSavedPane(app: *App, sp: Pane, opened: []const ?PaneId, opts: OpenOpts) OpenError!?PaneId {
    switch (sp.kind) {
        .editor => {
            if (sp.path.len == 0) return null;
            // A file that went away is not recreated as an empty buffer.
            Io.Dir.cwd().access(app.io, sp.path, .{}) catch return null;
            var id = app.openEditor(sp.path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
            for (opened) |o| if (o == id) {
                id = app.duplicatePane(id) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return null,
                };
                break;
            };
            const e = app.panes.editor(id) orelse return null;
            e.buf.editor.setCursor(@min(sp.cursor, e.buf.editor.len()));
            const lines: u32 = @intCast(@max(e.buf.editor.lineCount(), 1));
            e.view.scroll_line = @min(sp.scroll_line, lines - 1);
            e.view.scroll_col = sp.scroll_col;
            e.view.pinAt(e.buf.editor.cursor);
            e.wrap = sp.wrap;
            e.pinned = sp.pinned;
            for (sp.folds) |f| {
                if (f.start >= lines or f.end >= lines or f.end < f.start) continue;
                try e.buf.editor.folds.put(app.gpa, f.start, f.end);
            }
            for (sp.marks) |m| try e.buf.doc.setMarkPos(m.letter, .{ .row = m.row, .col = m.col });
            return id;
        },
        .md_preview => {
            if (sp.path.len == 0) return null;
            Io.Dir.cwd().access(app.io, sp.path, .{}) catch return null;
            return md_preview.open(app, sp.path, .here, null) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
        },
        // // changed (session-kinds): the query-shaped kinds. Each one
        // checks its subject first and returns null — quietly, no
        // toast, no empty shell — when the subject is gone.
        .image => {
            if (sp.path.len == 0) return null;
            Io.Dir.cwd().access(app.io, sp.path, .{}) catch return null;
            const id = image_pane.open(app, sp.path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            // A saved image tab is one the user kept, so it is not a
            // preview the next glance may take over.
            if (app.panes.get(id)) |p| if (p.* == .image) {
                p.image.is_preview = false;
            };
            return id;
        },
        .grep => {
            const q = sp.query orelse return null;
            return grep.restorePane(app, q, .{
                .case_sensitive = sp.grep_case,
                .whole_word = sp.grep_word,
                .regex = sp.grep_regex,
            }, sp.cursor);
        },
        .git_status => {
            const root = sp.repo orelse return null;
            const repo = (try git_app.repoByPath(app, root)) orelse return null;
            const id = git_app.openStatusPane(app, repo) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
            if (app.panes.get(id)) |p| if (p.* == .git_status) {
                p.git_status.cursor = sp.cursor;
                p.git_status.scroll = sp.scroll_line;
            };
            return id;
        },
        .git_graph => {
            const root = sp.repo orelse return null;
            const repo = (try git_app.repoByPath(app, root)) orelse return null;
            return git_app.ensureGraphPane(app, repo) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
        },
        .diff => {
            const root = sp.repo orelse return null;
            const scope = sp.diff_scope orelse return null;
            switch (scope) {
                .file, .worktree, .head, .staged => {},
                // Written by a newer build, or by hand: a revision
                // whose reachability this restore cannot check.
                .commit, .range, .orig, .conflict => return null,
            }
            const repo = (try git_app.repoByPath(app, root)) orelse return null;
            const rel: ?[]const u8 = if (sp.path.len > 0) sp.path else null;
            // A per-file diff of a file that went away is not a diff.
            if (scope == .file) {
                if (rel == null) return null;
                const abs = try std.fs.path.join(app.frame.allocator(), &.{ repo.path, rel.? });
                Io.Dir.cwd().access(app.io, abs, .{}) catch return null;
            }
            return git_app.openDiff(app, repo, scope, rel, sp.rev, null) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
        },
        .request => {
            if (sp.path.len == 0) return null;
            const idx = (try requestBlockIndex(app, sp.path, sp.block, sp.block_index)) orelse return null;
            return http_app.openFileBlock(app, sp.path, idx) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
        },
        .browser => {
            const url = sp.url orelse return null;
            return browser_pane.open(app, url) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
        },
        .mount => {
            if (!mount_pane.supported) return null;
            const id = sp.integration orelse return null;
            if (sp.argv.len == 0) return null;
            // The session restores before the startup scan: read the
            // manifests now, so the pane's own is there to resolve.
            if (app.integrations.generation == 0) integrations_app.refresh(app) catch return null;
            const idx = app.integrations.find(id) orelse return null;
            const m = app.integrations.list[idx].manifest;
            return integrations_app.openMount(app, .{
                .id = id,
                .binary = m.binary,
                .args = sp.argv[1..],
                .label = sp.label orelse m.label,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
        },
        .pty => {
            if (!pty_pane.supported) return null;
            // The three rules, in `terminalRestore`.
            const plan = terminalRestore(app, sp);
            const argv: []const []const u8 = switch (plan) {
                .shell => &.{},
                .dormant => sp.argv,
                .resumed => |id| blk: {
                    // A session still running in a pane is that pane,
                    // not a second `--resume` of it beside the first:
                    // two processes on one conversation append to one
                    // transcript and double the spend. The saved tree
                    // gets the live pane; a second saved copy of it
                    // (only a hand-edited file has one) gets nothing.
                    if (pty_pane.liveSessionPane(app, id)) |live| {
                        for (opened) |o| if (o == live) return null;
                        app.session.kept_live += 1;
                        return live;
                    }
                    // // changed (codex-resume): a Codex line is BUILT
                    // rather than patched — `codex` has no `--resume`
                    // flag to swap in, and its own prompt (a positional)
                    // must not be re-sent. `codexResumeArgv` keeps the
                    // pane's binary and the options `resume` accepts,
                    // and is idempotent on a line it already wrote.
                    if (launch_profiles.isProductArgv(app, sp.argv[0], .codex)) {
                        break :blk try cli.codexResumeArgv(app.frame.allocator(), sp.argv[0], id, sp.argv);
                    }
                    // The saved line keeps whatever else was on it
                    // (`--model`); its session flag is the relaunch
                    // rule's (`pty_pane.relaunchOf`): `--resume <id>`
                    // when Claude Code wrote a transcript for the id,
                    // else `--session-id <id>` again — a session nobody
                    // typed into has none, and resuming it is the CLI's
                    // "No conversation found" and exit 1. A file written
                    // before the line carried the id gets the canonical
                    // `claude <flag> <id>`: a restore must never start a
                    // SECOND session under an id that already exists.
                    const line = if (hasFlag(sp.argv, "--resume") or hasFlag(sp.argv, "--session-id")) sp.argv else try cli.claudeResumeArgv(app.frame.allocator(), id);
                    break :blk try pty_pane.relaunchArgv(app, app.frame.allocator(), line, sp.cwd);
                },
            };
            const id = pty_pane.open(app, .{
                .argv = argv,
                .cwd = sp.cwd,
                .label = sp.label,
                .renamed = sp.renamed,
                .placement = .tab,
                .kind = if (argv.len == 0) .shell else .command,
                .accent_color = sp.accent,
                .dormant = plan == .dormant and !opts.run_commands,
                // sessiondiff: a saved base is adopted, not re-taken.
                .record_changes = sp.changes_repo == null,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
            if (sp.changes_repo) |repo| try session_changes.adopt(app, id, .{ .repo = repo, .since_ms = sp.changes_since_ms, .head = sp.changes_head, .dirty = sp.changes_dirty });
            return id;
        },
    }
}

/// Which block of the `.http` file at `file` a saved request pane
/// named — the one at its saved position when that one still has the
/// saved name, else the first of that name (the leading block for
/// null). Null when the file went away or no longer has that block.
fn requestBlockIndex(app: *App, file: []const u8, block: ?[]const u8, at: ?u32) Allocator.Error!?u32 {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = Io.Dir.cwd().readFileAlloc(app.io, file, a, .limited(16 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const list = try http_parse.blocks(a, text);
    const Same = struct {
        fn is(b: http_parse.Block, want: ?[]const u8) bool {
            return if (want) |w| (b.name != null and std.mem.eql(u8, b.name.?, w)) else b.name == null;
        }
    };
    if (at) |i| if (i < list.len and Same.is(list[i], block)) return i;
    for (list, 0..) |b, i| if (Same.is(b, block)) return @intCast(i);
    // A file of one unnamed block reads as its leading block.
    return if (block == null and list.len > 0) 0 else null;
}

/// A `Layout` from a saved tab. Pane indices that did not come back
/// become `sentinel` tabs and are swept; a pool that is not a tree
/// (a node referenced twice, an index out of range) is an empty layout.
pub fn buildLayout(gpa: Allocator, tab: Tab, ids: []const ?PaneId) Allocator.Error!Layout {
    var l = Layout.init(gpa);
    errdefer l.deinit();
    if (!wellFormed(tab)) return l;
    for (tab.nodes) |n| switch (n) {
        .leaf => |lf| {
            var leaf: layout_mod.Leaf = .{ .active = sentinel, .tabs = .empty };
            errdefer leaf.tabs.deinit(gpa);
            for (lf.tabs) |ti| {
                const id: PaneId = if (ti < ids.len) (ids[ti] orelse sentinel) else sentinel;
                // Named twice in one tree (a hand-edited file): the
                // first leaf keeps it.
                const twice = id != sentinel and (l.leafOf(id) != null or std.mem.indexOfScalar(PaneId, leaf.tabs.items, id) != null);
                try leaf.tabs.append(gpa, if (twice) sentinel else id);
            }
            if (leaf.tabs.items.len == 0) try leaf.tabs.append(gpa, sentinel);
            const want: PaneId = if (lf.active < ids.len) (ids[lf.active] orelse sentinel) else sentinel;
            leaf.active = if (std.mem.indexOfScalar(PaneId, leaf.tabs.items, want) != null) want else leaf.tabs.items[0];
            try l.nodes.append(gpa, .{ .leaf = leaf });
        },
        .split => |s| try l.nodes.append(gpa, .{ .split = .{
            .dir = s.dir,
            .ratio = std.math.clamp(s.ratio, 10, 90),
            .first = s.first,
            .second = s.second,
        } }),
    };
    l.root = tab.root;
    while (l.leafOf(sentinel) != null) _ = l.removePane(sentinel);
    // After the sweep, which drops a zoom whenever it collapses a leaf.
    if (tab.zoomed) |zi| if (zi < ids.len) if (ids[zi]) |pid| if (l.leafOf(pid) != null) {
        l.zoomed = pid;
    };
    return l;
}

/// Every node referenced at most once, every reference in range, the
/// root in range, and a split's halves distinct.
fn wellFormed(tab: Tab) bool {
    const n = tab.nodes.len;
    if (n == 0) return tab.root == null;
    const root = tab.root orelse return false;
    if (root >= n or n > 4096) return false;
    var refs: [4096]u8 = @splat(0);
    refs[root] += 1;
    for (tab.nodes) |node| switch (node) {
        .leaf => {},
        .split => |s| {
            if (s.first >= n or s.second >= n or s.first == s.second) return false;
            refs[s.first] += 1;
            refs[s.second] += 1;
        },
    };
    for (refs[0..n]) |r| if (r != 1) return false;
    return true;
}

// ─── the commands ────────────────────────────────────────────────────────

pub fn saveCmd(app: *App) command.CommandError!void {
    save(app) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return app.diag.fail(app.frame.allocator(), "session: could not write {s}", .{relPath(app.profile())}),
    };
    app.toast("session saved ({d} pane(s), {d} tab(s))", .{ app.panes.count(), app.layouts.layouts.items.len });
}

pub fn restoreCmd(app: *App) command.CommandError!void {
    app.session.restored = false;
    try restore(app);
    if (!app.session.restored) return app.diag.fail(app.frame.allocator(), "session: nothing restored from {s}", .{relPath(app.profile())});
    const kept = app.session.kept_live;
    if (kept == 0) return app.toast("session restored", .{});
    app.toast("session restored · {d} AI session{s} already running, kept in {s} pane, not resumed again", .{ kept, if (kept == 1) "" else "s", if (kept == 1) "its" else "their" });
}

pub fn clearCmd(app: *App) command.CommandError!void {
    const file = try path(app, app.frame.allocator());
    Io.Dir.cwd().deleteFile(app.io, file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return app.diag.fail(app.frame.allocator(), "session: could not delete {s}: {s}", .{ relPath(app.profile()), @errorName(err) }),
    };
    // Off until `session.save` asks again, so quitting does not bring it back.
    app.session.autosave = false;
    app.toast("session cleared — the next launch starts clean", .{});
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

const Fixture = struct {
    tmp: t.TmpDir,
    root: []u8,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &pbuf);
        return .{ .tmp = tmp, .root = try t.allocator.dupe(u8, pbuf[0..n]) };
    }

    fn deinit(f: *Fixture) void {
        t.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn app(f: *Fixture) !App {
        return App.initWith(t.allocator, t.io, .{ .workspace = f.root, .cols = 120, .rows = 40 });
    }

    fn abs(f: *Fixture, rel: []const u8) ![]u8 {
        return std.fs.path.join(t.allocator, &.{ f.root, rel });
    }

    /// `git <args>` in the fixture's workspace (the test's own git, not
    /// the app's worker) — as `git.zig`'s fixture runs it.
    fn sh(f: *Fixture, args: []const []const u8) !void {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(t.allocator);
        try argv.appendSlice(t.allocator, &.{ "git", "-c", "user.email=t@mnml.dev", "-c", "user.name=tester" });
        try argv.appendSlice(t.allocator, args);
        const res = try std.process.run(t.allocator, t.io, .{ .argv = argv.items, .cwd = .{ .path = f.root } });
        defer t.allocator.free(res.stdout);
        defer t.allocator.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) return error.GitFailed;
    }

    /// Tick until every git job and every grep run has landed (or `max`
    /// ticks pass) — the restored panes are all asynchronous.
    fn settle(a: *App, max: usize) !void {
        var i: usize = 0;
        while (i < max) : (i += 1) {
            try a.tick(App.nowMs(t.io));
            if (!busy(a)) return;
            t.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }

    fn busy(a: *App) bool {
        if (a.git.status_pending or a.git.busy != 0 or a.git.rail_pending) return true;
        for (a.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
            .diff => |*d| if (d.pending) return true,
            .git_graph => |*g| if (g.pending or g.detail_pending) return true,
            .grep => |*g| if (g.loading) return true,
            else => {},
        };
        return false;
    }
};

test "session: each tab page's zoom comes back — page 1 zoomed on its second split, page 2 on its first, a page with no zoom writes none" {
    var f = try Fixture.init();
    defer f.deinit();
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt", "d.txt" }) |n| try f.tmp.dir.writeFile(t.io, .{ .sub_path = n, .data = "x\n" });
    const paths = [_][]u8{ try f.abs("a.txt"), try f.abs("b.txt"), try f.abs("c.txt"), try f.abs("d.txt") };
    defer for (paths) |p| t.allocator.free(p);
    {
        var app = try f.app();
        defer app.deinit();
        _ = try app.openPath(paths[0]);
        try command.run(&app, .{ .static = .@"view.split_right" });
        _ = try app.openPath(paths[1]);
        try command.run(&app, .{ .static = .@"view.toggle_zoom" });
        try command.run(&app, .{ .static = .@"tab.new" });
        _ = try app.openPath(paths[2]);
        try command.run(&app, .{ .static = .@"view.split_right" });
        _ = try app.openPath(paths[3]);
        app.setActive(app.panes.findPath(paths[2]).?);
        try command.run(&app, .{ .static = .@"view.toggle_zoom" });
        try command.run(&app, .{ .static = .@"tab.new" });
        try command.run(&app, .{ .static = .@"tab.first" });
        try save(&app);
        const text = try Io.Dir.cwd().readFileAlloc(t.io, try path(&app, app.frame.allocator()), app.frame.allocator(), .limited(1 << 20));
        // Two pages zoomed, the third not: two `.zoomed` fields.
        try t.expectEqual(@as(usize, 2), std.mem.count(u8, text, ".zoomed"));
    }
    {
        var app = try f.app();
        defer app.deinit();
        try restore(&app);
        try t.expectEqual(@as(usize, 3), app.layouts.layouts.items.len);
        try t.expectEqual(@as(usize, 0), app.layouts.active);
        try t.expectEqualStrings(paths[1], app.activeEditor().?.buf.doc.path.?);
        try t.expect(app.panes.editor(app.zoomedPane().?).?.buf.doc.isAt(paths[1]));
        try t.expectEqual(@as(usize, 2), (try app.layouts.current().leaves(app.frame.allocator())).len);
        const z2 = app.layouts.layouts.items[1].zoomed.?;
        try t.expect(app.panes.editor(z2).?.buf.doc.isAt(paths[2]));
        try t.expect(app.layouts.layouts.items[2].zoomed == null);
        // Switching to page 2 lands on its zoomed split and keeps it.
        try command.run(&app, .{ .static = .@"tab.next" });
        try t.expectEqual(z2, app.active.?);
        try t.expectEqual(z2, app.zoomedPane().?);
    }
}

test "session: save → restore brings back the panes, the split, the tab pages, the cursor, folds, pins and history" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "one\ntwo\nthree\nfour\n" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "b.txt", .data = "b\n" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "c.md", .data = "# c\n" });
    const a = try f.abs("a.txt");
    defer t.allocator.free(a);
    const b = try f.abs("b.txt");
    defer t.allocator.free(b);
    const c = try f.abs("c.md");
    defer t.allocator.free(c);
    {
        var app = try f.app();
        defer app.deinit();
        const ida = try app.openPath(a);
        const e = app.panes.editor(ida).?;
        e.buf.editor.setCursor(9); // "three"
        e.wrap = true;
        try e.buf.editor.folds.put(t.allocator, 1, 2);
        try e.buf.doc.setMarkPos('q', .{ .row = 3, .col = 0 });
        // A second file split to the right, a markdown preview on a second tab page.
        _ = try app.openPath(b);
        try command.run(&app, .{ .static = .@"view.split_right" });
        try command.run(&app, .{ .static = .@"tab.new" });
        _ = try md_preview.open(&app, c, .here, null);
        try command.run(&app, .{ .static = .@"tab.prev" });
        app.setActive(ida);
        try app.harpoon.set(t.allocator, 2, a);
        try app.noteCmdLine("set wrap");
        try command.run(&app, .{ .static = .noop });
        try command.run(&app, .{ .static = .@"view.toggle_line_numbers" });
        app.tree.width = 44;
        app.tree.visible = false;
        try app.toastLevel(.warn, "remember me", .{});
        app.zen = true;
        try save(&app);
    }
    {
        var app = try f.app();
        defer app.deinit();
        try restore(&app);
        try t.expect(app.session.restored);
        // Two tab pages; the first is active and holds a split.
        try t.expectEqual(@as(usize, 2), app.layouts.layouts.items.len);
        try t.expectEqual(@as(usize, 0), app.layouts.active);
        const leaves = try app.layouts.current().leaves(app.frame.allocator());
        try t.expectEqual(@as(usize, 2), leaves.len);
        // The active pane is a.txt with its cursor, wrap, fold and mark.
        const e = app.activeEditor().?;
        try t.expectEqualStrings(a, e.buf.doc.path.?);
        try t.expectEqual(@as(usize, 9), e.buf.editor.cursor);
        try t.expectEqual(true, e.wrap.?);
        try t.expectEqual(@as(usize, 2), e.buf.editor.folds.get(1).?);
        try t.expectEqual(@as(usize, 3), e.buf.doc.markPos('q').?.row);
        // The preview came back on the second page; b.txt's two windows
        // came back as two windows on one document.
        try t.expect(app.panes.findPreview(c) != null);
        var b_views: usize = 0;
        var b_doc: ?*const @import("../editor/document.zig").Document = null;
        for (app.panes.slots.items) |*slot| if (slot.*) |*p| if (p.asEditor()) |ep| if (ep.buf.doc.isAt(b)) {
            b_views += 1;
            if (b_doc) |d| try t.expect(d == ep.buf.doc) else b_doc = ep.buf.doc;
        };
        try t.expectEqual(@as(usize, 2), b_views);
        // Chrome and lists.
        try t.expectEqual(@as(u16, 44), app.tree.width);
        try t.expect(!app.tree.visible);
        try t.expect(app.zen);
        // A session that comes back in full screen says how to leave
        // (the chrome that would show the way is not painted).
        var reminded = false;
        for (app.toasts.items) |tt| if (std.mem.indexOf(u8, tt.text, "Full screen · Esc Esc") != null) {
            reminded = true;
        };
        try t.expect(reminded);
        try t.expectEqualStrings(a, app.harpoon.paths[2].?);
        try t.expectEqualStrings("set wrap", app.cmd_history.items[0]);
        // The command MRU came back newest first (the restore's own
        // commands are not in it: they ran before the file was read).
        try t.expectEqualStrings("view.toggle_line_numbers", app.recent_commands.items[0]);
        try t.expectEqualStrings("noop", app.recent_commands.items[1]);
        try t.expect(app.recent.items.len >= 2);
        var found = false;
        for (app.messages.items.items) |m| if (std.mem.eql(u8, m.text, "remember me")) {
            found = true;
        };
        try t.expect(found);
        // Round-trip: what the restored app would save equals what was read.
        var arena_state = std.heap.ArenaAllocator.init(t.allocator);
        defer arena_state.deinit();
        const again = try capture(&app, arena_state.allocator());
        try t.expectEqual(@as(usize, 4), again.panes.len);
        try t.expectEqual(@as(usize, 2), again.tabs.len);
        try t.expectEqual(@as(usize, 9), again.panes[again.active.?].cursor);
    }
}

test "session: a foreign workspace, a future version and a broken file are one toast each; a vanished file is skipped" {
    var f = try Fixture.init();
    defer f.deinit();
    var app = try f.app();
    defer app.deinit();
    try f.tmp.dir.createDirPath(t.io, ".mnml");
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = rel_path, .data = ".{ .workspace = \"/elsewhere\" }" });
    try restore(&app);
    try t.expect(!app.session.restored);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "belongs to /elsewhere") != null);
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = rel_path, .data = ".{ .version = 99 }" });
    try restore(&app);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "format v99") != null);
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = rel_path, .data = ".{ .workspace = " });
    try restore(&app);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "does not parse") != null);
    // A well-formed file naming a file that no longer exists restores nothing for it.
    const text = try std.fmt.allocPrint(t.allocator, ".{{ .workspace = \"{s}\", .panes = .{{ .{{ .path = \"{s}/gone.txt\" }} }}, .tabs = .{{ .{{ .nodes = .{{ .{{ .leaf = .{{ .active = 0, .tabs = .{{0}} }} }} }}, .root = 0 }} }}, .active = 0 }}", .{ f.root, f.root });
    defer t.allocator.free(text);
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = rel_path, .data = text });
    try restore(&app);
    try t.expect(app.session.restored);
    try t.expectEqual(@as(usize, 0), app.panes.count());
    try t.expect(app.layouts.current().isEmpty());
    // A pool that is not a tree is an empty layout, not a hang.
    try t.expect(!wellFormed(.{ .nodes = &.{ .{ .split = .{ .first = 0, .second = 1 } }, .{ .leaf = .{} } }, .root = 0 }));
    try t.expect(wellFormed(.{ .nodes = &.{ .{ .split = .{ .first = 1, .second = 2 } }, .{ .leaf = .{} }, .{ .leaf = .{} } }, .root = 0 }));
}

test "session: the workspace compare is by realpath — a symlinked spelling on either side restores, a different directory is still rejected" {
    var f = try Fixture.init();
    defer f.deinit();
    // `<root>/ws` is the workspace; `<root>/link` is another spelling of it;
    // `<root>/other` is a real directory that is not it.
    try f.tmp.dir.createDirPath(t.io, "ws/.mnml");
    try f.tmp.dir.createDirPath(t.io, "other");
    try f.tmp.dir.symLink(t.io, "ws", "link", .{ .is_directory = true });
    const ws = try f.abs("ws");
    defer t.allocator.free(ws);
    const link = try f.abs("link");
    defer t.allocator.free(link);
    const other = try f.abs("other");
    defer t.allocator.free(other);
    try t.expect(sameWorkspace(t.io, link, ws));
    try t.expect(sameWorkspace(t.io, ws, link));
    try t.expect(!sameWorkspace(t.io, other, ws));
    try t.expect(!sameWorkspace(t.io, "/elsewhere", ws));

    // The file names the unresolved spelling; the app runs on the resolved one.
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .cols = 120, .rows = 40 });
    defer app.deinit();
    const by_link = try std.fmt.allocPrint(t.allocator, ".{{ .workspace = \"{s}\" }}", .{link});
    defer t.allocator.free(by_link);
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/" ++ rel_path, .data = by_link });
    try restore(&app);
    try t.expect(app.session.restored);
    try t.expect(app.lastToast() == null);

    // The reverse: the file is canonical, the app was launched through the link.
    var via_link = try App.initWith(t.allocator, t.io, .{ .workspace = link, .cols = 120, .rows = 40 });
    defer via_link.deinit();
    const by_ws = try std.fmt.allocPrint(t.allocator, ".{{ .workspace = \"{s}\" }}", .{ws});
    defer t.allocator.free(by_ws);
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/" ++ rel_path, .data = by_ws });
    try restore(&via_link);
    try t.expect(via_link.session.restored);
    try t.expect(via_link.lastToast() == null);
    // …and what that app writes back is the resolved spelling, not the link.
    try save(&via_link);
    const written = try f.tmp.dir.readFileAlloc(t.io, "ws/" ++ rel_path, t.allocator, .limited(1 << 20));
    defer t.allocator.free(written);
    try t.expect(std.mem.indexOf(u8, written, ws) != null);
    try t.expect(std.mem.indexOf(u8, written, link) == null);

    // A real directory that is not this workspace is still one toast.
    const by_other = try std.fmt.allocPrint(t.allocator, ".{{ .workspace = \"{s}\" }}", .{other});
    defer t.allocator.free(by_other);
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/" ++ rel_path, .data = by_other });
    app.session.restored = false;
    try restore(&app);
    try t.expect(!app.session.restored);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "belongs to") != null);
}

test "session: clear deletes the file and stops the autosave; the timer writes every 30 s" {
    var f = try Fixture.init();
    defer f.deinit();
    var app = try f.app();
    defer app.deinit();
    app.session.autosave = true;
    app.session.last_save_ms = app.now_ms;
    tick(&app, app.now_ms + autosave_ms - 1);
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, rel_path, .{}));
    tick(&app, app.now_ms + autosave_ms);
    _ = try f.tmp.dir.statFile(t.io, rel_path, .{});
    try clearCmd(&app);
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, rel_path, .{}));
    try t.expect(!app.session.autosave);
    onExit(&app, .exit);
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, rel_path, .{}));
    try saveCmd(&app);
    _ = try f.tmp.dir.statFile(t.io, rel_path, .{});
}

test "session: the session worktrees ride in the file by path, the learned id with them, and come back" {
    var f = try Fixture.init();
    defer f.deinit();
    {
        var app = try f.app();
        defer app.deinit();
        try app.sessions.worktrees.add(t.allocator, "/w-worktrees/feat", "feat", "feat", "/w", null);
        try app.sessions.worktrees.add(t.allocator, "/w-worktrees/fix", "fix", "fix", "/w", "sid-7");
        try save(&app);
    }
    {
        var app = try f.app();
        defer app.deinit();
        try restore(&app);
        try t.expect(app.session.restored);
        try t.expectEqual(@as(usize, 2), app.sessions.worktrees.items.items.len);
        const feat = app.sessions.worktrees.byPath("/w-worktrees/feat").?;
        try t.expectEqualStrings("feat", feat.name);
        try t.expectEqualStrings("/w", feat.repo);
        try t.expect(feat.session_id == null);
        try t.expectEqualStrings("/w-worktrees/fix", app.sessions.worktrees.bySession("sid-7").?.path);
    }
}

test "session: the bottom dock round-trips — which section it shows, its height, and a section a user docked" {
    var f = try Fixture.init();
    defer f.deinit();
    {
        var app = try f.app();
        defer app.deinit();
        // The diagnostics start in the dock; open it, put TODOS there
        // too (so the dock's `last` is TODOS), and drag it taller.
        try command.run(&app, .{ .static = .@"view.toggle_bottom_panel" });
        try t.expectEqual(side_mod.Section.diagnostics, side_mod.shown(&app, .bottom).?);
        try side_mod.move(&app, .todos, .bottom);
        try side_mod.open(&app, .todos, false);
        side_mod.setSize(&app, .bottom, 18);
        try save(&app);
    }
    {
        var app = try f.app();
        defer app.deinit();
        try restore(&app);
        try t.expect(app.session.restored);
        try t.expectEqual(@as(u16, 18), side_mod.size(&app, .bottom));
        try t.expectEqual(Config.Side.bottom, side_mod.sideOf(&app, .todos));
        try t.expectEqual(side_mod.Section.todos, side_mod.shown(&app, .bottom).?);
        // A closed dock comes back closed, and its height with it.
        try command.run(&app, .{ .static = .@"view.toggle_bottom_panel" });
        try t.expect(side_mod.shown(&app, .bottom) == null);
        try save(&app);
    }
    {
        var app = try f.app();
        defer app.deinit();
        try restore(&app);
        try t.expect(side_mod.shown(&app, .bottom) == null);
        try t.expectEqual(@as(u16, 18), side_mod.size(&app, .bottom));
        // The toggle opens the first section that lives in the dock —
        // TODOS, in rail order — since a closed dock saved no `last`.
        try command.run(&app, .{ .static = .@"view.toggle_bottom_panel" });
        try t.expectEqual(side_mod.Section.todos, side_mod.shown(&app, .bottom).?);
    }
}

test "session: the session colours and a pty pane's accent ride in the file and come back" {
    // A POSIX shell script drives the pty.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    {
        var app = try f.app();
        defer app.deinit();
        try app.sessions.setColor(t.allocator, "sid-1", "blue");
        try app.sessions.setColor(t.allocator, "sid-2", "pink");
        const id = try pty_pane.open(&app, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" }, .label = "sh", .kind = .command, .placement = .tab });
        try pty_pane.setAccent(&app, id, "red");
        try save(&app);
    }
    {
        var app = try f.app();
        defer app.deinit();
        try restore(&app);
        try t.expect(app.session.restored);
        try t.expectEqualStrings("blue", app.sessions.color("sid-1").?);
        try t.expectEqualStrings("pink", app.sessions.color("sid-2").?);
        var found: ?[]const u8 = null;
        var dormant = false;
        for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
            .pty => |*pt| {
                found = pt.accent_color;
                dormant = pt.dormant and pt.session == null and pt.exit != null;
            },
            else => {},
        };
        try t.expectEqualStrings("red", found orelse return error.TestUnexpectedResult);
        // Rule 3: `/bin/sh -c "sleep 30"` is an arbitrary command line,
        // not a shell and not a session to resume, so the pane came
        // back and the child did not — nothing re-runs someone's
        // command at launch.
        try t.expect(dormant);
    }
}

test "session: an editor's rail colour rides in the file too, and a pane picked out of order keeps the one it had" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "one\n" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "b.txt", .data = "two\n" });
    const a = try f.abs("a.txt");
    defer t.allocator.free(a);
    const b = try f.abs("b.txt");
    defer t.allocator.free(b);
    {
        var app = try f.app();
        defer app.deinit();
        // Two editors off the ladder, then the second one picked: the
        // pick is the interesting one, because a restore that re-rolled
        // off the ladder would hand it green's neighbour again.
        const ida = try app.openPath(a);
        const idb = try app.openPath(b);
        try t.expectEqualStrings("green", pane_accent.nameOf(&app, ida).?);
        try pane_accent.setName(&app, idb, "purple");
        try save(&app);
    }
    {
        var app = try f.app();
        defer app.deinit();
        try restore(&app);
        try t.expect(app.session.restored);
        var seen: [2]?[]const u8 = .{ null, null };
        var n: usize = 0;
        for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| {
            if (p.* != .editor) continue;
            if (n < seen.len) seen[n] = pane_accent.nameOf(&app, @intCast(i));
            n += 1;
        };
        try t.expectEqual(@as(usize, 2), n);
        try t.expectEqualStrings("green", seen[0] orelse return error.TestUnexpectedResult);
        try t.expectEqualStrings("purple", seen[1] orelse return error.TestUnexpectedResult);
    }
}

test "session: the two profiles key the file apart — dev saves session-dev.zon and never touches the stable one" {
    var f = try Fixture.init();
    defer f.deinit();
    // Both profiles open the SAME workspace, which is the whole point:
    // you daily-drive a project and develop mnml in it on the same day.
    try f.tmp.dir.createDirPath(t.io, ".mnml");
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = rel_path, .data = ".{ .workspace = \"/elsewhere\" }" });

    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try env.put("MNML_PROFILE", "dev");
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = f.root, .cols = 120, .rows = 40, .env = &env });
    defer app.deinit();
    try t.expectEqual(config_profile.Profile.dev, app.profile());

    {
        const arena = app.frame.allocator();
        const p = try path(&app, arena);
        try t.expect(std.mem.endsWith(u8, p, rel_path_dev));
    }
    try save(&app);
    _ = try f.tmp.dir.statFile(t.io, rel_path_dev, .{});
    // The stable profile's file is exactly as it was left.
    const stable = try f.tmp.dir.readFileAlloc(t.io, rel_path, t.allocator, .limited(1 << 16));
    defer t.allocator.free(stable);
    try t.expectEqualStrings(".{ .workspace = \"/elsewhere\" }", stable);
    // And the dev profile does not read it either: a restore that found
    // the stable file would toast about /elsewhere.
    try restore(&app);
    try t.expect(app.session.restored);
}

/// The id a restore plan resumes, spelled so a rule that regressed
/// reads as a failed comparison rather than a panic on the union's
/// other field — which is what `.resumed` on a `.dormant` plan does,
/// and a panic takes the test binary down before the runner can say
/// which test failed.
fn resumedId(tr: TerminalRestore) []const u8 {
    return switch (tr) {
        .resumed => |id| id,
        else => "<not a resume>",
    };
}

test "session: the three terminal-restore rules, and the switch that overrides them" {
    var f = try Fixture.init();
    defer f.deinit();
    var app = try f.app();
    defer app.deinit();

    // Rule 1 — no command line at all is a plain shell: cheap to start,
    // harmless, and the pane is useless without it.
    try t.expect(terminalRestore(&app, .{ .kind = .pty }) == .shell);
    try t.expect(terminalRestore(&app, .{ .kind = .pty, .cwd = "/tmp" }) == .shell);

    // Rule 2 — a Claude line whose id was saved resumes THAT session.
    const claude: Pane = .{ .kind = .pty, .argv = &.{ "claude", "--resume", "sid-9" }, .session_id = "sid-9" };
    try t.expectEqualStrings("sid-9", resumedId(terminalRestore(&app, claude)));
    // The id off the argv alone — a file written before the field.
    const older: Pane = .{ .kind = .pty, .argv = &.{ "claude", "--resume", "sid-9" } };
    try t.expectEqualStrings("sid-9", resumedId(terminalRestore(&app, older)));
    // An absolute path to the binary is still Claude, and so is a line
    // that kept its other flags.
    const with_model: Pane = .{ .kind = .pty, .argv = &.{ "/opt/homebrew/bin/claude", "--model", "opus", "--resume", "sid-9" }, .session_id = "sid-9" };
    try t.expectEqualStrings("sid-9", resumedId(terminalRestore(&app, with_model)));

    // // changed (codex-resume): a Codex pane is rule 2 as well, off the
    // id `paneSessionId` looked up when the file was written — the
    // command line carries none when the session starts, and carries
    // `resume <id>` once a restore has built it.
    const codex_found: Pane = .{ .kind = .pty, .argv = &.{"codex"}, .session_id = "cdx-1" };
    try t.expectEqualStrings("cdx-1", resumedId(terminalRestore(&app, codex_found)));
    const codex_again: Pane = .{ .kind = .pty, .argv = &.{ "codex", "resume", "cdx-1" } };
    try t.expectEqualStrings("cdx-1", resumedId(terminalRestore(&app, codex_again)));
    const codex_abs: Pane = .{ .kind = .pty, .argv = &.{ "/opt/homebrew/bin/codex", "--search" }, .session_id = "cdx-1" };
    try t.expectEqualStrings("cdx-1", resumedId(terminalRestore(&app, codex_abs)));
    // A profile's shim is its product too, on either side.
    const profiles = [_]launch_profiles.Profile{.{ .name = "fast", .product = .codex, .binary = "codex", .args = &.{"--fast"} }};
    app.cfg.ai.launch_profiles = &profiles;
    const codex_shim: Pane = .{ .kind = .pty, .argv = &.{"/d/bin/mnml-ai-fast"}, .session_id = "cdx-1" };
    try t.expectEqualStrings("cdx-1", resumedId(terminalRestore(&app, codex_shim)));
    try t.expect(terminalRestore(&app, .{ .kind = .pty, .argv = &.{"/d/bin/mnml-ai-nope"}, .session_id = "cdx-1" }) == .dormant);

    // Rule 3 — anything else waits for a key. An arbitrary command line
    // (re-running someone's deploy at launch is not a restore); a bare
    // `claude` with no id, because a resume must never quietly become a
    // NEW billed session; and a Codex pane whose session could not be
    // named, because `--last` is not an answer to "which one was this".
    try t.expect(terminalRestore(&app, .{ .kind = .pty, .argv = &.{ "npm", "run", "deploy" } }) == .dormant);
    try t.expect(terminalRestore(&app, .{ .kind = .pty, .argv = &.{"claude"} }) == .dormant);
    try t.expect(terminalRestore(&app, .{ .kind = .pty, .argv = &.{"codex"} }) == .dormant);
    try t.expect(terminalRestore(&app, .{ .kind = .pty, .argv = &.{ "codex", "--search" } }) == .dormant);
    try t.expect(terminalRestore(&app, .{ .kind = .pty, .argv = &.{ "codex", "exec", "fix the tests" } }) == .dormant);
    // An empty id is no id.
    try t.expect(terminalRestore(&app, .{ .kind = .pty, .argv = &.{ "claude", "--resume", "" }, .session_id = "" }) == .dormant);
    try t.expect(terminalRestore(&app, .{ .kind = .pty, .argv = &.{"codex"}, .session_id = "" }) == .dormant);

    // The one switch puts every one of them in bucket 3 — what mnml did
    // for the day this rule was the other way around.
    app.cfg.session.restore_terminals = .dormant;
    try t.expect(terminalRestore(&app, .{ .kind = .pty }) == .dormant);
    try t.expect(terminalRestore(&app, claude) == .dormant);
    try t.expect(terminalRestore(&app, with_model) == .dormant);
    try t.expect(terminalRestore(&app, codex_found) == .dormant);
    try t.expect(terminalRestore(&app, codex_again) == .dormant);
    try t.expect(terminalRestore(&app, codex_shim) == .dormant);
}

/// The one pty pane an app has, for the round-trip tests below.
fn solePty(app: *App) ?*pty_pane.PtyPane {
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .pty => |*pt| return pt,
        else => {},
    };
    return null;
}

test "session: a restored shell pane comes back RUNNING, and `.dormant` is the switch that keeps it waiting" {
    // A real login shell drives the pty.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    {
        var app = try f.app();
        defer app.deinit();
        _ = try pty_pane.open(&app, .{ .argv = &.{}, .label = "sh", .kind = .shell, .placement = .tab });
        try save(&app);
    }
    {
        var app = try f.app();
        defer app.deinit();
        try restore(&app);
        const p = solePty(&app) orelse return error.TestUnexpectedResult;
        // The whole ask: a restart hands the shell back working.
        try t.expect(!p.dormant);
        try t.expect(p.session != null);
        try t.expect(p.exit == null);
        try t.expectEqual(@as(usize, 0), p.argv.len);
    }
    {
        var app = try f.app();
        defer app.deinit();
        app.cfg.session.restore_terminals = .dormant;
        try restore(&app);
        const p = solePty(&app) orelse return error.TestUnexpectedResult;
        try t.expect(p.dormant);
        try t.expect(p.session == null);
        try t.expect(p.exit != null);
    }
}

test "session: a restore in a running instance closes the panes it replaces — the shell count stays put" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "a\n" });
    const a = try f.abs("a.txt");
    defer t.allocator.free(a);
    var app = try f.app();
    defer app.deinit();
    _ = try app.openPath(a);
    _ = try pty_pane.open(&app, .{ .argv = &.{}, .label = "sh", .kind = .shell, .placement = .tab });
    try save(&app);
    const Count = struct {
        fn of(ap: *App) [2]usize {
            var n: [2]usize = .{ 0, 0 };
            for (ap.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
                .pty => |*pp| if (pp.session != null) {
                    n[0] += 1;
                },
                .editor => n[1] += 1,
                else => {},
            };
            return n;
        }
    };
    try t.expectEqual([2]usize{ 1, 1 }, Count.of(&app));
    for (0..3) |_| {
        try restore(&app);
        // One live shell and one editor, as saved — not one more a time.
        try t.expectEqual([2]usize{ 1, 1 }, Count.of(&app));
    }
    // A dirty editor is not the restore's to close: its pane survives.
    var dirty_id: ?PaneId = null;
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| if (p.* == .editor) {
        dirty_id = @intCast(i);
    };
    const de = app.panes.editor(dirty_id.?).?;
    try de.buf.editor.splice(0, 0, "x");
    de.buf.doc.dirty = true;
    try t.expect(app.panes.get(dirty_id.?).?.dirty());
    try restore(&app);
    try t.expect(app.panes.get(dirty_id.?) != null);
    try t.expect(app.panes.get(dirty_id.?).?.dirty());
}

test "session: a Claude pane's id rides in the file; the restored line resumes it when it has a transcript, and starts it again under the same id when it has none" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    // A fake `claude` — basename is what tells mnml the product, and
    // the real CLI is never run by a test.
    try f.tmp.dir.createDirPath(t.io, "bin");
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "bin/claude", .data = "#!/bin/sh\nprintf '%s ' \"$@\" >> argv.log\nsleep 30\n" });
    try f.tmp.dir.setFilePermissions(t.io, "bin/claude", .fromMode(0o755), .{});
    const fake = try f.abs("bin/claude");
    defer t.allocator.free(fake);
    {
        var app = try f.app();
        defer app.deinit();
        // As `ai.claude_code_new` starts one: a NEW session under an id
        // of mnml's own.
        _ = try pty_pane.open(&app, .{ .argv = &.{ fake, "--session-id", "sid-9" }, .label = "claude", .kind = .command, .placement = .tab });
        try save(&app);
    }
    const text = try f.tmp.dir.readFileAlloc(t.io, rel_path, t.allocator, .limited(1 << 16));
    defer t.allocator.free(text);
    // The id is written down, spelled as the resume.
    try t.expect(std.mem.indexOf(u8, text, "sid-9") != null);
    try t.expect(std.mem.indexOf(u8, text, "--resume") != null);
    try t.expect(std.mem.indexOf(u8, text, "--session-id") == null);
    // No transcript — nothing was typed into it: `claude --resume` of
    // the id would be "No conversation found" and exit 1, so it starts
    // again under the same id.
    {
        var app = try f.app();
        defer app.deinit();
        app.sessions.home = try std.fs.path.join(t.allocator, &.{ f.root, "home" });
        try restore(&app);
        const p = solePty(&app) orelse return error.TestUnexpectedResult;
        try t.expect(!p.dormant);
        try t.expect(p.session != null);
        try t.expectEqual(@as(usize, 3), p.argv.len);
        try t.expectEqualStrings("--session-id", p.argv[1]);
        try t.expectEqualStrings("sid-9", p.argv[2]);
    }
    // Claude wrote one (the first message): the restore resumes it.
    // Claude Code's directory name for the cwd — every byte that is not
    // an ASCII letter or digit becomes `-` (the temp root's `_` too).
    const enc = try t.allocator.dupe(u8, f.root);
    defer t.allocator.free(enc);
    for (enc) |*c| if (!std.ascii.isAlphanumeric(c.*)) {
        c.* = '-';
    };
    const dir = try std.fs.path.join(t.allocator, &.{ "home", ".claude", "projects", enc });
    defer t.allocator.free(dir);
    try f.tmp.dir.createDirPath(t.io, dir);
    const file = try std.fs.path.join(t.allocator, &.{ dir, "sid-9.jsonl" });
    defer t.allocator.free(file);
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = file, .data = "{\"type\":\"user\"}\n" });
    {
        var app = try f.app();
        defer app.deinit();
        app.sessions.home = try std.fs.path.join(t.allocator, &.{ f.root, "home" });
        try restore(&app);
        const p = solePty(&app) orelse return error.TestUnexpectedResult;
        try t.expect(!p.dormant);
        try t.expect(p.session != null);
        try t.expectEqual(@as(usize, 3), p.argv.len);
        try t.expectEqualStrings("--resume", p.argv[1]);
        try t.expectEqualStrings("sid-9", p.argv[2]);
    }
}

test "session: restore over a session still running keeps its pane — no second `--resume` of a live id, and the toast says so" {
    // sess-resume-live-session-twice.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDirPath(t.io, "bin");
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "bin/claude", .data = "#!/bin/sh\nsleep 30\n" });
    try f.tmp.dir.setFilePermissions(t.io, "bin/claude", .fromMode(0o755), .{});
    const fake = try f.abs("bin/claude");
    defer t.allocator.free(fake);
    var app = try f.app();
    defer app.deinit();
    const live = try pty_pane.open(&app, .{ .argv = &.{ fake, "--session-id", "sid-live" }, .label = "claude", .kind = .command, .placement = .tab });
    try t.expectEqual(live, pty_pane.liveSessionPane(&app, "sid-live").?);
    try t.expect(pty_pane.liveSessionPane(&app, "sid-other") == null);
    try save(&app);
    try restoreCmd(&app);
    // One pty in the store — the live one, shown by the restored tree.
    var ptys: usize = 0;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .pty => ptys += 1,
        else => {},
    };
    try t.expectEqual(@as(usize, 1), ptys);
    try t.expectEqual(@as(u16, 1), app.session.kept_live);
    try t.expect(app.layouts.current().leafOf(live) != null);
    var said = false;
    for (app.toasts.items) |ts| if (std.mem.indexOf(u8, ts.text, "already running") != null) {
        said = true;
    };
    try t.expect(said);
}

/// `secs` as the UTC ISO-8601 stamp a rollout's first line carries —
/// what the real `codex` writes when it opens one.
fn isoUtc(arena: Allocator, secs: i64) ![]u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        yd.year,
        md.month.numeric(),
        @as(u16, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}

test "session: a Codex pane's session is looked up from its rollout, rides in the file, and the restored line resumes it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    // A fake `codex` — the basename is what tells mnml the product, and
    // the real CLI is never run by a test.
    try f.tmp.dir.createDirPath(t.io, "bin");
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "bin/codex", .data = "#!/bin/sh\nprintf '%s ' \"$@\" >> argv.log\nsleep 30\n" });
    try f.tmp.dir.setFilePermissions(t.io, "bin/codex", .fromMode(0o755), .{});
    const fake = try f.abs("bin/codex");
    defer t.allocator.free(fake);
    const home = try f.abs("home");
    defer t.allocator.free(home);
    // Hex, because a rollout name that is not shaped like a uuid is not
    // a session id.
    const sid = "abcdabcd-0000-4000-8000-0000000c0dec";
    {
        var app = try f.app();
        defer app.deinit();
        // The fixture's home, so the lookup never reads the developer's
        // own `~/.codex`.
        try app.env.put("HOME", home);
        // As `ai.codex_new` starts one: no session id anywhere on the
        // line, because Codex takes none.
        _ = try pty_pane.open(&app, .{ .argv = &.{fake}, .label = "codex", .kind = .command, .placement = .tab });
        const pt = solePty(&app) orelse return error.TestUnexpectedResult;
        try t.expect(pt.started_at_s > 0);
        try t.expect(pt.codex_session_id == null);

        // The rollout that child would have opened: this workspace,
        // this second.
        const arena = app.frame.allocator();
        try f.tmp.dir.createDirPath(t.io, "home/.codex/sessions/2026/09/21");
        const name = try std.fmt.allocPrint(arena, "home/.codex/sessions/2026/09/21/rollout-now-{s}.jsonl", .{sid});
        const line = try std.fmt.allocPrint(
            arena,
            "{{\"timestamp\":\"{s}\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"{s}\",\"cwd\":\"{s}\"}}}}\n",
            .{ try isoUtc(arena, pt.started_at_s), sid, f.root },
        );
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = line });

        try save(&app);
        // Learned at save time and kept: the pane knows its session now.
        try t.expectEqualStrings(sid, pt.codex_session_id orelse "<not found>");
    }
    const text = try f.tmp.dir.readFileAlloc(t.io, rel_path, t.allocator, .limited(1 << 16));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, sid) != null);
    {
        var app = try f.app();
        defer app.deinit();
        try app.env.put("HOME", home);
        try restore(&app);
        const p = solePty(&app) orelse return error.TestUnexpectedResult;
        try t.expect(!p.dormant);
        try t.expect(p.session != null);
        try t.expectEqual(@as(usize, 3), p.argv.len);
        // The pane's own binary, `resume`, and the id it was found under
        // — never `--last`, and never a second session.
        try t.expectEqualStrings(fake, p.argv[0]);
        try t.expectEqualStrings("resume", p.argv[1]);
        try t.expectEqualStrings(sid, p.argv[2]);
    }
}

test "session: a Codex pane whose session cannot be named uniquely comes back dormant, not resumed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDirPath(t.io, "bin");
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "bin/codex", .data = "#!/bin/sh\nsleep 30\n" });
    try f.tmp.dir.setFilePermissions(t.io, "bin/codex", .fromMode(0o755), .{});
    const fake = try f.abs("bin/codex");
    defer t.allocator.free(fake);
    const home = try f.abs("home");
    defer t.allocator.free(home);
    {
        var app = try f.app();
        defer app.deinit();
        try app.env.put("HOME", home);
        _ = try pty_pane.open(&app, .{ .argv = &.{fake}, .label = "codex", .kind = .command, .placement = .tab });
        const pt = solePty(&app) orelse return error.TestUnexpectedResult;
        const arena = app.frame.allocator();
        const iso = try isoUtc(arena, pt.started_at_s);
        try f.tmp.dir.createDirPath(t.io, "home/.codex/sessions/2026/09/21");
        // TWO sessions of this workspace inside the window — a second
        // Codex started in the same directory while this one was still
        // finding its feet. Which one is this pane's cannot be told, so
        // neither is the answer.
        for ([_][]const u8{ "abcdabcd-0000-4000-8000-00000000000a", "abcdabcd-0000-4000-8000-00000000000b" }) |id| {
            const name = try std.fmt.allocPrint(arena, "home/.codex/sessions/2026/09/21/rollout-now-{s}.jsonl", .{id});
            const line = try std.fmt.allocPrint(
                arena,
                "{{\"timestamp\":\"{s}\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"{s}\",\"cwd\":\"{s}\"}}}}\n",
                .{ iso, id, f.root },
            );
            try f.tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = line });
        }
        try save(&app);
        try t.expect(pt.codex_session_id == null);
    }
    {
        var app = try f.app();
        defer app.deinit();
        try app.env.put("HOME", home);
        try restore(&app);
        const p = solePty(&app) orelse return error.TestUnexpectedResult;
        // Rule 3: the tab is back, nothing was started, and no
        // stranger's conversation was resumed.
        try t.expect(p.dormant);
        try t.expect(p.session == null);
        try t.expectEqual(@as(usize, 1), p.argv.len);
    }
}

// ─── the query-shaped kinds (session-kinds) ─────────────────────────────

test "session: git status, Search, the commit graph, a worktree diff and an image come back, each by re-running its query" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "one needle two\nplain\n" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "shot.png", .data = "\x89PNG\r\n\x1a\n" });
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.sh(&.{ "add", "." });
    try f.sh(&.{ "commit", "-q", "-m", "first" });
    // A worktree diff needs something to diff; two hits give the
    // Search a third row, so a cursor of 2 is a row and not a clamp.
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "one needle two\nneedle again\n" });
    const png = try f.abs("shot.png");
    defer t.allocator.free(png);
    const txt = try f.abs("a.txt");
    defer t.allocator.free(txt);

    var leaves_before: usize = 0;
    {
        var app = try f.app();
        defer app.deinit();
        _ = try app.openPath(txt);
        const repo = (try git_app.repoByPath(&app, f.root)).?;
        const sid = try git_app.openStatusPane(&app, repo);
        app.panes.get(sid).?.git_status.cursor = 1;
        app.showPane(try git_app.ensureGraphPane(&app, repo));
        _ = try git_app.openDiff(&app, repo, .worktree, null, null, null);
        const gid = (try grep.restorePane(&app, "needle", .{ .regex = true, .whole_word = true }, 0)).?;
        app.showPane(gid);
        // The image opens AFTER the Search: adding a pane grows the
        // store, which moves every pane in it, and a run in flight has
        // to survive that (`GrepPane.group`).
        const iid = try image_pane.open(&app, png);
        app.panes.get(iid).?.image.is_preview = false;
        try Fixture.settle(&app, 400);
        // The row the review was ON, not the first one.
        app.panes.get(gid).?.grep.cursor = 2;
        leaves_before = (try app.layouts.current().leaves(app.frame.allocator())).len;
        try save(&app);
    }
    {
        var app = try f.app();
        defer app.deinit();
        try restore(&app);
        try t.expect(app.session.restored);
        try Fixture.settle(&app, 400);

        const sid = app.panes.findKind(.git_status).?;
        const st = &app.panes.get(sid).?.git_status;
        try t.expectEqualStrings(f.root, app.git.repoById(st.repo).?.path);
        try t.expectEqual(@as(usize, 1), st.cursor);

        const gid = app.panes.findKind(.grep).?;
        const g = &app.panes.get(gid).?.grep;
        try t.expectEqualStrings("needle", g.query);
        try t.expect(g.flags.regex);
        try t.expect(g.flags.whole_word);
        // The query really ran against today's files, and the cursor
        // came back on the row it was on — which can only be put back
        // once the run says it is done, since the hits arrive in
        // batches and every batch clamps the cursor to what it has.
        try t.expect(g.hits.items.len > 0);
        try t.expectEqual(@as(usize, 2), g.cursor);
        try t.expect(g.restore_cursor == null);

        const graph = app.panes.findKind(.git_graph).?;
        try t.expectEqualStrings(f.root, app.git.repoById(app.panes.get(graph).?.git_graph.repo).?.path);

        const did = app.panes.findKind(.diff).?;
        try t.expectEqual(git_client.DiffScope.worktree, app.panes.get(did).?.diff.scope);

        const iid = app.panes.findKind(.image).?;
        try t.expectEqualStrings(png, app.panes.get(iid).?.image.path);

        // Each came back in a leaf of its own, as many as there were.
        const layout = app.layouts.current();
        try t.expectEqual(leaves_before, (try layout.leaves(app.frame.allocator())).len);
        for ([_]PaneId{ sid, gid, graph, did, iid }) |id| try t.expect(layout.leafOf(id) != null);
    }
}

test "session: a query-shaped pane whose subject is gone is skipped — no pane, no toast" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "one needle two\n" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "shot.png", .data = "\x89PNG\r\n\x1a\n" });
    try f.sh(&.{ "init", "-q", "-b", "main" });
    try f.sh(&.{ "add", "." });
    try f.sh(&.{ "commit", "-q", "-m", "first" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "one needle three\n" });
    const png = try f.abs("shot.png");
    defer t.allocator.free(png);
    const txt = try f.abs("a.txt");
    defer t.allocator.free(txt);
    {
        var app = try f.app();
        defer app.deinit();
        _ = try app.openPath(txt);
        const repo = (try git_app.repoByPath(&app, f.root)).?;
        _ = try git_app.openStatusPane(&app, repo);
        _ = try git_app.ensureGraphPane(&app, repo);
        _ = try git_app.openDiff(&app, repo, .file, "a.txt", null, null);
        _ = (try grep.restorePane(&app, "needle", .{}, 0)).?;
        const iid = try image_pane.open(&app, png);
        app.panes.get(iid).?.image.is_preview = false;
        try Fixture.settle(&app, 400);
        try save(&app);
    }
    // The workspace stops being a repo, the diffed file and the image go.
    try f.tmp.dir.deleteTree(t.io, ".git");
    try f.tmp.dir.deleteFile(t.io, "shot.png");
    try f.tmp.dir.deleteFile(t.io, "a.txt");
    // A Search pane with no query is a pane with no subject.
    {
        var app = try f.app();
        defer app.deinit();
        var arena_state = std.heap.ArenaAllocator.init(t.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        try apply(&app, arena, .{
            .workspace = f.root,
            .panes = &.{.{ .kind = .grep, .query = "" }},
        });
        try t.expect(app.panes.findKind(.grep) == null);
    }
    {
        var app = try f.app();
        defer app.deinit();
        try restore(&app);
        try t.expect(app.session.restored);
        try Fixture.settle(&app, 400);
        // Every git pane's repo is gone, the image's file is gone, and
        // the per-file diff has no file: none of them came back, and
        // nothing was said about it.
        try t.expect(app.panes.findKind(.git_status) == null);
        try t.expect(app.panes.findKind(.git_graph) == null);
        try t.expect(app.panes.findKind(.diff) == null);
        try t.expect(app.panes.findKind(.image) == null);
        for (app.toasts.items) |tt| {
            try t.expect(std.mem.indexOf(u8, tt.text, "git status") == null);
            try t.expect(std.mem.indexOf(u8, tt.text, "shot.png") == null);
        }
        // The Search pane's subject is the query, which cannot vanish:
        // it comes back and finds nothing, which is an answer.
        try t.expect(app.panes.findKind(.grep) != null);
    }
}

test "session: a file from the old field set still loads; an unknown pane kind is one toast, not a crash" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "hello\n" });
    const a = try f.abs("a.txt");
    defer t.allocator.free(a);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Written before the query-shaped kinds existed: no `repo`, no
    // `query`, no `grep_*`, no `diff_scope`, no `rev`.
    const old = try std.fmt.allocPrintSentinel(arena, ".{{ .version = 1, .workspace = \"{s}\", .panes = .{{ .{{ .kind = .editor, .path = \"{s}\", .cursor = 2 }} }}, .tabs = .{{ .{{ .nodes = .{{ .{{ .leaf = .{{ .active = 0, .tabs = .{{0}} }} }} }}, .root = 0 }} }} }}", .{ f.root, a }, 0);
    const parsed = try parse(arena, old);
    try t.expectEqual(@as(usize, 1), parsed.panes.len);
    try t.expectEqual(PaneKind.editor, parsed.panes[0].kind);
    try t.expect(parsed.panes[0].repo == null);
    try t.expect(parsed.panes[0].query == null);
    try t.expect(parsed.panes[0].diff_scope == null);
    {
        var app = try f.app();
        defer app.deinit();
        try apply(&app, arena, parsed);
        try t.expectEqual(@as(usize, 2), app.activeEditor().?.buf.editor.cursor);
    }

    // A kind a later build added: the whole file is ignored with the
    // "does not parse" toast — never a crash, never half a layout.
    const newer = try std.fmt.allocPrintSentinel(arena, ".{{ .version = 1, .workspace = \"{s}\", .panes = .{{ .{{ .kind = .hologram, .path = \"{s}\" }} }} }}", .{ f.root, a }, 0);
    try t.expectError(error.ParseZon, parse(arena, newer));
    {
        var app = try f.app();
        defer app.deinit();
        const file = try path(&app, arena);
        try f.tmp.dir.createDirPath(t.io, ".mnml");
        try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = file, .data = newer });
        try restore(&app);
        try t.expect(!app.session.restored);
        try t.expect(std.mem.indexOf(u8, app.lastToast().?, "does not parse") != null);
    }

    // And a field a later build added is ignored, not a parse failure.
    const extra = try std.fmt.allocPrintSentinel(arena, ".{{ .version = 1, .workspace = \"{s}\", .panes = .{{ .{{ .kind = .editor, .path = \"{s}\", .telepathy = true }} }} }}", .{ f.root, a }, 0);
    const ok = try parse(arena, extra);
    try t.expectEqual(@as(usize, 1), ok.panes.len);
}

test "session: an integration pane is written as its manifest and command line, and one whose manifest is gone is skipped" {
    // hunt/findings-2026-09-23/integ-panes-lost-on-restart.md
    var a_state = std.heap.ArenaAllocator.init(t.allocator);
    defer a_state.deinit();
    const arena = a_state.allocator();
    const text = try render(arena, .{
        .workspace = "/w",
        .panes = &.{.{ .kind = .mount, .integration = "jira_work", .argv = &.{ "/bin/mnml-jira", "--only", "work" }, .label = "Jira Work" }},
    });
    try t.expect(std.mem.indexOf(u8, text, ".kind = .mount") != null);
    const back = try parse(arena, try arena.dupeZ(u8, text));
    try t.expectEqual(PaneKind.mount, back.panes[0].kind);
    try t.expectEqualStrings("jira_work", back.panes[0].integration.?);
    try t.expectEqualStrings("--only", back.panes[0].argv[1]);
    // No manifest by that id on this machine: nothing to reopen it
    // with, so no pane — and no guess at a binary.
    var f = try Fixture.init();
    defer f.deinit();
    var app = try f.app();
    defer app.deinit();
    // As if the scan had run and found nothing — the test must never
    // read (let alone spawn from) the machine's own manifests.
    app.integrations.generation = 1;
    try t.expect((try openSavedPane(&app, back.panes[0], &.{}, .{})) == null);
}
