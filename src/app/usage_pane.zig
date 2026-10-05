//! The usage panes (`Pane.ai_usage`: `ai.claude_usage` / `ai.codex_usage`)
//! and the app side of the usage reader (`src/ai/usage.zig`): the owned
//! per-account snapshots the chip and the panes read, the fetch
//! cadence, the workers, the keys.
//!
//!   D1  a worker's `*usage.Result` rides `AppEvent.usage`; `handle`
//!       copies what it keeps onto the account's own arena and destroys
//!       it; a job's argument strings are the worker's to free;
//!   D3  one `Io.Group` for every usage worker (`State.group`), cancelled
//!       at deinit; a result for an account no longer configured is
//!       dropped;
//!   D2  the workers never toast; the identity warning rides the result.
//!
//! `MNML_CLAUDE_USAGE_FIXTURE` (read once, from the app's environment)
//! swaps the wire for the fixture directory — the `.test` corpus, the
//! spec dumps and the unit tests use it.

const std = @import("std");
const repeat = @import("mnml_sdk").zig_compat.repeat;
/// The one "does this pane have the keys" (`render.paneFocused`).
const paneFocused = @import("render.zig").paneFocused;
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = app_mod.Key;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const usage = @import("../ai/usage.zig");
const usage_view = @import("../ui/usage_view.zig");
const clock = @import("clock.zig");
const pty_pane = @import("pty_pane.zig");
const Ui = @import("../ui/context.zig");
const Rect = @import("../ui/rect.zig");
const settings = @import("settings.zig");
const context_menus = @import("context_menus.zig");
const config_persist = @import("../config/persist.zig");
const ClaudeAccount = app_mod.Config.ClaudeAccount;
const MenuItem = command.MenuItem;

pub const Product = enum { claude, codex };

/// `Pane.ai_usage`: a product and a scroll offset.
pub const UsagePane = struct {
    product: Product,
    scroll: usize = 0,
    /// The account (by its place in the list) the next paint scrolls to
    /// — the chip's `!` opens the pane at the account that needs it.
    scroll_to: ?usize = null,

    /// The tab's words — Rust's `tab_title`.
    pub fn title(p: *const UsagePane) []const u8 {
        return switch (p.product) {
            .claude => "Claude Usage",
            .codex => "Codex Usage",
        };
    }
};

/// One account's snapshot; every slice lives on its own arena, rebuilt
/// on each result so a stale reading is never left dangling.
pub const Account = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    usage: usage.Usage = .{},
    email: ?[]const u8 = null,
    org: ?[]const u8 = null,
    is_active: bool = false,

    pub fn view(a: *const Account) usage_view.AccountView {
        return .{ .name = a.name, .usage = a.usage, .email = a.email, .org = a.org, .is_active = a.is_active };
    }

    pub fn chip(a: *const Account) usage.ChipAccount {
        return .{ .name = a.name, .usage = a.usage, .is_active = a.is_active };
    }
};

/// The per-account schedule: when it was last spawned, whether a fetch
/// is in flight.
const Sched = struct {
    name: []u8,
    last_at: u64 = 0,
    pending: bool = false,
    /// The fetch in flight renews an expired token (`expired —
    /// refreshing…`).
    renewing: bool = false,
};

/// A Re-auth in flight: the account, the `claude login` pane it opened,
/// the keychain's refresh token when it started — a login has landed
/// once that changes.
const Reauth = struct {
    name: []u8,
    pane: ?PaneId,
    baseline: ?[]u8 = null,
    baseline_set: bool = false,
    last_poll_ms: i64 = 0,
    /// The login pane has exited or closed: one last read, then done.
    final: bool = false,
    final_polled: bool = false,

    fn deinit(r: *Reauth, gpa: Allocator) void {
        gpa.free(r.name);
        if (r.baseline) |b| gpa.free(b);
    }
};

/// How often a Re-auth reads the keychain while its login runs.
pub const reauth_poll_ms: i64 = 1500;

pub const State = struct {
    group: Io.Group = .init,
    accounts: std.ArrayListUnmanaged(Account) = .empty,
    sched: std.ArrayListUnmanaged(Sched) = .empty,
    codex: ?usage.Codex = null,
    /// Owned; `codex.last_error` points into it.
    codex_error: ?[]u8 = null,
    codex_pending: bool = false,
    codex_last_at: u64 = 0,
    last_spawn_at: u64 = 0,
    /// The keychain's refresh token: which account the CLI is logged
    /// in as. Owned.
    keychain_rt: ?[]u8 = null,
    keychain_pending: bool = false,
    keychain_last_at: u64 = 0,
    /// The Re-auth in flight, when one is.
    reauth: ?Reauth = null,
    /// The keychain refresh token the silent re-capture last looked at
    /// (owned): one look per login, so one toast.
    recapture_seen: ?[]u8 = null,
    /// `MNML_CLAUDE_USAGE_FIXTURE`, owned; read once.
    fixture: ?[]u8 = null,
    fixture_checked: bool = false,
    now_override: ?u64 = null,
    tz_override: ?i64 = null,
    /// The ticker chip's last slot, to repaint when it moves.
    ticker_slot: u64 = 0,
    dup_warned: bool = false,
    /// Owns `app.cfg.ai.claude_accounts` once an account has been added,
    /// renamed or removed here (the loader's arena owned the list it
    /// read). A reload points the config back at the loader's.
    cfg_arena: ?std.heap.ArenaAllocator = null,
    /// `account\x00key` for every unknown usage key already logged (owned
    /// keys), and how many have been — the tests read the count.
    unknown_seen: std.StringHashMapUnmanaged(void) = .empty,
    unknown_logged: usize = 0,

    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.group.cancel(io);
        if (self.cfg_arena) |*a| a.deinit();
        var kit = self.unknown_seen.keyIterator();
        while (kit.next()) |k| gpa.free(k.*);
        self.unknown_seen.deinit(gpa);
        for (self.accounts.items) |*a| a.arena.deinit();
        self.accounts.deinit(gpa);
        for (self.sched.items) |s| gpa.free(s.name);
        self.sched.deinit(gpa);
        if (self.codex_error) |e| gpa.free(e);
        if (self.keychain_rt) |k| gpa.free(k);
        if (self.recapture_seen) |k| gpa.free(k);
        if (self.reauth) |*r| r.deinit(gpa);
        if (self.fixture) |f| gpa.free(f);
    }

    pub fn find(self: *State, name: []const u8) ?*Account {
        for (self.accounts.items) |*a| if (std.mem.eql(u8, a.name, name)) return a;
        return null;
    }

    fn schedFor(self: *State, name: []const u8) ?*Sched {
        for (self.sched.items) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }

    /// The account the chip shows alone: the active one, else the first.
    pub fn active(self: *State) ?*Account {
        for (self.accounts.items) |*a| if (a.is_active) return a;
        return if (self.accounts.items.len > 0) &self.accounts.items[0] else null;
    }

    pub fn anyPending(self: *const State) bool {
        for (self.sched.items) |s| if (s.pending) return true;
        return self.codex_pending;
    }
};

fn st(app: *App) *State {
    return &app.ai.usage;
}

// ─── the source ─────────────────────────────────────────────────────────

/// The fixture directory, when the environment names one.
pub fn fixtureDir(app: *App) ?[]const u8 {
    const s = st(app);
    if (!s.fixture_checked) {
        s.fixture_checked = true;
        if (app.env.get(usage.fixture_env)) |dir| if (dir.len > 0) {
            s.fixture = app.gpa.dupe(u8, dir) catch null;
            if (s.fixture) |d| {
                s.now_override = usage.fixtureNow(app.io, d);
                s.tz_override = usage.fixtureTz(app.io, d);
            }
        };
    }
    return s.fixture;
}

/// Unix seconds: the fixture's clock, else the wall clock.
pub fn nowSecs(app: *App) u64 {
    _ = fixtureDir(app);
    if (st(app).now_override) |n| return n;
    return @intCast(@max(Io.Timestamp.now(app.io, .real).toSeconds(), 0));
}

/// Seconds east of UTC for the reset clocks.
pub fn tzOffset(app: *App, secs: u64) i64 {
    _ = fixtureDir(app);
    return st(app).tz_override orelse clock.localOffset(@intCast(secs));
}

/// The configured accounts, resolved: the fixture's `accounts` file
/// when it has one, else `.ai.claude_accounts`, else the 0.2.x
/// `[[ai.claude.accounts]]` blocks as the migration left them
/// (`.ai.claude.accounts`, kept verbatim under `extra`).
pub fn configured(app: *App, arena: Allocator) Allocator.Error![]usage.AccountCfg {
    if (fixtureDir(app)) |dir| if (try usage.fixtureAccounts(arena, app.io, dir)) |list| return list;
    if (app.cfg.ai.claude_accounts.len == 0) if (try accountsFromExtra(arena, app.cfg.ai.extra)) |list| return usage.accountsFromConfig(arena, list, app.data_root, app.homeDir());
    return usage.accountsFromConfig(arena, app.cfg.ai.claude_accounts, app.data_root, app.homeDir());
}

/// `.ai.claude.accounts` off the verbatim tree: `name` / `token_path`
/// strings, an `active` bool. Null when the tree has no such list.
fn accountsFromExtra(arena: Allocator, extra: app_mod.Config.Dynamic) Allocator.Error!?[]app_mod.Config.ClaudeAccount {
    const claude = extra.get("claude") orelse return null;
    const accounts = claude.get("accounts") orelse return null;
    const items = switch (accounts) {
        .array => |a| a,
        else => return null,
    };
    var out: std.ArrayListUnmanaged(app_mod.Config.ClaudeAccount) = .empty;
    for (items) |it| {
        if (it != .object) continue;
        var acc: app_mod.Config.ClaudeAccount = .{};
        if (it.get("name")) |n| if (n == .string) {
            acc.name = n.string;
        };
        if (it.get("token_path")) |p| if (p == .string) {
            acc.token_path = p.string;
        };
        if (it.get("active")) |a| if (a == .bool) {
            acc.active = a.bool;
        };
        try out.append(arena, acc);
    }
    return if (out.items.len == 0) null else out.items;
}

fn iconEnabled(app: *const App, id: []const u8) bool {
    for (app.cfg.ui.integration_icons) |ic| if (std.mem.eql(u8, ic.id, id) and ic.enabled) return true;
    return false;
}

// ─── the cadence ────────────────────────────────────────────────────────

/// Per tick: the Codex scan every five minutes; the active Claude
/// account every five (every minute from 90 %), the others every
/// twenty, one spawn per tick and none within 20 s of the last, a
/// backed-off account skipped. `force` bypasses the throttles and
/// spawns every account at once (a pane opening, `r`,
/// `ai.refresh_usage`).
pub fn tick(app: *App) Allocator.Error!void {
    try tickReauth(app);
    return refresh(app, false);
}

fn refresh(app: *App, force: bool) Allocator.Error!void {
    const s = st(app);
    const claude_on = iconEnabled(app, "claude_code") or force or findPane(app, .claude) != null;
    const codex_on = iconEnabled(app, "codex") or force or findPane(app, .codex) != null;
    if (!claude_on and !codex_on) return;
    const now = nowSecs(app);
    if (codex_on and !s.codex_pending and (force or now -| s.codex_last_at >= usage.refresh_interval_s)) {
        s.codex_last_at = now;
        try spawnCodex(app, now);
    }
    if (!claude_on) return;
    const arena = app.frame.allocator();
    const cfg = try configured(app, arena);
    try pruneTo(app, cfg);
    if (fixtureDir(app) == null and builtin.os.tag == .macos and !s.keychain_pending and (force or now -| s.keychain_last_at >= usage.keychain_interval_s)) {
        s.keychain_last_at = now;
        try spawnKeychain(app, .poll, .{});
    }
    if (!force and now -| s.last_spawn_at < usage.spawn_gap_s) return;
    for (cfg) |c| {
        const sched = s.schedFor(c.name) orelse blk: {
            try s.sched.append(app.gpa, .{ .name = try app.gpa.dupe(u8, c.name) });
            break :blk &s.sched.items[s.sched.items.len - 1];
        };
        if (sched.pending) continue;
        const acc = s.find(c.name);
        if (!force) {
            if (acc) |a| if (a.usage.retry_after_at > now) continue;
            const is_active = if (acc) |a| a.is_active else c.active;
            const percent: u16 = if (acc) |a| a.usage.percent else 0;
            if (now -| sched.last_at < usage.intervalFor(is_active, percent, sched.last_at)) continue;
        } else if (acc) |a| {
            a.usage.retry_after_at = 0;
        }
        sched.last_at = now;
        sched.pending = true;
        sched.renewing = try renews(app, acc, c, now);
        s.last_spawn_at = now;
        spawnClaude(app, c, cfg.len, now) catch |err| {
            sched.pending = false;
            return err;
        };
        if (!force) break;
    }
}

/// Drop snapshots and schedules for accounts no longer configured.
fn pruneTo(app: *App, cfg: []const usage.AccountCfg) Allocator.Error!void {
    const s = st(app);
    var i: usize = 0;
    while (i < s.accounts.items.len) {
        if (named(cfg, s.accounts.items[i].name)) {
            i += 1;
        } else {
            var gone = s.accounts.orderedRemove(i);
            gone.arena.deinit();
        }
    }
    i = 0;
    while (i < s.sched.items.len) {
        if (named(cfg, s.sched.items[i].name)) {
            i += 1;
        } else {
            const gone = s.sched.orderedRemove(i);
            app.gpa.free(gone.name);
        }
    }
}

/// The pane lists accounts as the config does, whatever order their
/// results arrived in.
fn orderByConfig(s: *State, cfg: []const usage.AccountCfg) void {
    var pos: usize = 0;
    for (cfg) |c| {
        for (s.accounts.items[pos..], pos..) |a, i| if (std.mem.eql(u8, a.name, c.name)) {
            if (i != pos) {
                const moved = s.accounts.orderedRemove(i);
                s.accounts.insertAssumeCapacity(pos, moved);
            }
            pos += 1;
            break;
        };
    }
}

fn named(cfg: []const usage.AccountCfg, name: []const u8) bool {
    for (cfg) |c| if (std.mem.eql(u8, c.name, name)) return true;
    return false;
}

/// `ai.refresh_usage`, `r`, a pane opening: everything, now.
pub fn refreshAll(app: *App) Allocator.Error!void {
    return refresh(app, true);
}

/// The ticker chip repaints when its slot moves; the loop's deadline
/// asks for a wake within the second while it is on.
pub fn tickerActive(app: *const App) bool {
    return app.cfg.ai.claude_meter_mode == .ticker and app.ai.usage.accounts.items.len > 1 and iconEnabled(app, "claude_code");
}

pub fn pollTicker(app: *App) void {
    if (!tickerActive(app)) return;
    const slot = nowSecs(app) / usage.ticker_slot_s;
    if (slot != st(app).ticker_slot) {
        st(app).ticker_slot = slot;
        app.needs_render = true;
    }
}

// ─── the workers ────────────────────────────────────────────────────────

const ClaudeJob = struct {
    name: []u8,
    token_path: []u8,
    fixture: ?[]u8,
    data_root: []u8,
    account_count: usize,
    now: u64,

    fn destroy(j: *ClaudeJob, gpa: Allocator) void {
        gpa.free(j.name);
        gpa.free(j.token_path);
        if (j.fixture) |f| gpa.free(f);
        gpa.free(j.data_root);
        gpa.destroy(j);
    }
};

/// Whether a fetch of `c` now renews its token: the last read was
/// turned down, or the token file's own clock says it has expired.
fn renews(app: *App, acc: ?*Account, c: usage.AccountCfg, now: u64) Allocator.Error!bool {
    if (acc) |a| if (usage.accountState(&a.usage) == .expired) return true;
    if (c.token_path.len == 0) return false;
    const arena = app.frame.allocator();
    const raw = Io.Dir.cwd().readFileAlloc(app.io, c.token_path, arena, .limited(64 * 1024)) catch return false;
    const at = usage.expiresAtOf(arena, raw) orelse return false;
    return at <= now and usage.refreshTokenOf(arena, raw) != null;
}

fn spawnClaude(app: *App, c: usage.AccountCfg, count: usize, now: u64) Allocator.Error!void {
    const gpa = app.gpa;
    const job = try gpa.create(ClaudeJob);
    errdefer gpa.destroy(job);
    job.* = .{ .name = try gpa.dupe(u8, c.name), .token_path = &.{}, .fixture = null, .data_root = &.{}, .account_count = count, .now = now };
    errdefer gpa.free(job.name);
    job.token_path = try gpa.dupe(u8, c.token_path);
    errdefer gpa.free(job.token_path);
    job.data_root = try gpa.dupe(u8, app.data_root);
    errdefer gpa.free(job.data_root);
    if (fixtureDir(app)) |d| job.fixture = try gpa.dupe(u8, d);
    errdefer if (job.fixture) |f| gpa.free(f);
    st(app).group.concurrent(app.io, claudeWorker, .{ app.events, app.io, gpa, job }) catch return error.OutOfMemory;
}

fn claudeWorker(events: *event.EventQueue, io: Io, gpa: Allocator, job: *ClaudeJob) Io.Cancelable!void {
    defer job.destroy(gpa);
    const r = usage.Result.create(gpa) catch return;
    errdefer r.destroy(gpa);
    const arena = r.arena.allocator();
    const name = arena.dupe(u8, job.name) catch return;
    const outcome: usage.ClaudeOutcome = if (job.fixture) |dir|
        usage.fetchFixture(arena, io, dir, job.name, job.now) catch return
    else
        usage.fetchLive(gpa, io, arena, .{ .data_root = job.data_root, .account_count = job.account_count }, job.name, job.token_path, job.now) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return,
            error.Failed => .{ .err = .{ .message = "fetch: the request failed (offline?)" } },
        };
    r.payload = .{ .claude = .{ .name = name, .outcome = outcome } };
    events.post(io, .{ .usage = r });
}

const CodexJob = struct {
    home: ?[]u8,
    fixture: ?[]u8,
    now: u64,

    fn destroy(j: *CodexJob, gpa: Allocator) void {
        if (j.home) |h| gpa.free(h);
        if (j.fixture) |f| gpa.free(f);
        gpa.destroy(j);
    }
};

fn spawnCodex(app: *App, now: u64) Allocator.Error!void {
    const gpa = app.gpa;
    const s = st(app);
    const job = try gpa.create(CodexJob);
    errdefer gpa.destroy(job);
    job.* = .{ .home = null, .fixture = null, .now = now };
    if (app.homeDir()) |h| job.home = try gpa.dupe(u8, h);
    errdefer if (job.home) |h| gpa.free(h);
    if (fixtureDir(app)) |d| job.fixture = try gpa.dupe(u8, d);
    errdefer if (job.fixture) |f| gpa.free(f);
    s.codex_pending = true;
    s.group.concurrent(app.io, codexWorker, .{ app.events, app.io, gpa, job }) catch {
        s.codex_pending = false;
        return error.OutOfMemory;
    };
}

fn codexWorker(events: *event.EventQueue, io: Io, gpa: Allocator, job: *CodexJob) Io.Cancelable!void {
    defer job.destroy(gpa);
    const r = usage.Result.create(gpa) catch return;
    errdefer r.destroy(gpa);
    const arena = r.arena.allocator();
    const outcome: usage.CodexOutcome = if (job.fixture) |dir|
        usage.fetchCodexFixture(arena, io, dir, job.now) catch return
    else if (job.home) |home|
        usage.fetchCodexLive(gpa, io, arena, home, job.now) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return,
        }
    else
        .{ .err = "no home directory — ~/.codex/sessions cannot be read" };
    r.payload = .{ .codex = outcome };
    events.post(io, .{ .usage = r });
}

const KeychainJob = struct {
    mode: usage.KeychainMode,
    /// Owned. `.reauth`: the refresh token the login started from — the
    /// profile is asked only once the keychain's differs.
    baseline: ?[]u8 = null,
    /// Owned. `.file_under`: the account to file the login under.
    target: ?[]u8 = null,
    /// Ask the profile endpoint whose login it is.
    want_email: bool = false,
    /// Owned. The CLI's credentials file — read where there is no
    /// keychain (`usage.readCliLogin`).
    creds: ?[]u8 = null,

    fn destroy(job: *KeychainJob, gpa: Allocator) void {
        if (job.baseline) |b| gpa.free(b);
        if (job.creds) |x| gpa.free(x);
        if (job.target) |x| gpa.free(x);
        gpa.destroy(job);
    }
};

const KeychainOpts = struct { baseline: ?[]const u8 = null, target: ?[]const u8 = null, want_email: bool = false };

fn spawnKeychain(app: *App, mode: usage.KeychainMode, o: KeychainOpts) Allocator.Error!void {
    const gpa = app.gpa;
    const s = st(app);
    const job = try gpa.create(KeychainJob);
    job.* = .{ .mode = mode, .want_email = o.want_email or mode == .capture or mode == .recapture or mode == .file_under };
    errdefer job.destroy(gpa);
    if (o.baseline) |b| job.baseline = try gpa.dupe(u8, b);
    if (o.target) |x| job.target = try gpa.dupe(u8, x);
    if (try cliCredentialsPath(app, app.frame.allocator())) |c| job.creds = try gpa.dupe(u8, c);
    s.keychain_pending = true;
    s.group.concurrent(app.io, keychainWorker, .{ app.events, app.io, gpa, job }) catch {
        s.keychain_pending = false;
        return error.OutOfMemory;
    };
}

fn keychainWorker(events: *event.EventQueue, io: Io, gpa: Allocator, job: *KeychainJob) Io.Cancelable!void {
    defer job.destroy(gpa);
    const r = usage.Result.create(gpa) catch return;
    errdefer r.destroy(gpa);
    const arena = r.arena.allocator();
    var k: usage.Keychain = .{ .mode = job.mode };
    if (job.target) |x| k.target = arena.dupe(u8, x) catch return;
    if (usage.readCliLogin(gpa, io, arena, job.creds)) |blob| {
        k.blob = blob;
        k.refresh_token = usage.refreshTokenOf(arena, blob);
        const changed = if (job.baseline) |b| (if (k.refresh_token) |rt| !std.mem.eql(u8, rt, b) else true) else true;
        if (job.want_email and changed) {
            if (usage.accessTokenOf(arena, blob)) |token| {
                const reply = usage.httpGet(gpa, io, arena, usage.profile_url, token) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => null,
                };
                if (reply) |rep| if (rep.status >= 200 and rep.status < 300) {
                    if (usage.parseProfile(arena, rep.body) catch null) |p| k.email = p.email;
                };
            }
        }
    } else k.err = "the keychain has no Claude Code login yet";
    r.payload = .{ .keychain = k };
    events.post(io, .{ .usage = r });
}

// ─── the event handler (D1) ─────────────────────────────────────────────

/// `r` is destroyed on every path.
pub fn handle(app: *App, r: *usage.Result) Allocator.Error!void {
    defer r.destroy(app.gpa);
    const s = st(app);
    switch (r.payload) {
        .none => return,
        .claude => |c| {
            if (s.schedFor(c.name)) |sched| {
                sched.pending = false;
                sched.renewing = false;
            }
            const arena = app.frame.allocator();
            const cfg = try configured(app, arena);
            if (!named(cfg, c.name)) return;
            const active_cfg = for (cfg) |x| {
                if (std.mem.eql(u8, x.name, c.name)) break x.active;
            } else false;
            const now = nowSecs(app);
            // The arena is a value: allocate through `next.arena` itself so
            // the state that is copied into the list at the end is the one
            // the allocations advanced.
            var next: Account = .{ .arena = .init(app.gpa), .name = &.{}, .is_active = active_cfg };
            errdefer next.arena.deinit();
            const fa = next.arena.allocator();
            next.name = try fa.dupe(u8, c.name);
            const old = s.find(c.name);
            if (old) |o| next.is_active = o.is_active;
            switch (c.outcome) {
                .ok => |f| {
                    try logUnknownKeys(app, c.name, f.usage.unknown_keys);
                    next.usage = try dupeUsage(fa, f.usage);
                    if (f.email) |e| next.email = try fa.dupe(u8, e);
                    if (f.org) |o| next.org = try fa.dupe(u8, o);
                    if (f.warning) |w| app.toast("{s}", .{w});
                    if (f.recaptured) app.toast("signed {s} back in from the Claude Code login on this machine", .{c.name});
                },
                .err => |e| {
                    if (old) |o| {
                        next.usage = try dupeUsage(fa, o.usage);
                        if (o.email) |em| next.email = try fa.dupe(u8, em);
                        if (o.org) |og| next.org = try fa.dupe(u8, og);
                    }
                    usage.applyFetchError(&next.usage, .{ .message = try fa.dupe(u8, e.message), .retry_after = e.retry_after, .needs_reauth = e.needs_reauth, .auth = e.auth }, now);
                },
            }
            if (old) |o| {
                o.arena.deinit();
                o.* = next;
            } else try s.accounts.append(app.gpa, next);
            orderByConfig(s, cfg);
            try restampActive(app);
        },
        .codex => |c| {
            s.codex_pending = false;
            if (s.codex_error) |e| app.gpa.free(e);
            s.codex_error = null;
            switch (c) {
                .ok => |u| s.codex = u,
                .err => |e| {
                    var u = s.codex orelse usage.Codex{};
                    s.codex_error = try app.gpa.dupe(u8, e);
                    u.last_error = s.codex_error;
                    s.codex = u;
                },
            }
        },
        .keychain => |k| {
            s.keychain_pending = false;
            if (s.keychain_rt) |old| app.gpa.free(old);
            s.keychain_rt = if (k.refresh_token) |rt| try app.gpa.dupe(u8, rt) else null;
            try restampActive(app);
            switch (k.mode) {
                .poll => try maybeRecapture(app),
                .capture => try captureLogin(app, k),
                .reauth => try reauthRead(app, k),
                .recapture => try recaptureRead(app, k),
                .file_under => try fileUnderRead(app, k),
            }
        },
    }
    app.needs_render = true;
}

fn dupeUsage(arena: Allocator, u: usage.Usage) Allocator.Error!usage.Usage {
    var out = u;
    const scoped = try arena.alloc(usage.Scoped, u.scoped.len);
    for (u.scoped, 0..) |sc, i| {
        scoped[i] = sc;
        scoped[i].model = try arena.dupe(u8, sc.model);
    }
    out.scoped = scoped;
    const windows = try arena.alloc(usage.ExtraWindow, u.windows.len);
    for (u.windows, 0..) |w, i| windows[i] = .{ .key = try arena.dupe(u8, w.key), .title = try arena.dupe(u8, w.title), .percent = w.percent, .resets_at = w.resets_at, .locked_reason = try dupeOpt(arena, w.locked_reason) };
    out.windows = windows;
    if (u.extra_usage) |e| out.extra_usage = .{ .enabled = e.enabled, .reason = try dupeOpt(arena, e.reason), .percent = e.percent };
    if (u.breakdown) |b| {
        const rows = try arena.alloc(usage.SurfaceShare, b.rows.len);
        for (b.rows, 0..) |r, i| rows[i] = .{ .key = try arena.dupe(u8, r.key), .name = try arena.dupe(u8, r.name), .percent = r.percent };
        out.breakdown = .{ .as_of = b.as_of, .window_started_at = b.window_started_at, .rows = rows };
    }
    out.locked_reason = try dupeOpt(arena, u.locked_reason);
    out.weekly_locked_reason = try dupeOpt(arena, u.weekly_locked_reason);
    // Logged on arrival; the snapshot does not keep them.
    out.unknown_keys = &.{};
    if (u.last_error) |e| out.last_error = try arena.dupe(u8, e);
    return out;
}

fn dupeOpt(arena: Allocator, s: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (s) |x| try arena.dupe(u8, x) else null;
}

const log = std.log.scoped(.usage);

/// The names of the top-level keys the parser does not know, at debug
/// level, once per account per key — how the field that carries a new
/// window gets learned from an account that has one.
fn logUnknownKeys(app: *App, name: []const u8, keys: []const []const u8) Allocator.Error!void {
    const s = st(app);
    for (keys) |k| {
        const id = try std.fmt.allocPrint(app.frame.allocator(), "{s}\x00{s}", .{ name, k });
        if (s.unknown_seen.contains(id)) continue;
        const owned = try app.gpa.dupe(u8, id);
        errdefer app.gpa.free(owned);
        try s.unknown_seen.put(app.gpa, owned, {});
        s.unknown_logged += 1;
        log.debug("claude usage: account {s} reports a field this build does not read: {s}", .{ name, k });
    }
}

/// `is_active`: the account whose token file holds the keychain's
/// refresh token — the CLI's current login — else the config's flag.
fn restampActive(app: *App) Allocator.Error!void {
    const s = st(app);
    const arena = app.frame.allocator();
    const cfg = try configured(app, arena);
    var active_name: ?[]const u8 = null;
    if (s.keychain_rt) |rt| active_name = try usage.accountOfRefreshToken(arena, app.io, cfg, rt);
    if (active_name == null) for (cfg) |c| if (c.active) {
        active_name = c.name;
    };
    for (s.accounts.items) |*a| a.is_active = if (active_name) |n| std.mem.eql(u8, a.name, n) else false;
}

/// `R`: file the keychain's login under the account it belongs to —
/// the one pinned to its email, or the only one — then re-read it.
fn captureLogin(app: *App, k: usage.Keychain) Allocator.Error!void {
    const arena = app.frame.allocator();
    if (k.err) |e| return app.toast("{s}", .{e});
    const blob = k.blob orelse return app.toast("the keychain returned nothing", .{});
    const cfg = try configured(app, arena);
    var target: ?usage.AccountCfg = null;
    if (cfg.len == 1) target = cfg[0] else if (k.email) |email| {
        for (cfg) |c| if (try usage.pinnedEmail(arena, app.io, app.data_root, c.name)) |pinned| if (std.mem.eql(u8, pinned, email)) {
            target = c;
        };
    }
    // An account just added and never linked has no pin yet: when it is
    // the only one without a token file, the login is taken to be its —
    // `a`, then `L` to log in as it, then `R`, is how one is linked
    // without pasting a token.
    if (target == null) if (try onlyUnlinked(app, cfg)) |c| {
        target = c;
    };
    const tgt = target orelse return app.toast("the keychain login ({s}) matches no account on file — Re-auth the one you want", .{k.email orelse "unknown"});
    usage.writeSecret(app.io, tgt.token_path, blob) catch |err| return app.toast("could not write {s}: {s}", .{ app.relPath(tgt.token_path), @errorName(err) });
    app.toast("captured the keychain login for {s} ({s})", .{ tgt.name, k.email orelse "identity unknown" });
    if (st(app).schedFor(tgt.name)) |sched| sched.last_at = 0;
    if (st(app).find(tgt.name)) |a| a.usage.retry_after_at = 0;
    try refresh(app, true);
}

/// The one configured account whose token file is missing, when exactly
/// one is.
fn onlyUnlinked(app: *App, cfg: []const usage.AccountCfg) Allocator.Error!?usage.AccountCfg {
    var found: ?usage.AccountCfg = null;
    for (cfg) |c| {
        if (c.token_path.len == 0) continue;
        Io.Dir.cwd().access(app.io, c.token_path, .{}) catch {
            if (found != null) return null;
            found = c;
        };
    }
    return found;
}

// ─── Re-auth and the silent re-capture ──────────────────────────────────

/// Whether this build can read Claude Code's login: the macOS keychain,
/// and never in fixture mode.
fn keychainReadable(app: *App) bool {
    return builtin.os.tag == .macos and fixtureDir(app) == null;
}

/// Whether Re-auth can read the CLI's login here: the keychain on macOS,
/// the credentials file everywhere — never in fixture mode.
fn loginReadable(app: *App) bool {
    return fixtureDir(app) == null;
}

/// The CLI's credentials file: `CLAUDE_CONFIG_DIR`, else `~/.claude`.
fn cliCredentialsPath(app: *App, arena: Allocator) Allocator.Error!?[]const u8 {
    return usage.credentialsPath(arena, app.homeDir(), app.env.get("CLAUDE_CONFIG_DIR"));
}

/// The configured account named `name`, its token path resolved.
fn cfgOf(app: *App, arena: Allocator, name: []const u8) Allocator.Error!?usage.AccountCfg {
    for (try configured(app, arena)) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

/// After a token file changed under an account: fetch it now.
fn kick(app: *App, name: []const u8) Allocator.Error!void {
    if (st(app).schedFor(name)) |sched| sched.last_at = 0;
    if (st(app).find(name)) |a| a.usage.retry_after_at = 0;
    try refresh(app, true);
}

/// Whether `path` already holds exactly `blob`.
fn holds(app: *App, arena: Allocator, path: []const u8, blob: []const u8) bool {
    const cur = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(64 * 1024)) catch return false;
    return std.mem.eql(u8, std.mem.trim(u8, cur, " \t\r\n"), std.mem.trim(u8, blob, " \t\r\n"));
}

/// Whose login `email` is, for a Re-auth of `name`: its own (its pin,
/// or no pin yet and no other account's); another account's (the
/// mismatch guard offers to file it there); or nobody's — said, never
/// filed. One account configured takes any login, as `R` always has.
pub const Verdict = union(enum) { capture, other: []const u8, unknown };

pub fn reauthVerdict(app: *App, arena: Allocator, name: []const u8, email: ?[]const u8) Allocator.Error!Verdict {
    const cfg = try configured(app, arena);
    const e = email orelse return if (cfg.len <= 1) .capture else .unknown;
    const pin = try usage.pinnedEmail(arena, app.io, app.data_root, name);
    if (pin) |p| if (std.mem.eql(u8, p, e)) return .capture;
    for (cfg) |c| {
        if (std.mem.eql(u8, c.name, name)) continue;
        if (try usage.pinnedEmail(arena, app.io, app.data_root, c.name)) |other| if (std.mem.eql(u8, other, e)) return .{ .other = c.name };
    }
    if (pin == null or cfg.len <= 1) return .capture;
    return .unknown;
}

/// `ai.claude_reauth`, an account's *Re-auth* button and menu row: a
/// pane running `claude login`, watched — the keychain is read every
/// 1.5 s, and the login that lands is filed under the account when it is
/// the account's (`reauthRead`). Nothing to press afterwards.
pub fn startReauth(app: *App, name: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const gpa = app.gpa;
    _ = (try cfgOf(app, arena, name)) orelse return app.diag.fail(arena, "no Claude account named {s}", .{name});
    if (!loginReadable(app)) return app.diag.fail(arena, "fixture mode: Re-auth reads no keychain", .{});
    const s = st(app);
    if (s.reauth) |*r| {
        if (std.mem.eql(u8, r.name, name)) if (r.pane) |id| if (app.panes.pty(id) != null) {
            app.showPane(id);
            return;
        };
        try endReauth(app, true);
    }
    const label = try std.fmt.allocPrint(arena, "claude login — {s}", .{name});
    const pane = pty_pane.open(app, .{ .argv = &.{ "claude", "login" }, .label = label, .placement = .below, .kind = .command }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "could not start `claude login`: {s}", .{@errorName(err)}),
    };
    s.reauth = .{ .name = try gpa.dupe(u8, name), .pane = pane };
    app.toast("log in as {s} below — the login is filed under it when it lands", .{name});
    app.needs_render = true;
}

/// Stop watching; `close` takes the login pane with it.
fn endReauth(app: *App, close: bool) Allocator.Error!void {
    const s = st(app);
    var r = s.reauth orelse return;
    s.reauth = null;
    defer r.deinit(app.gpa);
    if (close) if (r.pane) |id| if (app.panes.pty(id) != null) try app.forceClosePane(id);
    if (findPane(app, .claude)) |id| app.showPane(id);
    app.needs_render = true;
}

/// Whether the tick should wake the loop: a Re-auth is watching.
pub fn watching(app: *const App) bool {
    return app.ai.usage.reauth != null;
}

/// Per tick while a Re-auth runs: a keychain read every 1.5 s; once the
/// login pane has exited or been closed, one more, then the watch ends.
fn tickReauth(app: *App) Allocator.Error!void {
    const s = st(app);
    const r = if (s.reauth) |*x| x else return;
    if (!r.final) if (r.pane) |id| {
        const gone = if (app.panes.pty(id)) |p| p.exit != null else true;
        if (gone) r.final = true;
    };
    if (s.keychain_pending or r.final_polled) return;
    if (!r.final and app.now_ms - r.last_poll_ms < reauth_poll_ms) return;
    r.last_poll_ms = app.now_ms;
    if (r.final and r.baseline_set) r.final_polled = true;
    try spawnKeychain(app, .reauth, .{ .baseline = r.baseline, .want_email = r.baseline_set });
}

/// A Re-auth's keychain read. The first sets the baseline; one whose
/// refresh token differs is the new login, filed when it is the
/// account's, else the mismatch guard. A read after the pane ended with
/// nothing new ends the watch.
pub fn reauthRead(app: *App, k: usage.Keychain) Allocator.Error!void {
    const s = st(app);
    const r = if (s.reauth) |*x| x else return;
    const arena = app.frame.allocator();
    if (!r.baseline_set) {
        r.baseline_set = true;
        r.baseline = if (k.refresh_token) |rt| try app.gpa.dupe(u8, rt) else null;
        return;
    }
    const changed = if (k.refresh_token) |rt| (if (r.baseline) |b| !std.mem.eql(u8, b, rt) else true) else false;
    const blob = k.blob orelse null;
    if (!changed or blob == null) {
        if (r.final_polled) {
            app.toast("the login for {s} closed with no new Claude Code login — Re-auth to try again", .{r.name});
            try endReauth(app, false);
        }
        return;
    }
    const name = try arena.dupe(u8, r.name);
    switch (try reauthVerdict(app, arena, name, k.email)) {
        .capture => {
            const c = (try cfgOf(app, arena, name)) orelse return endReauth(app, true);
            usage.writeSecret(app.io, c.token_path, blob.?) catch |err| {
                app.toast("could not write {s}: {s}", .{ app.relPath(c.token_path), @errorName(err) });
                return endReauth(app, false);
            };
            if (k.email) |e| _ = try usage.pinIdentity(arena, app.io, app.data_root, name, e);
            try endReauth(app, true);
            app.toast("signed {s} in{s}{s}{s}", .{ name, if (k.email != null) " (" else "", k.email orelse "", if (k.email != null) ")" else "" });
            try kick(app, name);
        },
        .other => |other| {
            try endReauth(app, true);
            try openFileUnder(app, name, other, k.email orelse "");
        },
        .unknown => {
            try endReauth(app, true);
            app.toast("that login is {s}, not {s}'s — nothing was filed; Re-auth again and log in as {s}", .{ k.email orelse "an account mnml cannot name", name, name });
        },
    }
}

pub const file_under_cancel = 'c';

/// The mismatch guard: the login a Re-auth of `name` got is `other`'s.
/// *File under <other>* reads the keychain again and files it there;
/// *Cancel* leaves every token file as it was.
fn openFileUnder(app: *App, name: []const u8, other: []const u8, email: []const u8) Allocator.Error!void {
    const gpa = app.gpa;
    const msg = try std.fmt.allocPrint(gpa, "The login that landed is {s} — that is {s}, not {s}. Nothing was filed under {s}.", .{ email, other, name, name });
    errdefer gpa.free(msg);
    const target = try gpa.dupe(u8, other);
    errdefer gpa.free(target);
    const label = try std.fmt.allocPrint(gpa, "File under {s}", .{other});
    errdefer gpa.free(label);
    const choices = try gpa.alloc(app_mod.Confirm.Choice, 2);
    choices[0] = .{ .key = 'f', .label = label };
    choices[1] = .{ .key = file_under_cancel, .label = "Cancel" };
    app.overlay.deinit(gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Re-auth: another account's login", .message = msg, .choices = choices },
        .purpose = .{ .claude_file_login = .{ .target = target, .label = label, .choices = choices } },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The guard's *File under*: read the keychain again for `target`.
pub fn fileUnderAccept(app: *App, target: []const u8, choice: usize) CommandError!void {
    if (choice != 0) return;
    if (!loginReadable(app)) return app.diag.fail(app.frame.allocator(), "the Claude Code login cannot be read here", .{});
    try spawnKeychain(app, .file_under, .{ .target = target });
}

/// The *File under* read: filed under the target only when the login is
/// still the one pinned to it.
pub fn fileUnderRead(app: *App, k: usage.Keychain) Allocator.Error!void {
    const arena = app.frame.allocator();
    const name = k.target orelse return;
    const blob = k.blob orelse return app.toast("{s}", .{k.err orelse "the keychain returned nothing"});
    const pin = try usage.pinnedEmail(arena, app.io, app.data_root, name);
    const ok = if (k.email) |e| (if (pin) |p| std.mem.eql(u8, p, e) else false) else false;
    if (!ok) return app.toast("the keychain's login is no longer {s}'s — nothing was filed", .{name});
    const c = (try cfgOf(app, arena, name)) orelse return;
    usage.writeSecret(app.io, c.token_path, blob) catch |err| return app.toast("could not write {s}: {s}", .{ app.relPath(c.token_path), @errorName(err) });
    app.toast("filed the login under {s}", .{name});
    try kick(app, name);
}

/// The account a keychain login of `email` silently re-captures: one
/// whose token was turned down (expired, or the keychain then held
/// another account) and whose pin is that email. Null otherwise —
/// another account's login is never filed without asking.
pub fn recaptureTarget(app: *App, arena: Allocator, email: ?[]const u8) Allocator.Error!?[]const u8 {
    const e = email orelse return null;
    for (st(app).accounts.items) |*a| {
        switch (usage.accountState(&a.usage)) {
            .expired, .other_login => {},
            else => continue,
        }
        const pin = (try usage.pinnedEmail(arena, app.io, app.data_root, a.name)) orelse continue;
        if (std.mem.eql(u8, pin, e)) return a.name;
    }
    return null;
}

/// After a keychain poll: when an account's token was turned down and
/// the keychain holds a login not looked at yet, ask whose it is.
fn maybeRecapture(app: *App) Allocator.Error!void {
    const s = st(app);
    if (!keychainReadable(app) or s.keychain_pending or s.reauth != null) return;
    const rt = s.keychain_rt orelse return;
    if (s.recapture_seen) |seen| if (std.mem.eql(u8, seen, rt)) return;
    for (s.accounts.items) |*a| switch (usage.accountState(&a.usage)) {
        .expired, .other_login => break,
        else => {},
    } else return;
    try spawnKeychain(app, .recapture, .{});
}

/// The re-capture read: the login filed under the expired account it
/// belongs to, one toast; anyone else's login, nothing at all.
pub fn recaptureRead(app: *App, k: usage.Keychain) Allocator.Error!void {
    const s = st(app);
    const arena = app.frame.allocator();
    if (k.refresh_token) |rt| {
        const owned = try app.gpa.dupe(u8, rt);
        if (s.recapture_seen) |old| app.gpa.free(old);
        s.recapture_seen = owned;
    }
    const blob = k.blob orelse return;
    const name = (try recaptureTarget(app, arena, k.email)) orelse return;
    const c = (try cfgOf(app, arena, name)) orelse return;
    if (holds(app, arena, c.token_path, blob)) return;
    usage.writeSecret(app.io, c.token_path, blob) catch return;
    app.toast("signed {s} back in from the Claude Code login on this machine", .{name});
    try kick(app, name);
}

// ─── the accounts: add, link, rename, remove ────────────────────────────

pub const max_name_len = 32;

/// Why `name` cannot name an account, or null. The rules are Rust's
/// (`rename_claude_account`): not empty, at most 32 characters, nothing
/// that would need escaping in the config.
pub fn nameProblem(name: []const u8) ?[]const u8 {
    if (name.len == 0) return "the name is empty";
    const n = std.unicode.utf8CountCodepoints(name) catch return "the name is not UTF-8";
    if (n > max_name_len) return "at most 32 characters";
    for (name) |c| if (c == '"' or c == '\\' or c < 0x20 or c == 0x7f) return "no quotes, backslashes or control characters";
    return null;
}

/// The accounts as the home config spells them — names, unresolved token
/// paths, the active flag — the list an edit writes back. The config's
/// list, else the 0.2.x blocks, else the implicit `default` account when
/// its `ai_token` exists (so adding a second account keeps the first).
pub fn rawAccounts(app: *App, arena: Allocator) Allocator.Error![]ClaudeAccount {
    if (app.cfg.ai.claude_accounts.len > 0) return arena.dupe(ClaudeAccount, app.cfg.ai.claude_accounts);
    if (try accountsFromExtra(arena, app.cfg.ai.extra)) |list| return list;
    if (app.data_root.len > 0) {
        const path = try std.fs.path.join(arena, &.{ app.data_root, usage.token_file });
        if (Io.Dir.cwd().access(app.io, path, .{})) |_| {
            const one = try arena.alloc(ClaudeAccount, 1);
            one[0] = .{ .name = "default", .token_path = usage.token_file, .active = true };
            return one;
        } else |_| {}
    }
    return &.{};
}

/// `ai_token.<slug>` under the data root, unused by any account in
/// `list` and not already on disk.
fn freshTokenFile(app: *App, arena: Allocator, name: []const u8, list: []const ClaudeAccount) Allocator.Error![]const u8 {
    var slug: std.ArrayListUnmanaged(u8) = .empty;
    for (name) |c| {
        const keep = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
        if (keep) try slug.append(arena, std.ascii.toLower(c)) else if (slug.items.len > 0 and slug.items[slug.items.len - 1] != '-') try slug.append(arena, '-');
    }
    while (slug.items.len > 0 and slug.items[slug.items.len - 1] == '-') slug.items.len -= 1;
    if (slug.items.len == 0) try slug.appendSlice(arena, "account");
    var n: usize = 1;
    while (true) : (n += 1) {
        const file = if (n == 1) try std.fmt.allocPrint(arena, "{s}.{s}", .{ usage.token_file, slug.items }) else try std.fmt.allocPrint(arena, "{s}.{s}-{d}", .{ usage.token_file, slug.items, n });
        const taken = for (list) |a| {
            if (std.mem.eql(u8, a.token_path, file)) break true;
        } else false;
        if (taken) continue;
        if (app.data_root.len > 0) {
            const path = try std.fs.path.join(arena, &.{ app.data_root, file });
            if (Io.Dir.cwd().access(app.io, path, .{})) |_| continue else |_| {}
        }
        return file;
    }
}

/// Point `app.cfg.ai.claude_accounts` at an owned copy of `list` and
/// write it to the home config, one account per line.
fn writeAccounts(app: *App, list: []const ClaudeAccount) Allocator.Error!void {
    const s = st(app);
    if (s.cfg_arena == null) s.cfg_arena = .init(app.gpa);
    const a = s.cfg_arena.?.allocator();
    const owned = try a.alloc(ClaudeAccount, list.len);
    for (list, 0..) |acc, i| owned[i] = .{ .name = try a.dupe(u8, acc.name), .token_path = try a.dupe(u8, acc.token_path), .active = acc.active };
    app.cfg.ai.claude_accounts = owned;
    const arena = app.frame.allocator();
    const elems = try arena.alloc([]const u8, owned.len);
    for (owned, 0..) |acc, i| elems[i] = try config_persist.serializeLiteral(arena, acc);
    const literal = try config_persist.listLiteral(arena, elems, true, repeat(" ", 12));
    _ = try settings.persistLiteral(app, .home, &.{ "ai", "claude_accounts" }, literal);
}

/// `ai.claude_add_account`, `a` in the Claude pane, the pane's and the
/// chip's menus: the name; the account then shows `no login yet —
/// Re-auth`.
pub fn addCmd(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "Name the Claude account to add"), .purpose = .claude_account_add } };
    app.overlay.prompt.state.placeholder = "work, personal, a client's name…";
    app.focus = .overlay;
    app.needs_render = true;
}

/// The name prompt's accept: the account joins `ai.claude_accounts` in
/// the home config with a token file of its own under the data root —
/// the first one added is the active one — and its fetch starts. No
/// token prompt: Re-auth signs it in (a token can still be pasted from
/// the account's menu, Advanced ▸ Paste a token…).
pub fn addAccept(app: *App, text: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const name = std.mem.trim(u8, text, " \t\r\n");
    if (name.len == 0) return;
    if (nameProblem(name)) |why| return app.diag.fail(arena, "add account: {s}", .{why});
    const list = try rawAccounts(app, arena);
    for (list) |a| if (std.mem.eql(u8, a.name, name)) return app.diag.fail(arena, "add account: `{s}` is already an account", .{name});
    const next = try arena.alloc(ClaudeAccount, list.len + 1);
    @memcpy(next[0..list.len], list);
    next[list.len] = .{ .name = name, .token_path = try freshTokenFile(app, arena, name, list), .active = list.len == 0 };
    try writeAccounts(app, next);
    try refreshAll(app);
    app.toast("added {s} — Re-auth signs it in", .{name});
}

/// The secret prompt that links `name`: the OAuth token pasted into it
/// lands in that account's token file.
pub fn openTokenPrompt(app: *App, name: []const u8) CommandError!void {
    const gpa = app.gpa;
    const owned = try gpa.dupe(u8, name);
    errdefer gpa.free(owned);
    const title = try std.fmt.allocPrint(gpa, "Paste the Claude Code OAuth token for {s}", .{name});
    errdefer gpa.free(title);
    var ps = app_mod.Prompt.init(gpa, title);
    ps.secret = true;
    ps.placeholder = "the accessToken, or the whole login blob";
    app.overlay.deinit(gpa);
    app.overlay = .{ .prompt = .{ .state = ps, .purpose = .{ .claude_account_token = .{ .name = owned, .title = title } } } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The token prompt's accept: the token into the account's own file
/// (mode 0600), and a fetch for it now. Empty is "later".
pub fn tokenAccept(app: *App, name: []const u8, text: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const token = std.mem.trim(u8, text, " \t\r\n");
    if (token.len == 0) {
        app.toast("{s} is not linked yet — Re-auth signs it in", .{name});
        return;
    }
    const cfg = try configured(app, arena);
    const acc = for (cfg) |c| {
        if (std.mem.eql(u8, c.name, name)) break c;
    } else return app.diag.fail(arena, "no Claude account named {s}", .{name});
    if (acc.token_path.len == 0) return app.diag.fail(arena, "fixture mode: {s} has no token file", .{name});
    usage.writeSecret(app.io, acc.token_path, token) catch |err| return app.diag.fail(arena, "could not write {s}: {s}", .{ app.relPath(acc.token_path), @errorName(err) });
    app.toast("linked {s} ({s})", .{ name, app.relPath(acc.token_path) });
    if (st(app).schedFor(name)) |sched| sched.last_at = 0;
    if (st(app).find(name)) |a| a.usage.retry_after_at = 0;
    try refreshAll(app);
}

/// The rename prompt, seeded with the name as a selection.
pub fn openRenamePrompt(app: *App, name: []const u8) CommandError!void {
    const gpa = app.gpa;
    const owned = try gpa.dupe(u8, name);
    errdefer gpa.free(owned);
    const title = try std.fmt.allocPrint(gpa, "Rename Claude account (was: {s})", .{name});
    errdefer gpa.free(title);
    var ps = app_mod.Prompt.init(gpa, title);
    errdefer app_mod.Prompt.deinit(&ps, gpa);
    try ps.seed(gpa, name);
    app.overlay.deinit(gpa);
    app.overlay = .{ .prompt = .{ .state = ps, .purpose = .{ .claude_account_rename = .{ .name = owned, .title = title } } } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The rename prompt's accept: the name in the home config, the
/// snapshot, the schedule and the identity pin — the token file stays
/// where it is.
pub fn renameAccount(app: *App, old: []const u8, text: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const new = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.eql(u8, new, old)) return;
    if (nameProblem(new)) |why| return app.diag.fail(arena, "rename: {s}", .{why});
    const list = try rawAccounts(app, arena);
    var idx: ?usize = null;
    for (list, 0..) |a, i| {
        if (std.mem.eql(u8, a.name, new)) return app.diag.fail(arena, "rename: `{s}` is already an account", .{new});
        if (std.mem.eql(u8, a.name, old)) idx = i;
    }
    const i = idx orelse return app.diag.fail(arena, "no Claude account named {s} in the config", .{old});
    list[i].name = new;
    try writeAccounts(app, list);
    const s = st(app);
    if (s.find(old)) |a| a.name = try a.arena.allocator().dupe(u8, new);
    if (s.schedFor(old)) |sched| {
        const owned = try app.gpa.dupe(u8, new);
        app.gpa.free(sched.name);
        sched.name = owned;
    }
    try usage.movePin(arena, app.io, app.data_root, old, new);
    app.toast("renamed `{s}` → `{s}`", .{ old, new });
    app.needs_render = true;
}

pub const remove_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'r', .label = "Remove" }, .{ .key = 'c', .label = "Cancel" } };

/// The confirm before a removal, naming what goes and what stays.
pub fn openRemoveConfirm(app: *App, name: []const u8) CommandError!void {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const list = try rawAccounts(app, arena);
    const acc = for (list) |a| {
        if (std.mem.eql(u8, a.name, name)) break a;
    } else return app.diag.fail(arena, "no Claude account named {s} in the config", .{name});
    const path = try usage.resolveTokenPath(arena, acc.token_path, app.data_root, app.homeDir());
    const msg = if (ownsTokenFile(app, path, list, name))
        try std.fmt.allocPrint(gpa, "Remove Claude account {s}? It leaves the config, and its token file is deleted ({s}).", .{ name, app.relPath(path) })
    else
        try std.fmt.allocPrint(gpa, "Remove Claude account {s}? It leaves the config; its token file stays, being outside the data root ({s}).", .{ name, app.relPath(path) });
    errdefer gpa.free(msg);
    const owned = try gpa.dupe(u8, name);
    errdefer gpa.free(owned);
    app.overlay.deinit(gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Remove Claude account", .message = msg, .choices = &remove_choices },
        .purpose = .{ .remove_claude_account = owned },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// Whether removing `name` may delete `path`: it sits under the data
/// root and no other account names the same file.
fn ownsTokenFile(app: *App, path: []const u8, list: []const ClaudeAccount, name: []const u8) bool {
    const root = app.data_root;
    if (root.len == 0 or path.len <= root.len + 1) return false;
    if (!std.mem.startsWith(u8, path, root) or !std.fs.path.isSep(path[root.len])) return false;
    const arena = app.frame.allocator();
    for (list) |a| {
        if (std.mem.eql(u8, a.name, name)) continue;
        const other = usage.resolveTokenPath(arena, a.token_path, root, app.homeDir()) catch return false;
        if (std.mem.eql(u8, other, path)) return false;
    }
    return true;
}

/// The confirm's yes: out of the home config, the snapshot and the pin
/// dropped, the token file deleted when it is the data root's and no
/// one else's. The active flag moves to the first account left.
pub fn removeAccount(app: *App, name: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const list = try rawAccounts(app, arena);
    var next: std.ArrayListUnmanaged(ClaudeAccount) = .empty;
    var gone: ?ClaudeAccount = null;
    for (list) |a| if (std.mem.eql(u8, a.name, name)) {
        gone = a;
    } else try next.append(arena, a);
    const acc = gone orelse return app.diag.fail(arena, "no Claude account named {s} in the config", .{name});
    if (acc.active and next.items.len > 0) {
        const any = for (next.items) |a| {
            if (a.active) break true;
        } else false;
        if (!any) next.items[0].active = true;
    }
    const path = try usage.resolveTokenPath(arena, acc.token_path, app.data_root, app.homeDir());
    const owns = ownsTokenFile(app, path, list, name);
    try writeAccounts(app, next.items);
    var deleted = false;
    if (owns) {
        if (Io.Dir.cwd().deleteFile(app.io, path)) |_| {
            deleted = true;
        } else |_| {}
    }
    try usage.movePin(arena, app.io, app.data_root, name, null);
    try pruneTo(app, try configured(app, arena));
    try restampActive(app);
    app.toast("removed Claude account {s}{s}", .{ name, if (deleted) " and its token file" else "" });
    app.needs_render = true;
}

/// A `.claude_account` menu row.
pub fn accountAction(app: *App, verb: command.ClaudeAccountAct.Verb, name: []const u8) CommandError!void {
    return switch (verb) {
        .reauth => startReauth(app, name),
        .link => openTokenPrompt(app, name),
        .rename => openRenamePrompt(app, name),
        .remove => openRemoveConfirm(app, name),
    };
}

/// The palette's link / rename / remove: straight to the one account
/// when there is only one, else a menu of them to pick from.
pub fn chooseAccount(app: *App, verb: command.ClaudeAccountAct.Verb) CommandError!void {
    const arena = app.frame.allocator();
    const cfg = try configured(app, arena);
    if (cfg.len == 0) return app.diag.fail(arena, "no Claude account configured — :ai.claude_add_account adds one", .{});
    if (cfg.len == 1) return accountAction(app, verb, cfg[0].name);
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const rows = try app.gpa.alloc(MenuItem, cfg.len);
    errdefer app.gpa.free(rows);
    for (cfg, 0..) |c, i| rows[i] = .{ .label = try mem.allocator().dupe(u8, c.name), .action = .{ .claude_account = .{ .act = verb, .name = try mem.allocator().dupe(u8, c.name) } }, .checked = c.active };
    const title: []const u8 = switch (verb) {
        .reauth => "Re-auth which Claude account?",
        .link => "Paste a token for which Claude account?",
        .rename => "Rename which Claude account?",
        .remove => "Remove which Claude account?",
    };
    try context_menus.openOwned(app, title, rows, app.screen.width / 3, app.screen.height / 4, mem);
}

// ─── the panes ──────────────────────────────────────────────────────────

pub fn findPane(app: *App, product: Product) ?PaneId {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*pane| switch (pane.*) {
        .ai_usage => |*p| if (p.product == product) return @intCast(i),
        else => {},
    };
    return null;
}

/// `ai.claude_usage` / `ai.codex_usage`: the one pane per product, a
/// tab in the active leaf (Rust's `reveal_pane`); a fresh fetch either
/// way.
pub fn open(app: *App, product: Product) CommandError!void {
    if (findPane(app, product)) |id| {
        app.showPane(id);
    } else {
        const id = try app.panes.add(.{ .ai_usage = .{ .product = product } });
        app.showPane(id);
    }
    try refreshAll(app);
    app.needs_render = true;
}

/// The Claude chip menu's *Re-auth* row: the one account straight, or
/// a submenu naming each. Strings on `mem`, the menu's own arena.
pub fn chipReauthRows(app: *App, mem: Allocator) Allocator.Error![]const MenuItem {
    const cfg = try configured(app, mem);
    if (cfg.len == 0) return &.{};
    if (cfg.len == 1) return mem.dupe(MenuItem, &.{.{ .label = "Re-auth", .action = .{ .claude_account = .{ .act = .reauth, .name = cfg[0].name } } }});
    const kids = try mem.alloc(MenuItem, cfg.len);
    for (cfg, 0..) |c, i| kids[i] = .{ .label = c.name, .action = .{ .claude_account = .{ .act = .reauth, .name = c.name } } };
    return mem.dupe(MenuItem, &.{.{ .label = "Re-auth an account", .action = .none, .submenu = kids }});
}

/// The chip's `!`: the Claude pane, scrolled to account `i`.
pub fn openAt(app: *App, i: usize) CommandError!void {
    try open(app, .claude);
    if (findPane(app, .claude)) |id| if (app.panes.get(id)) |pane| switch (pane.*) {
        .ai_usage => |*p| p.scroll_to = i,
        else => {},
    };
}

/// The account the chip's `!` is about, by its place in the list: one
/// that wants a Re-auth, else — in the compact meter — the one in the
/// warning or critical tier it paints, else one whose last fetch failed.
/// Null when nothing needs looking at.
pub fn attention(app: *App) ?usize {
    const s = st(app);
    for (s.accounts.items, 0..) |*a, i| if (usage.accountState(&a.usage).wantsReauth()) return i;
    if (s.accounts.items.len > 1 and app.cfg.ai.claude_meter_mode == .compact) if (warningIndex(s.accounts.items)) |i| return i;
    for (s.accounts.items, 0..) |*a, i| if (a.usage.last_error != null) return i;
    return null;
}

/// A click on the Claude chip: the pane at the account needing
/// attention, when one does. False leaves the click to the chip's own.
pub fn chipAttentionClick(app: *App) CommandError!bool {
    const i = attention(app) orelse return false;
    try openAt(app, i);
    return true;
}

/// `ai.show_last_response`: the last usage body, as the fetcher wrote it.
pub fn showLastResponse(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    if (app.data_root.len == 0) return app.diag.fail(arena, "no data root — the last response is not kept", .{});
    const path = try std.fs.path.join(arena, &.{ app.data_root, "cache", usage.last_response_file });
    Io.Dir.cwd().access(app.io, path, .{}) catch return app.diag.fail(arena, "no usage response cached yet — :ai.refresh_usage first", .{});
    _ = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "could not open {s}: {s}", .{ app.relPath(path), @errorName(err) }),
    };
}

pub fn handleKey(app: *App, id: PaneId, p: *UsagePane, k: Key) Allocator.Error!bool {
    app.needs_render = true;
    switch (k.code) {
        .down => p.scroll +|= 1,
        .up => p.scroll -|= 1,
        .page_down => p.scroll +|= 5,
        .page_up => p.scroll -|= 5,
        .home => p.scroll = 0,
        .end => p.scroll = std.math.maxInt(usize) / 2,
        .esc => try app.forceClosePane(id),
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'j' => p.scroll +|= 1,
                'k' => p.scroll -|= 1,
                'g' => p.scroll = 0,
                'G' => p.scroll = std.math.maxInt(usize) / 2,
                'q' => try app.forceClosePane(id),
                'a' => if (p.product == .claude) try toastFail(app, addCmd(app)) else return false,
                'r' => {
                    try refreshAll(app);
                    app.toast("refreshing {s} usage…", .{if (p.product == .claude) "Claude" else "Codex"});
                },
                'L' => if (p.product == .claude) {
                    _ = pty_pane.open(app, .{ .argv = &.{ "claude", "login" }, .label = "claude login", .placement = .below, .kind = .command }) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => app.toast("could not start `claude login`: {s}", .{@errorName(err)}),
                    };
                } else return false,
                'R' => if (p.product == .claude) {
                    if (builtin.os.tag != .macos) {
                        app.toast("the keychain capture is macOS-only — paste the token via ai.link_claude_token", .{});
                    } else if (fixtureDir(app) != null) {
                        app.toast("fixture mode: nothing to capture", .{});
                    } else if (st(app).keychain_pending) {
                        app.toast("the keychain is being read…", .{});
                    } else {
                        try spawnKeychain(app, .capture, .{});
                        app.toast("reading the keychain…", .{});
                    }
                } else return false,
                else => return false,
            }
        },
        else => return false,
    }
    return true;
}

// ─── the mouse ──────────────────────────────────────────────────────────

/// The Claude pane's `script_hit` ids: the header's kebab, a row outside
/// any account, a row of account `i`'s block, account `i`'s pencil, a row
/// of account `i`'s `This week by surface` rows.
pub const hit_kebab: u32 = 1;
pub const hit_body: u32 = 2;
pub const hit_account_base: u32 = 0x100;
pub const hit_pencil_base: u32 = 0x1000;
pub const hit_breakdown_base: u32 = 0x2000;
/// Account `i`'s *Re-auth* button on its state line.
pub const hit_reauth_base: u32 = 0x3000;

pub fn isPencilHit(id: u32) bool {
    return id >= hit_pencil_base and id < hit_breakdown_base;
}

pub fn isBreakdownHit(id: u32) bool {
    return id >= hit_breakdown_base and id < hit_reauth_base;
}

pub fn isReauthHit(id: u32) bool {
    return id >= hit_reauth_base;
}

/// The account a block, pencil or breakdown id names, in the order the
/// pane lists them.
pub fn accountOfHit(app: *App, id: u32) ?[]const u8 {
    const base: u32 = if (id >= hit_reauth_base) hit_reauth_base else if (id >= hit_breakdown_base) hit_breakdown_base else if (id >= hit_pencil_base) hit_pencil_base else if (id >= hit_account_base) hit_account_base else return null;
    const i = id - base;
    const s = st(app);
    return if (i < s.accounts.items.len) s.accounts.items[i].name else null;
}

/// A press in the Claude pane: the pencil renames; right-click on an
/// account's rows is that account's menu, anywhere else (or the kebab,
/// either button) the pane's.
pub fn click(app: *App, p: *UsagePane, hit_id: u32, m: @import("../core/key.zig").Mouse) Allocator.Error!void {
    if (m.kind != .press or p.product != .claude) return;
    const right = m.button == .right;
    if (hit_id == hit_kebab) return openPaneMenu(app, m.x, m.y);
    if (accountOfHit(app, hit_id)) |name| {
        if (isPencilHit(hit_id) and !right) return toastFail(app, openRenamePrompt(app, name));
        if (isReauthHit(hit_id) and !right) return toastFail(app, startReauth(app, name));
        if (right) return openAccountMenu(app, name, m.x, m.y);
        return;
    }
    if (right) return openPaneMenu(app, m.x, m.y);
}

fn toastFail(app: *App, r: CommandError!void) Allocator.Error!void {
    r catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (app.diag.msg) |msg| app.toast("{s}", .{msg}) else app.toast("{s}", .{command.reason(err)});
            app.diag.clear();
        },
    };
}

/// The pane's menu (the kebab, a right-click outside an account): add an
/// account, refresh, the raw response.
pub fn openPaneMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const rows = try context_menus.items(app, &.{
        .{ .label = "Add Claude account…", .action = .{ .command = .@"ai.claude_add_account" } },
        .{ .label = "Refresh usage now", .action = .{ .command = .@"ai.refresh_usage" }, .separator_before = true },
        .{ .label = "Show last response", .action = .{ .command = .@"ai.show_last_response" } },
    });
    errdefer app.gpa.free(rows);
    try app.openMenu("Claude usage", rows, x, y);
}

/// One account's menu, titled with its name: Re-auth it, rename it,
/// remove it, Advanced ▸ Paste a token…; then the pane's own rows.
pub fn openAccountMenu(app: *App, name: []const u8, x: u16, y: u16) Allocator.Error!void {
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const n = try mem.allocator().dupe(u8, name);
    const advanced = try mem.allocator().dupe(MenuItem, &.{
        .{ .label = "Paste a token…", .action = .{ .claude_account = .{ .act = .link, .name = n } } },
    });
    const rows = try context_menus.items(app, &.{
        .{ .label = "Re-auth", .action = .{ .claude_account = .{ .act = .reauth, .name = n } } },
        .{ .label = "Rename…", .action = .{ .claude_account = .{ .act = .rename, .name = n } } },
        .{ .label = "Remove…", .action = .{ .claude_account = .{ .act = .remove, .name = n } } },
        .{ .label = "Advanced", .action = .none, .submenu = advanced },
        .{ .label = "Add Claude account…", .action = .{ .command = .@"ai.claude_add_account" }, .separator_before = true },
        .{ .label = "Refresh usage now", .action = .{ .command = .@"ai.refresh_usage" } },
    });
    errdefer app.gpa.free(rows);
    try context_menus.openOwned(app, n, rows, x, y, mem);
}

pub fn scrollBy(p: *UsagePane, delta: i64) void {
    const cur: i64 = @intCast(p.scroll);
    p.scroll = @intCast(@max(cur + delta, 0));
}

/// Build the view's props off the state and paint.
pub fn draw(app: *App, ui: Ui, id: PaneId, p: *UsagePane, area: Rect) Allocator.Error!void {
    const s = st(app);
    const now = nowSecs(app);
    const views = try ui.arena.alloc(usage_view.AccountView, s.accounts.items.len);
    for (s.accounts.items, 0..) |*a, i| {
        views[i] = a.view();
        if (s.schedFor(a.name)) |sched| views[i].renewing = sched.pending and sched.renewing;
    }
    usage_view.draw(ui, id, area, p, .{
        .accounts = views,
        .codex = s.codex,
        .now = now,
        .tz = if (st(app).tz_override) |o| .{ .fixed = o } else .local,
        .loading = s.anyPending(),
    }, paneFocused(app, id));
}

// ─── the chip ───────────────────────────────────────────────────────────

/// The Claude chip in three runs, so the statusline can paint the middle
/// one differently: `head`, then `accent` (underlined when `underline`),
/// then `tail`. `joined` is the whole text.
pub const ChipParts = struct {
    head: []const u8,
    accent: []const u8 = "",
    tail: []const u8 = "",
    underline: bool = false,
    /// Set when the worst account is in warning or critical: the accent
    /// run paints as a dark mini-pill in that colour inside the brand
    /// chip (the percent on the coral itself was unreadable — Rust's
    /// #1139 took it off for that).
    tier: ?usage.Tier = null,
    /// The accent paints on the dark ink (the single chip's pill); off,
    /// it is the tier colour on the chip's own coral (the compact
    /// meter's warning account).
    on_ink: bool = true,

    pub fn joined(c: ChipParts, arena: Allocator) Allocator.Error![]const u8 {
        return std.mem.concat(arena, u8, &.{ c.head, c.accent, c.tail });
    }
};

/// The statusline's Claude chip: one account (`ai.chip_show_*` picks
/// the detail, `ai.chip_toggle_reset` the countdown), or every account
/// as `claude_meter_mode` says — compact (the sparkline) or ticker
/// (one at a time, 4 s each, its letter first, underlined when it is
/// the active account, as Rust's). One account configured is always the
/// single chip.
pub fn claudeChipParts(app: *App, arena: Allocator, glyph: []const u8) Allocator.Error!ChipParts {
    const s = st(app);
    const now = nowSecs(app);
    const opts: usage.ChipOpts = .{
        .glyph = glyph,
        .detail = switch (app.ai.chip_detail) {
            .session => .session,
            .weekly => .weekly,
            .both => .both,
        },
        .show_reset = app.ai.chip_reset_suffix,
        .now = now,
    };
    const n = s.accounts.items.len;
    const mode = if (n > 1) app.cfg.ai.claude_meter_mode else .off;
    switch (mode) {
        .compact => {
            const rows = try arena.alloc(usage.ChipAccount, n);
            for (s.accounts.items, 0..) |*a, i| rows[i] = a.chip();
            const c = try usage.compactChip(arena, rows, opts);
            if (c.spark.len == 0) return .{ .head = c.text };
            const head = c.text[0 .. c.text.len - c.spark.len - c.rest.len];
            // An account in warning or critical: its letter and percent
            // in the tier's colour on the coral, then one `!`, then the
            // arrow as it was — no ink block.
            if (warningIndex(s.accounts.items)) |wi| {
                const u = &s.accounts.items[wi].usage;
                const rest = if (std.mem.startsWith(u8, c.rest, "!")) c.rest[1..] else c.rest;
                return .{
                    .head = head,
                    .accent = try std.fmt.allocPrint(arena, "{c} {d}%", .{ usage.abbrev(s.accounts.items[wi].name), alarmPercent(u) }),
                    .tail = try std.fmt.allocPrint(arena, "!{s}", .{rest}),
                    .tier = usage.accountTier(u),
                    .on_ink = false,
                };
            }
            return .{ .head = head, .accent = c.spark, .tail = c.rest };
        },
        .ticker => {
            const a = &s.accounts.items[usage.tickerIndex(now, n)];
            // ` G 95% 52% ` cut after the glyph: the letter goes between.
            const full = try usage.singleChip(arena, &a.usage, null, opts);
            const cut = 1 + glyph.len + 1;
            const letter = try arena.dupe(u8, &.{usage.abbrev(a.name)});
            return .{ .head = full[0..cut], .accent = letter, .tail = try std.fmt.allocPrint(arena, " {s}", .{full[cut..]}), .underline = a.is_active };
        },
        .off => {
            const a = s.active() orelse return .{ .head = try std.fmt.allocPrint(arena, " {s} … ", .{glyph}) };
            const full = try usage.singleChip(arena, &a.usage, null, opts);
            const tier = if (a.usage.fetched_at > 0) alarm(usage.accountTier(&a.usage)) else null;
            const t_ = tier orelse return .{ .head = full };
            // ` G 95% 52% `: the figures are the pill, the spaces the chip's.
            const cut = 1 + glyph.len + 1;
            return .{ .head = full[0..cut], .accent = full[cut .. full.len - 1], .tail = " ", .tier = t_ };
        },
    }
}

/// One account as the chip's hover lists it: its name (and whether it is
/// the active one), then its two percents and the next reset.
pub const TipLine = struct { text: []const u8, sub: []const u8 };

pub fn chipTipLines(app: *App, arena: Allocator) Allocator.Error![]TipLine {
    const s = st(app);
    const now = nowSecs(app);
    // The account the `!` is about leads, named with its cause.
    const lead: usize = if (attention(app) != null) 1 else 0;
    const all = try arena.alloc(TipLine, s.accounts.items.len + lead);
    if (attention(app)) |ai| all[0] = .{
        .text = try std.fmt.allocPrint(arena, "! {s}: {s}", .{ s.accounts.items[ai].name, try attentionCause(app, arena, ai) }),
        .sub = "click: the usage pane, at this account",
    };
    const out = all[lead..];
    for (s.accounts.items, 0..) |*a, i| {
        const u = &a.usage;
        const text = try std.fmt.allocPrint(arena, "{s}{s}", .{ a.name, if (a.is_active) " (active)" else "" });
        const sub = if (u.fetched_at == 0)
            try std.fmt.allocPrint(arena, "{s}", .{if (u.last_error) |e| e else "not read yet"})
        else blk: {
            var next: u64 = 0;
            for ([_]u64{ u.resets_at, u.weekly_resets_at }) |at| if (at > now and (next == 0 or at < next)) {
                next = at;
            };
            var buf: [32]u8 = undefined;
            const when: []const u8 = if (next == 0) "" else if (next - now < 86_400) usage.fmtShortTime(&buf, next, tzOffset(app, next)) else usage.fmtLongTime(&buf, next, tzOffset(app, next));
            break :blk try std.fmt.allocPrint(arena, "{d}% session · {d}% week{s}{s}{s}", .{ u.percent, u.weekly_percent, if (next == 0) "" else " · resets ", when, if (u.last_error != null) " (stale)" else "" });
        };
        out[i] = .{ .text = text, .sub = sub };
    }
    return all;
}

/// A tier worth painting: warning or critical.
fn alarm(tier: usage.Tier) ?usage.Tier {
    return if (tier == .ok) null else tier;
}

/// The read account in the worst tier at warning or above (the higher
/// percent between two of a tier), by its place in the list.
pub fn warningIndex(accounts: []const Account) ?usize {
    var best: ?usize = null;
    for (accounts, 0..) |*a, i| {
        if (a.usage.fetched_at == 0) continue;
        const tier = usage.accountTier(&a.usage);
        if (tier == .ok) continue;
        if (best) |b| {
            const bt = usage.accountTier(&accounts[b].usage);
            if (@intFromEnum(tier) < @intFromEnum(bt)) continue;
            if (tier == bt and alarmPercent(&a.usage) <= alarmPercent(&accounts[b].usage)) continue;
        }
        best = i;
    }
    return best;
}

/// The percent behind an account's tier: the week's when the week is the
/// worse window, else the session's.
fn alarmPercent(u: *const usage.Usage) u16 {
    const session = usage.tierOfWire(u.percent, u.severity);
    const week = usage.tierOfWire(u.weekly_percent, u.weekly_severity);
    return if (@intFromEnum(week) > @intFromEnum(session)) u.weekly_percent else u.percent;
}

/// Why account `i` is the chip's `!`, in the state line's words or the
/// tier's.
pub fn attentionCause(app: *App, arena: Allocator, i: usize) Allocator.Error![]const u8 {
    const a = &st(app).accounts.items[i];
    const u = &a.usage;
    const state = usage.accountState(u);
    if (state.wantsReauth()) return usage_view.stateLine(arena, state, u, nowSecs(app), .{ .fixed = tzOffset(app, nowSecs(app)) });
    if (u.last_error) |e| return std.fmt.allocPrint(arena, "the last fetch failed — {s}", .{e});
    const session = usage.tierOfWire(u.percent, u.severity);
    const week = usage.tierOfWire(u.weekly_percent, u.weekly_severity);
    const tier = usage.worseTier(session, week);
    return std.fmt.allocPrint(arena, "{d}% of the {s} — {s}", .{ alarmPercent(u), if (@intFromEnum(week) > @intFromEnum(session)) "week" else "session", if (tier == .hot) "critical" else "warning" });
}

/// The chip as one string.
pub fn claudeChip(app: *App, arena: Allocator, glyph: []const u8) Allocator.Error![]const u8 {
    return (try claudeChipParts(app, arena, glyph)).joined(arena);
}

pub const CodexChip = struct { text: []const u8, has_data: bool };

/// ` 󱸁 12.3k ` — today's Codex tokens; `…` before the first scan.
pub fn codexChip(app: *App, arena: Allocator, glyph: []const u8) Allocator.Error!CodexChip {
    const c = st(app).codex orelse return .{ .text = try std.fmt.allocPrint(arena, " {s} … ", .{glyph}), .has_data = false };
    var buf: [16]u8 = undefined;
    return .{ .text = try std.fmt.allocPrint(arena, " {s} {s} ", .{ glyph, @import("../ai/transcript.zig").fmtTokens(&buf, c.tokens_today) }), .has_data = true };
}

// ─── the one-line summaries ─────────────────────────────────────────────

/// What the INTEGRATIONS row for *Claude Code* says under its label:
/// the chip's numbers spelled out, or why there are none. Read at
/// paint time from the same snapshots the chip and the pane read, so
/// it follows the reader's cadence with nothing to invalidate.
pub fn claudeSummary(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    const a = st(app).active() orelse return "not logged in";
    const u = &a.usage;
    if (usage.accountState(u).wantsReauth()) return "not logged in";
    if (u.fetched_at == 0) {
        if (u.last_error) |e| return std.fmt.allocPrint(arena, "no reading — {s}", .{e});
        return "not read yet";
    }
    return std.fmt.allocPrint(arena, "{d}% session · {d}% week{s}", .{ u.percent, u.weekly_percent, if (u.last_error != null) " (stale)" else "" });
}

/// The same for *Codex*, whose reader counts a day's transcripts
/// rather than asking an endpoint — so its "nothing" is a quiet day,
/// never a login.
pub fn codexSummary(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    const c = st(app).codex orelse return "not read yet";
    if (c.last_error) |e| return std.fmt.allocPrint(arena, "no reading — {s}", .{e});
    if (c.tokens_today == 0 and c.sessions_today == 0) return "no sessions today";
    var buf: [16]u8 = undefined;
    return std.fmt.allocPrint(arena, "{s} tokens today · {d} session{s}", .{
        @import("../ai/transcript.zig").fmtTokens(&buf, c.tokens_today),
        c.sessions_today,
        if (c.sessions_today == 1) "" else "s",
    });
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;
const screen_mod = @import("../ipc/screen.zig");

/// An App whose environment names a fixture directory seeded with two
/// accounts (`personal` at 95 / 52 % with a Fable row and a profile,
/// `work` throttled), a Codex day, a fixed clock and a UTC zone.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    dir: [std.fs.max_path_bytes]u8 = undefined,
    dir_len: usize = 0,

    fn init() !Fixture {
        var f: Fixture = .{ .tmp = t.tmpDir(.{}), .env = .init(t.allocator) };
        errdefer f.tmp.cleanup();
        f.dir_len = try f.tmp.dir.realPath(t.io, &f.dir);
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = "accounts", .data = "*personal\nwork\n" });
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = "personal.json", .data = usage.usage_fixture });
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = "personal.profile.json", .data = usage.profile_fixture });
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = "work.error", .data = "HTTP 429 retry-after=3150" });
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = "codex.json", .data = "{\"tokens_today\":1234567,\"sessions_today\":3}" });
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = "now", .data = "1789243232" });
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = "tz_offset", .data = "0" });
        try f.env.put(usage.fixture_env, f.dir[0..f.dir_len]);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.env.deinit();
        f.tmp.cleanup();
    }

    fn app(f: *Fixture) !App {
        return App.initWith(t.allocator, t.io, .{ .workspace = "/w", .cols = 120, .rows = 40, .env = &f.env });
    }
};

/// Tick until every spawned worker has answered (the fixture reads are
/// file reads on the thread pool; a bounded wait keeps a hang visible).
fn settle(app: *App) !void {
    var n: usize = 0;
    while (st(app).anyPending() or st(app).keychain_pending) : (n += 1) {
        if (n > 400) return error.UsageWorkersNeverAnswered;
        try app.tick(app.now_ms + 5);
        try t.io.sleep(.fromMilliseconds(5), .awake);
    }
    try app.tick(app.now_ms + 5);
}

test "ai.claude_usage opens the pane as a tab and the fixture's accounts land: session, weekly, the scoped row, the reset clocks, the throttled sibling" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var app = try fx.app();
    defer app.deinit();
    app.tree.visible = false;
    const ed = try app.openScratch();
    try command.run(&app, .{ .static = .@"ai.claude_usage" });
    const id = findPane(&app, .claude).?;
    try t.expect(id != ed);
    try t.expect(app.lastToast() == null or std.mem.indexOf(u8, app.lastToast().?, "not in this build") == null);
    // A tab in the editor's leaf, not a split (the header needs the width).
    try t.expectEqual(@as(usize, 1), (try app.layouts.current().leaves(app.frame.allocator())).len);
    try t.expectEqual(id, app.active.?);
    try settle(&app);
    try t.expectEqual(@as(usize, 2), st(&app).accounts.items.len);
    const personal = st(&app).find("personal").?;
    try t.expectEqual(@as(u16, 95), personal.usage.percent);
    try t.expect(personal.is_active);
    try t.expectEqualStrings("me@example.com", personal.email.?);
    const work = st(&app).find("work").?;
    try t.expectEqual(@as(u64, 0), work.usage.fetched_at);
    try t.expectEqual(@as(u64, 1789243232 + 3150), work.usage.retry_after_at);
    try app.render();
    const txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "Claude usage") != null);
    try t.expect(std.mem.indexOf(u8, txt, "(active) personal") != null);
    try t.expect(std.mem.indexOf(u8, txt, "me@example.com") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Current session") != null);
    try t.expect(std.mem.indexOf(u8, txt, "95% used") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Resets 8:20pm") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Current week (all models)") != null);
    try t.expect(std.mem.indexOf(u8, txt, "52% used") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Resets Sep 19 at 5am") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Current week (Fable)") != null);
    try t.expect(std.mem.indexOf(u8, txt, "55% used") != null);
    try t.expect(std.mem.indexOf(u8, txt, "retry in 3150s (429)") != null);
    try t.expect(std.mem.indexOf(u8, txt, "last error: HTTP 429 retry-after=3150") != null);
    try t.expect(std.mem.indexOf(u8, txt, "AI spend") == null);
    // `q` closes it; a second open reuses one pane.
    try app.handle(.{ .key = Key.char('q') });
    try t.expect(findPane(&app, .claude) == null);
    try command.run(&app, .{ .static = .@"ai.claude_usage" });
    try command.run(&app, .{ .static = .@"ai.claude_usage" });
    var n: usize = 0;
    for (app.panes.slots.items) |*slot| if (slot.*) |*pane| if (pane.* == .ai_usage) {
        n += 1;
    };
    try t.expectEqual(@as(usize, 1), n);
    try settle(&app);
}

test "ai.codex_usage: the spare pane — tokens today with thousands, the session count, the scan time" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var app = try fx.app();
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"ai.codex_usage" });
    try settle(&app);
    try app.render();
    const txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "Codex usage") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Tokens today") != null);
    try t.expect(std.mem.indexOf(u8, txt, "1,234,567") != null);
    try t.expect(std.mem.indexOf(u8, txt, "3 sessions") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Last scan: 8pm") != null);
    try t.expect(std.mem.indexOf(u8, txt, "AI spend") == null);
}

test "the pane's states: a line per account — signed in, checking, no login, expired, another account's — and a Re-auth button where it wants one" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "accounts", .data = "personal\nghost\n*locked\nstale\n" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "locked.error", .data = "needs-reauth: the keychain login is other@example.com, not locked's" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "stale.error", .data = "HTTP 401: token rejected" });
    var app = try fx.app();
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"ai.claude_usage" });
    // Before any result: the empty state.
    try app.render();
    var txt = try screen_mod.toTestText(t.allocator, &app.screen);
    try t.expect(std.mem.indexOf(u8, txt, "fetching… (a adds an account)") != null);
    t.allocator.free(txt);
    try settle(&app);
    const pid = findPane(&app, .claude).?;
    switch (app.panes.get(pid).?.*) {
        .ai_usage => |*p| p.scroll = 0,
        else => unreachable,
    }
    try app.resize(120, 80);
    try app.render();
    txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "signed in · resets 8:20pm") != null);
    try t.expect(std.mem.indexOf(u8, txt, "no login yet —  Re-auth") != null);
    try t.expect(std.mem.indexOf(u8, txt, "keychain holds another account —  Re-auth") != null);
    try t.expect(std.mem.indexOf(u8, txt, "expired —  Re-auth") != null);
    // The fix is the button: no steps, no backoff, no raw error.
    try t.expect(std.mem.indexOf(u8, txt, "press L") == null);
    try t.expect(std.mem.indexOf(u8, txt, "press R") == null);
    try t.expect(std.mem.indexOf(u8, txt, "next fetch in") == null);
    try t.expect(std.mem.indexOf(u8, txt, "last error: not linked") == null);
    try t.expect(std.mem.indexOf(u8, txt, "token rejected") == null);
    try t.expect(std.mem.indexOf(u8, txt, "(active) locked") != null);
    // Each button is its account's hit.
    var buttons: usize = 0;
    for (app.hits.items.items) |h| if (h.target == .script_hit and isReauthHit(h.target.script_hit.id)) {
        buttons += 1;
        const name = accountOfHit(&app, h.target.script_hit.id).?;
        try t.expect(!std.mem.eql(u8, name, "personal"));
    };
    try t.expectEqual(@as(usize, 3), buttons);
    // The chip's `!` is the first account wanting a Re-auth: a click
    // opens the pane scrolled to its block.
    try t.expectEqual(@as(?usize, 1), attention(&app));
    try app.resize(120, 16);
    try t.expect(try chipAttentionClick(&app));
    try app.render();
    switch (app.panes.get(pid).?.*) {
        .ai_usage => |*p| {
            try t.expect(p.scroll_to == null);
            try t.expect(p.scroll > 0);
        },
        else => unreachable,
    }
}

test "the state line's words, per state" {
    const a = t.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const now: u64 = 1789243232; // 2026-09-12 20:00:32 UTC
    const tz: usage_view.Tz = .{ .fixed = 0 };
    var u: usage.Usage = .{ .fetched_at = now, .percent = 40, .resets_at = now + 1168, .weekly_resets_at = now + 86_400 * 6 };
    try t.expectEqual(usage.AccountState.signed_in, usage.accountState(&u));
    try t.expectEqualStrings("signed in · resets 8:20pm", try usage_view.stateLine(ar, usage.accountState(&u), &u, now, tz));
    // The session reset passed: the week's, in the long form.
    u.resets_at = now - 10;
    try t.expectEqualStrings("signed in · resets Sep 18 at 8pm", try usage_view.stateLine(ar, usage.accountState(&u), &u, now, tz));
    // Expired with a fetch out renewing it: no button yet.
    var stale: usage.Usage = .{ .fetched_at = now, .percent = 40 };
    usage.applyFetchError(&stale, .{ .message = "HTTP 401: token rejected", .auth = .rejected }, now);
    try t.expectEqualStrings("expired — refreshing…", try usage_view.stateLine(ar, usage.shownState(&stale, true), &stale, now, tz));
    try t.expectEqualStrings("expired — Re-auth", try usage_view.stateLine(ar, usage.shownState(&stale, false), &stale, now, tz));
    // No reading yet.
    var fresh: usage.Usage = .{};
    try t.expectEqualStrings("checking…", try usage_view.stateLine(ar, usage.accountState(&fresh), &fresh, now, tz));
    // Each sign-in failure, the button's word after it.
    const cases = [_]struct { auth: usage.Auth, want: []const u8 }{
        .{ .auth = .rejected, .want = "expired — Re-auth" },
        .{ .auth = .other_login, .want = "keychain holds another account — Re-auth" },
        .{ .auth = .missing, .want = "no login yet — Re-auth" },
    };
    for (cases) |c| {
        var f: usage.Usage = .{ .fetched_at = now, .percent = 40 };
        usage.applyFetchError(&f, .{ .message = "x", .auth = c.auth, .needs_reauth = c.auth == .other_login }, now);
        try t.expect(usage.accountState(&f).wantsReauth());
        try t.expectEqualStrings(c.want, try usage_view.stateLine(ar, usage.accountState(&f), &f, now, tz));
    }
    // A failure that is not the sign-in's leaves it signed in (the stale
    // reading keeps its own error line).
    var net: usage.Usage = .{ .fetched_at = now, .percent = 40 };
    usage.applyFetchError(&net, .{ .message = "HTTP 500: boom" }, now);
    try t.expectEqual(usage.AccountState.signed_in, usage.accountState(&net));
}

test "the chip reads the same accounts: single, compact and ticker, the detail and the countdown" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var app = try fx.app();
    defer app.deinit();
    const icons = [_]app_mod.Config.IntegrationIcon{
        .{ .id = "claude_code", .glyph = "\u{F1E00}", .fallback = "\u{2733}", .command = "ai.claude_code", .color = @import("../ui/brand.zig").claude_hex, .label = "Claude Code", .enabled = true, .in_palette_bar = false },
        .{ .id = "codex", .glyph = "\u{F1E01}", .fallback = "\u{25c8}", .command = "ai.codex", .color = "", .label = "Codex", .enabled = true, .in_palette_bar = false },
    };
    app.cfg.ui.integration_icons = &icons;
    app.cfg.ai.claude_meter_mode = .off;
    try refreshAll(&app);
    try settle(&app);
    const arena = app.frame.allocator();
    // Off: the active account only, both windows by default.
    try t.expectEqualStrings(" G 95% 52% ", try claudeChip(&app, arena, "G"));
    app.ai.chip_detail = .session;
    try t.expectEqualStrings(" G 95% ", try claudeChip(&app, arena, "G"));
    app.ai.chip_reset_suffix = true;
    try t.expectEqualStrings(" G 95% 19m ", try claudeChip(&app, arena, "G"));
    app.ai.chip_detail = .both;
    try t.expectEqualStrings(" G 95% 19m 52% 6d ", try claudeChip(&app, arena, "G"));
    app.ai.chip_reset_suffix = false;
    // Compact: a block per account (`!` for the throttled one, never read); personal is the
    // one to spend on (5 % left in 19 min beats an unread sibling), so the arrow points at it.
    app.cfg.ai.claude_meter_mode = .compact;
    // personal is critical (95 %): its letter and percent stand in for the
    // blocks, then one `!`, then the arrow as it was.
    try t.expectEqualStrings(" G P 95%! →P ", try claudeChip(&app, arena, "G"));
    // Ticker: the account of the slot, its letter first.
    app.cfg.ai.claude_meter_mode = .ticker;
    try t.expectEqualStrings(" G P 95% 52% ", try claudeChip(&app, arena, "G"));
    st(&app).now_override = 1789243232 + 4;
    try t.expectEqualStrings(" G W —! ", try claudeChip(&app, arena, "G"));
    st(&app).now_override = 1789243232;
    try t.expect(tickerActive(&app));
    // The Codex chip reads the same scan.
    const cx = try codexChip(&app, arena, "X");
    try t.expectEqualStrings(" X 1.2M ", cx.text);
    try t.expect(cx.has_data);
    // The statusline paints it (ticker → the active account's letter).
    app.tree.visible = false;
    _ = try app.openScratch();
    try app.render();
    const txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, " P 95% 52% ") != null);
    try t.expect(std.mem.indexOf(u8, txt, " 1.2M ") != null);
    // Rust's ticker underlines the letter of the active account.
    const hit_rect = for (app.hits.items.items) |h| {
        if (h.target == .statusline_seg and h.target.statusline_seg == @import("statusline.zig").SegId.ai_claude.raw()) break h.rect;
    } else return error.NoClaudeChip;
    var letter_x: ?u16 = null;
    var x = hit_rect.x;
    while (x < hit_rect.x + hit_rect.w) : (x += 1) {
        const c = app.screen.readCell(x, hit_rect.y) orelse continue;
        if (std.mem.eql(u8, c.char.grapheme, "P")) letter_x = x;
    }
    try t.expect(app.screen.readCell(letter_x.?, hit_rect.y).?.style.ul_style == .single);
    try t.expect(app.screen.readCell(letter_x.? + 2, hit_rect.y).?.style.ul_style == .off);
}

test "the usage panes' tabs read as Rust's: Claude Usage, Codex Usage" {
    try t.expectEqualStrings("Claude Usage", (UsagePane{ .product = .claude }).title());
    try t.expectEqualStrings("Codex Usage", (UsagePane{ .product = .codex }).title());
}

test "the 0.2.x [[ai.claude.accounts]] blocks, migrated verbatim under .ai.claude.accounts, are the account list" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/w", .data_root = "/data" });
    defer app.deinit();
    const D = app_mod.Config.Dynamic;
    const personal = [_]D.Field{ .{ .name = "name", .value = .{ .string = "personal" } }, .{ .name = "token_path", .value = .{ .string = "ai_token.personal" } } };
    const work = [_]D.Field{ .{ .name = "active", .value = .{ .bool = true } }, .{ .name = "name", .value = .{ .string = "work" } }, .{ .name = "token_path", .value = .{ .string = "~/.claude/work.json" } } };
    const list = [_]D{ .{ .object = &personal }, .{ .object = &work } };
    const accounts = [_]D.Field{.{ .name = "accounts", .value = .{ .array = &list } }};
    const claude = [_]D.Field{.{ .name = "claude", .value = .{ .object = &accounts } }};
    app.cfg.ai.extra = .{ .object = &claude };
    const cfg = try configured(&app, app.frame.allocator());
    try t.expectEqual(@as(usize, 2), cfg.len);
    try t.expectEqualStrings("personal", cfg[0].name);
    try sdk_testing.expectPath("/data/ai_token.personal", cfg[0].token_path);
    try t.expect(!cfg[0].active and cfg[1].active);
    try t.expectEqualStrings("work", cfg[1].name);
    // The typed list wins when it is there.
    const typed = [_]app_mod.Config.ClaudeAccount{.{ .name = "solo", .token_path = "tok", .active = true }};
    app.cfg.ai.claude_accounts = &typed;
    const cfg2 = try configured(&app, app.frame.allocator());
    try t.expectEqual(@as(usize, 1), cfg2.len);
    try t.expectEqualStrings("solo", cfg2[0].name);
}

test "the cadence: one spawn per tick with the gap, the backed-off account skipped, a force spawns all" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var app = try fx.app();
    defer app.deinit();
    const icons = [_]app_mod.Config.IntegrationIcon{
        .{ .id = "claude_code", .glyph = "", .fallback = "", .command = "ai.claude_code", .color = "", .label = "Claude Code", .enabled = true, .in_palette_bar = false },
    };
    app.cfg.ui.integration_icons = &icons;
    const s = st(&app);
    try tick(&app);
    var pending: usize = 0;
    for (s.sched.items) |sc| if (sc.pending) {
        pending += 1;
    };
    try t.expectEqual(@as(usize, 1), pending);
    try t.expectEqual(@as(u64, 1789243232), s.last_spawn_at);
    try settle(&app);
    // Within the gap nothing else goes out; past it, the second account.
    s.now_override = 1789243232 + 5;
    try tick(&app);
    try t.expect(!s.anyPending());
    s.now_override = 1789243232 + 25;
    try tick(&app);
    try t.expect(s.schedFor("work").?.pending);
    try settle(&app);
    // `work` is backed off (3150 s): a later tick skips it while personal refreshes on its interval.
    s.now_override = 1789243232 + 25 + usage.refresh_interval_s;
    try tick(&app);
    try t.expect(s.schedFor("personal").?.pending);
    try t.expect(!s.schedFor("work").?.pending);
    try settle(&app);
    s.now_override = 1789243232 + 26 + usage.refresh_interval_s;
    try refreshAll(&app);
    try t.expect(s.schedFor("personal").?.pending and s.schedFor("work").?.pending);
    try settle(&app);
    // Listed as configured, whatever order the results landed in.
    try t.expectEqualStrings("personal", s.accounts.items[0].name);
    try t.expectEqualStrings("work", s.accounts.items[1].name);
    // An account dropped from the fixture's list is pruned.
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "accounts", .data = "*personal\n" });
    s.now_override = 1789243232 + 5000;
    try tick(&app);
    try t.expect(s.find("work") == null);
    try t.expect(s.schedFor("work") == null);
    try settle(&app);
}

test "the INTEGRATIONS row's quota line, per reader state" {
    // Nothing configured and no fixture: the row says why there is no
    // number rather than showing a zero.
    {
        var bare = try App.initWith(t.allocator, t.io, .{ .workspace = "/w", .cols = 80, .rows = 24 });
        defer bare.deinit();
        try t.expectEqualStrings("not logged in", try claudeSummary(&bare, bare.frame.allocator()));
        try t.expectEqualStrings("not read yet", try codexSummary(&bare, bare.frame.allocator()));
    }
    var fx = try Fixture.init();
    defer fx.deinit();
    var app = try fx.app();
    defer app.deinit();
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"ai.claude_usage" });
    try command.run(&app, .{ .static = .@"ai.codex_usage" });
    try settle(&app);
    try t.expectEqualStrings("95% session · 52% week", try claudeSummary(&app, app.frame.allocator()));
    try t.expectEqualStrings("1.2M tokens today · 3 sessions", try codexSummary(&app, app.frame.allocator()));
    // A reading on top of a failure is stale, not gone.
    const personal = st(&app).find("personal").?;
    personal.usage.last_error = "HTTP 500";
    try t.expectEqualStrings("95% session · 52% week (stale)", try claudeSummary(&app, app.frame.allocator()));
    // The keychain's login is another account's: the row says so, which
    // is what the pane's guided re-auth is for.
    personal.usage.needs_reauth = true;
    try t.expectEqualStrings("not logged in", try claudeSummary(&app, app.frame.allocator()));
    // A quiet Codex day reads as one, not as a login problem.
    st(&app).codex = .{ .tokens_today = 0, .sessions_today = 0, .fetched_at = 1 };
    try t.expectEqualStrings("no sessions today", try codexSummary(&app, app.frame.allocator()));
}

/// Type `text` into whatever has the keys, then Enter.
fn typeLine(app: *App, text: []const u8) !void {
    for (text) |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
}

/// A fixture directory with no `accounts` file — the config's list is
/// the account list — and a data root beside it.
const AccountsFixture = struct {
    fx: Fixture,
    data: [std.fs.max_path_bytes]u8 = undefined,
    data_len: usize = 0,

    fn init() !AccountsFixture {
        var f: AccountsFixture = .{ .fx = try Fixture.init() };
        errdefer f.fx.deinit();
        try f.fx.tmp.dir.deleteFile(t.io, "accounts");
        try f.fx.tmp.dir.createDirPath(t.io, "data");
        try f.fx.tmp.dir.writeFile(t.io, .{ .sub_path = "client.json", .data = usage.usage_fixture });
        const d = try std.fmt.bufPrint(&f.data, "{s}/data", .{f.fx.dir[0..f.fx.dir_len]});
        f.data_len = d.len;
        return f;
    }

    fn app(f: *AccountsFixture) !App {
        return App.initWith(t.allocator, t.io, .{ .workspace = "/w", .data_root = f.data[0..f.data_len], .cols = 120, .rows = 40, .env = &f.fx.env });
    }

    fn read(f: *AccountsFixture, rel: []const u8) ![]u8 {
        return f.fx.tmp.dir.readFileAlloc(t.io, rel, t.allocator, .limited(64 * 1024));
    }
};

test "ai.claude_add_account: a name — the account joins the home config beside the default with a token file of its own; no token prompt opens on its own, Advanced ▸ Paste a token… links it (0600), and it is fetched" {
    var f = try AccountsFixture.init();
    defer f.fx.deinit();
    // The implicit `default` account is linked, so it must survive the add.
    try f.fx.tmp.dir.writeFile(t.io, .{ .sub_path = "data/ai_token", .data = "fake-default-token" });
    try f.fx.tmp.dir.writeFile(t.io, .{ .sub_path = "Client A.json", .data = usage.usage_fixture });
    var app = try f.app();
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"ai.claude_add_account" });
    try t.expect(app.overlay == .prompt and app.overlay.prompt.purpose == .claude_account_add);
    try typeLine(&app, "Client A");
    // No prompt for a token: the account waits for its Re-auth.
    try t.expect(app.overlay != .prompt);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "Re-auth signs it in") != null);
    // The account menu's Advanced ▸ Paste a token… is where one is pasted.
    try openAccountMenu(&app, "Client A", 5, 5);
    const adv = for (app.overlay.menu.items) |it| {
        if (std.mem.eql(u8, it.label, "Advanced")) break it;
    } else return error.NoAdvancedRow;
    try t.expectEqual(@as(usize, 1), adv.submenu.len);
    try t.expectEqualStrings("Paste a token…", adv.submenu[0].label);
    try t.expectEqual(command.ClaudeAccountAct.Verb.link, adv.submenu[0].action.claude_account.act);
    try t.expectEqualStrings("Re-auth", app.overlay.menu.items[0].label);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    try accountAction(&app, .link, "Client A");
    try t.expect(app.overlay == .prompt and app.overlay.prompt.purpose == .claude_account_token);
    try t.expectEqualStrings("Client A", app.overlay.prompt.purpose.claude_account_token.name);
    try t.expect(app.overlay.prompt.state.secret);
    try typeLine(&app, "fake-token-for-tests");
    // The config: the default kept (still active), the new one after it.
    try t.expectEqual(@as(usize, 2), app.cfg.ai.claude_accounts.len);
    try t.expectEqualStrings("default", app.cfg.ai.claude_accounts[0].name);
    try t.expect(app.cfg.ai.claude_accounts[0].active);
    try t.expectEqualStrings("Client A", app.cfg.ai.claude_accounts[1].name);
    try t.expectEqualStrings("ai_token.client-a", app.cfg.ai.claude_accounts[1].token_path);
    try t.expect(!app.cfg.ai.claude_accounts[1].active);
    const zon = try f.read("data/config.zon");
    defer t.allocator.free(zon);
    try t.expect(std.mem.indexOf(u8, zon, ".name = \"Client A\"") != null);
    try t.expect(std.mem.indexOf(u8, zon, ".token_path = \"ai_token.client-a\"") != null);
    try t.expect(std.mem.indexOf(u8, zon, ".name = \"default\"") != null);
    // The token file, private.
    const tok = try f.read("data/ai_token.client-a");
    defer t.allocator.free(tok);
    try t.expectEqualStrings("fake-token-for-tests", tok);
    if (builtin.os.tag != .windows) {
        const stat = try f.fx.tmp.dir.statFile(t.io, "data/ai_token.client-a", .{});
        try t.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    }
    // A second account of the same name is refused.
    try command.run(&app, .{ .static = .@"ai.claude_add_account" });
    try typeLine(&app, "Client A");
    try t.expect(app.overlay != .prompt);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "already an account") != null);
    try settle(&app);
    // Fetched: the fixture's numbers under the new name.
    try t.expectEqual(@as(u16, 95), st(&app).find("Client A").?.usage.percent);
}

test "rename and remove: the config, the snapshot, the pin; a token file under the data root goes, one outside it stays" {
    var f = try AccountsFixture.init();
    defer f.fx.deinit();
    try f.fx.tmp.dir.createDirPath(t.io, "outside");
    try f.fx.tmp.dir.writeFile(t.io, .{ .sub_path = "outside/tok", .data = "fake-outside-token" });
    try f.fx.tmp.dir.writeFile(t.io, .{ .sub_path = "data/ai_token.client", .data = "fake-client-token" });
    try f.fx.tmp.dir.writeFile(t.io, .{ .sub_path = "data/ai_account_identity.json", .data = "{\"client\":\"c@example.com\"}" });
    var outside_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outside = try std.fmt.bufPrint(&outside_buf, "{s}/outside/tok", .{f.fx.dir[0..f.fx.dir_len]});
    const initial = [_]app_mod.Config.ClaudeAccount{
        .{ .name = "client", .token_path = "ai_token.client", .active = true },
        .{ .name = "ext", .token_path = outside },
    };
    var app = try f.app();
    defer app.deinit();
    app.cfg.ai.claude_accounts = &initial;
    app.tree.visible = false;
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"ai.claude_usage" });
    try settle(&app);
    try t.expect(st(&app).find("client") != null);
    // Two accounts: the palette asks which.
    try command.run(&app, .{ .static = .@"ai.claude_rename_account" });
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("Rename which Claude account?", app.overlay.menu.title);
    try t.expectEqual(@as(usize, 2), app.overlay.menu.items.len);
    try @import("dispatch.zig").runMenuActionForTest(&app, .{ .claude_account = .{ .act = .rename, .name = "client" } });
    try t.expect(app.overlay == .prompt and app.overlay.prompt.purpose == .claude_account_rename);
    try t.expectEqualStrings("client", app.overlay.prompt.state.text());
    // The seed is a selection: typing replaces it.
    try typeLine(&app, "acme");
    try t.expectEqualStrings("acme", app.cfg.ai.claude_accounts[0].name);
    try t.expectEqualStrings("ai_token.client", app.cfg.ai.claude_accounts[0].token_path);
    try t.expect(st(&app).find("acme") != null and st(&app).find("client") == null);
    try t.expect(st(&app).schedFor("acme") != null);
    try t.expectEqualStrings("c@example.com", (try usage.pinnedEmail(app.frame.allocator(), t.io, app.data_root, "acme")).?);
    // A clash and a bad name are refused.
    try usage_paneRename(&app, "acme", "ext");
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "already an account") != null);
    try usage_paneRename(&app, "acme", "a\"b");
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "no quotes") != null);
    // Remove the renamed one: confirmed, gone from the config and the
    // pane, its file (under the data root) deleted, its pin dropped, the
    // active flag moved to the one left.
    try command.run(&app, .{ .static = .@"ai.claude_remove_account" });
    try @import("dispatch.zig").runMenuActionForTest(&app, .{ .claude_account = .{ .act = .remove, .name = "acme" } });
    try t.expect(app.overlay == .confirm and app.overlay.confirm.purpose == .remove_claude_account);
    try t.expect(std.mem.indexOf(u8, app.overlay.confirm.message, "is deleted") != null);
    try app.handle(.{ .key = Key.char('r') });
    try t.expectEqual(@as(usize, 1), app.cfg.ai.claude_accounts.len);
    try t.expectEqualStrings("ext", app.cfg.ai.claude_accounts[0].name);
    try t.expect(app.cfg.ai.claude_accounts[0].active);
    try t.expect(st(&app).find("acme") == null);
    try t.expectError(error.FileNotFound, f.fx.tmp.dir.access(t.io, "data/ai_token.client", .{}));
    try t.expect((try usage.pinnedEmail(app.frame.allocator(), t.io, app.data_root, "acme")) == null);
    const zon = try f.read("data/config.zon");
    defer t.allocator.free(zon);
    try t.expect(std.mem.indexOf(u8, zon, "acme") == null);
    // The one outside the data root: out of the config, its file kept.
    try command.run(&app, .{ .static = .@"ai.claude_remove_account" });
    try t.expect(app.overlay == .confirm);
    try t.expect(std.mem.indexOf(u8, app.overlay.confirm.message, "stays") != null);
    try app.handle(.{ .key = Key.char('r') });
    try t.expectEqual(@as(usize, 0), app.cfg.ai.claude_accounts.len);
    try f.fx.tmp.dir.access(t.io, "outside/tok", .{});
    try settle(&app);
}

fn usage_paneRename(app: *App, old: []const u8, new: []const u8) !void {
    try openRenamePrompt(app, old);
    try typeLine(app, new);
}

test "the pane's mouse: the pencil renames, an account's rows open its menu, the kebab and the rest the pane's; `a` adds" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var app = try fx.app();
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"ai.claude_usage" });
    try settle(&app);
    try app.render();
    const txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "(active) personal " ++ usage_view.pencil_glyph ++ " · me@example.com") != null);
    const id = findPane(&app, .claude).?;
    var pencil: ?Rect = null;
    var block: ?Rect = null;
    var kebab: ?Rect = null;
    var body: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .script_hit and h.target.script_hit.pane == id) {
        const hid = h.target.script_hit.id;
        if (hid == hit_pencil_base) pencil = h.rect;
        if (hid == hit_account_base + 1 and block == null) block = h.rect;
        if (hid == hit_kebab) kebab = h.rect;
        if (hid == hit_body and body == null) body = h.rect;
    };
    const Mouse = @import("../core/key.zig").Mouse;
    const press = struct {
        fn at(a: *App, r: Rect, button: @FieldType(Mouse, "button")) !void {
            try a.handle(.{ .mouse = .{ .x = r.x, .y = r.y, .kind = .press, .button = button } });
        }
    }.at;
    try press(&app, pencil.?, .left);
    try t.expect(app.overlay == .prompt and app.overlay.prompt.purpose == .claude_account_rename);
    try t.expectEqualStrings("personal", app.overlay.prompt.purpose.claude_account_rename.name);
    try app.handle(.{ .key = Key.named(.esc) });
    try press(&app, block.?, .right);
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("work", app.overlay.menu.title);
    try t.expect(app.overlay.menu.items[1].action == .claude_account);
    try t.expectEqual(command.ClaudeAccountAct.Verb.rename, app.overlay.menu.items[1].action.claude_account.act);
    try app.handle(.{ .key = Key.named(.esc) });
    try press(&app, kebab.?, .left);
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("Claude usage", app.overlay.menu.title);
    try t.expectEqual(command.CommandId.@"ai.claude_add_account", app.overlay.menu.items[0].action.command);
    try app.handle(.{ .key = Key.named(.esc) });
    try press(&app, body.?, .right);
    try t.expectEqualStrings("Claude usage", app.overlay.menu.title);
    try app.handle(.{ .key = Key.named(.esc) });
    app.focus = .{ .pane = id };
    try app.handle(.{ .key = Key.char('a') });
    try t.expect(app.overlay == .prompt and app.overlay.prompt.purpose == .claude_account_add);
    try app.handle(.{ .key = Key.named(.esc) });
    // The chip's menu offers the add; the Codex one does not.
    try @import("context_menus.zig").openAiChipMenu(&app, false, 3, 3);
    var has_add = false;
    for (app.overlay.menu.items) |it| if (it.action == .command and it.action.command == .@"ai.claude_add_account") {
        has_add = true;
    };
    try t.expect(has_add);
    try @import("context_menus.zig").openAiChipMenu(&app, true, 3, 3);
    for (app.overlay.menu.items) |it| try t.expect(!(it.action == .command and it.action.command == .@"ai.claude_add_account"));
    try app.handle(.{ .key = Key.named(.esc) });
}

test "the wire's severity colours the bar over the thresholds; unknown keys are logged once per account" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "accounts", .data = "*personal\n" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "personal.json", .data = usage.usage_wide_fixture });
    var app = try fx.app();
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"ai.claude_usage" });
    try settle(&app);
    const a = st(&app).find("personal").?;
    try t.expectEqual(usage.Severity.critical, a.usage.weekly_severity.?);
    // Five keys this build does not read — the codename that no longer
    // passes for a reset offer among them: logged, once.
    try t.expectEqual(@as(usize, 5), st(&app).unknown_logged);
    try refreshAll(&app);
    try settle(&app);
    try t.expectEqual(@as(usize, 5), st(&app).unknown_logged);
    // 61 % is yellow by the thresholds; the endpoint says critical: red.
    try app.render();
    const pal = &app.theme.palette;
    var found = false;
    var y: u16 = 0;
    while (y < app.screen.height) : (y += 1) {
        var x: u16 = 0;
        var row: std.ArrayListUnmanaged(u8) = .empty;
        defer row.deinit(t.allocator);
        while (x < app.screen.width) : (x += 1) if (app.screen.readCell(x, y)) |c| try row.appendSlice(t.allocator, c.char.grapheme);
        if (std.mem.indexOf(u8, row.items, "61% used") == null) continue;
        // The bar starts after the pane's gutter (the last `▌` on the
        // row — the chrome's focus cue may paint one further left).
        var gx: ?u16 = null;
        var bx: u16 = 0;
        while (bx < app.screen.width) : (bx += 1) {
            const c = app.screen.readCell(bx, y) orelse continue;
            if (std.mem.eql(u8, c.char.grapheme, usage_view.gutter_glyph)) gx = bx;
        }
        // A few cells in: well inside the 61 % that is filled.
        const bar = app.screen.readCell(gx.? + 5, y).?;
        try t.expect(@import("vaxis").Color.eql(bar.style.bg, pal.red));
        found = true;
        break;
    }
    try t.expect(found);
}

test "the chip at a glance: the worst account's colour as a pill, no reset mark off a codename; the hover lists every account" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "accounts", .data = "*personal\nwork\nspare\n" });
    // `spare`: 88 % and 30 %, graded warning, and a codename with clocks.
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "spare.json", .data = usage.usage_wide_fixture });
    var app = try fx.app();
    defer app.deinit();
    const icons = [_]app_mod.Config.IntegrationIcon{
        .{ .id = "claude_code", .glyph = "\u{F1E00}", .fallback = "\u{2733}", .command = "ai.claude_code", .color = @import("../ui/brand.zig").claude_hex, .label = "Claude Code", .enabled = true, .in_palette_bar = false },
    };
    app.cfg.ui.integration_icons = &icons;
    app.cfg.ai.claude_meter_mode = .compact;
    try refreshAll(&app);
    try settle(&app);
    const arena = app.frame.allocator();
    const parts = try claudeChipParts(&app, arena, "G");
    // personal's 95 % critical is the worst: its letter and percent, the
    // tier's colour on the coral — no ink block — then a `!`.
    try t.expectEqualStrings("P 95%", parts.accent);
    try t.expectEqual(usage.Tier.hot, parts.tier.?);
    try t.expect(!parts.on_ink);
    try t.expect(std.mem.startsWith(u8, parts.tail, "!"));
    try t.expect(std.mem.indexOf(u8, parts.tail, "→") != null);
    // Painted: red on the chip's own coral.
    app.tree.visible = false;
    _ = try app.openScratch();
    try app.render();
    const r = for (app.hits.items.items) |h| {
        if (h.target == .statusline_seg and h.target.statusline_seg == @import("statusline.zig").SegId.ai_claude.raw()) break h.rect;
    } else return error.NoClaudeChip;
    var x = r.x;
    var seen = false;
    while (x < r.x + r.w) : (x += 1) {
        const c = app.screen.readCell(x, r.y) orelse continue;
        try t.expect(!std.mem.eql(u8, c.char.grapheme, "↺"));
        try t.expect(!std.mem.eql(u8, c.char.grapheme, "▇"));
        if (!std.mem.eql(u8, c.char.grapheme, "%")) continue;
        try t.expect(@import("vaxis").Color.eql(c.style.fg, app.theme.palette.red));
        try t.expect(@import("vaxis").Color.eql(c.style.bg, app.screen.readCell(r.x, r.y).?.style.bg));
        seen = true;
    }
    try t.expect(seen);
    // The hover: the account the `!` is about and why, then every
    // account, its two percents and the next reset.
    const tip = (try @import("discovery.zig").describe(&app, arena, .{ .statusline_seg = @import("statusline.zig").SegId.ai_claude.raw() })).?;
    try t.expectEqual(@as(usize, 4), tip.rows.len);
    try t.expectEqualStrings("! personal: 95% of the session — critical", tip.rows[0].text);
    try t.expectEqualStrings("personal (active)", tip.rows[1].text);
    try t.expectEqualStrings("95% session · 52% week · resets 8:20pm", tip.rows[1].sub);
    try t.expectEqualStrings("work", tip.rows[2].text);
    try t.expect(std.mem.indexOf(u8, tip.rows[2].sub, "429") != null);
    try t.expectEqualStrings("spare", tip.rows[3].text);
    try t.expectEqualStrings("88% session · 61% week · resets 10pm", tip.rows[3].sub);
    // Nothing alarming: the chip is Rust's, ink on coral, no pill.
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "accounts", .data = "*calm\nquiet\n" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "calm.json", .data = usage.usage_limits_only_fixture });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "quiet.json", .data = usage.usage_limits_only_fixture });
    try refreshAll(&app);
    try settle(&app);
    try t.expect((try claudeChipParts(&app, arena, "G")).tier == null);
}

test "This week by surface: under the week, a row per surface with its bar and percent, the time muted; none for an account that sends none; its rows hover and right-click as the account's" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "personal.json", .data = usage.usage_breakdown_fixture });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "work.json", .data = usage.usage_fixture });
    try fx.tmp.dir.deleteFile(t.io, "work.error");
    var app = try fx.app();
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"ai.claude_usage" });
    try settle(&app);
    try app.render();
    const txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    const title = "This week by surface · as of 7:55pm";
    const at = std.mem.indexOf(u8, txt, title) orelse return error.NoBreakdown;
    // Under personal's week, before the next account.
    try t.expect(at > std.mem.indexOf(u8, txt, "Current week (all models)").?);
    try t.expect(at < std.mem.indexOf(u8, txt, "work " ++ usage_view.pencil_glyph).?);
    // Once: `work` sends none.
    try t.expect(std.mem.indexOf(u8, txt[at + title.len ..], "This week by surface") == null);
    // Extra usage with every sub-field null: off, and nothing after it.
    const eu = std.mem.indexOf(u8, txt, "Extra usage: off") orelse return error.NoExtraUsage;
    const eol = std.mem.indexOfScalarPos(u8, txt, eu, '\n') orelse txt.len;
    try t.expect(std.mem.indexOf(u8, txt[eu..eol], "·") == null);
    const id = findPane(&app, .claude).?;
    const pal = &app.theme.palette;
    // Each surface: its name, a 20-cell bar filled to its share, `NN%`.
    const Want = struct { name: []const u8, pct: []const u8, filled: usize };
    for ([_]Want{ .{ .name = "Claude Code", .pct = "31%", .filled = 6 }, .{ .name = "Chat", .pct = "9%", .filled = 1 }, .{ .name = "Cowork", .pct = "5%", .filled = 1 }, .{ .name = "Other", .pct = "2%", .filled = 0 } }) |w| {
        var y: u16 = 0;
        const found = while (y < app.screen.height) : (y += 1) {
            var row: std.ArrayListUnmanaged(u8) = .empty;
            defer row.deinit(t.allocator);
            var filled: usize = 0;
            var empty: usize = 0;
            var x: u16 = 0;
            while (x < app.screen.width) : (x += 1) if (app.screen.readCell(x, y)) |c| {
                try row.appendSlice(t.allocator, c.char.grapheme);
                if (@import("vaxis").Color.eql(c.style.bg, pal.purple)) filled += 1;
                if (@import("vaxis").Color.eql(c.style.bg, pal.bg2)) empty += 1;
            };
            const trimmed = std.mem.trim(u8, row.items, " ▌|");
            if (!std.mem.startsWith(u8, trimmed, w.name) or !std.mem.endsWith(u8, trimmed, w.pct)) continue;
            try t.expectEqual(w.filled, filled);
            try t.expectEqual(@as(usize, usage_view.share_bar_w), filled + empty);
            break true;
        } else false;
        try t.expect(found);
    }
    // Its rows are the breakdown's hit: the hover names it, a
    // right-click is the account's menu.
    var rect: ?Rect = null;
    var others: usize = 0;
    for (app.hits.items.items) |h| if (h.target == .script_hit and h.target.script_hit.pane == id) {
        if (h.target.script_hit.id == hit_breakdown_base and rect == null) rect = h.rect;
        if (h.target.script_hit.id > hit_breakdown_base) others += 1;
    };
    try t.expectEqual(@as(usize, 0), others);
    const entry = (try @import("info_view_copy.zig").lookup(&app, app.frame.allocator(), .{ .script_hit = .{ .pane = id, .id = hit_breakdown_base } })).?;
    try t.expectEqualStrings("This week by surface — personal", entry.title);
    try app.handle(.{ .mouse = .{ .x = rect.?.x + 2, .y = rect.?.y, .kind = .press, .button = .right } });
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("personal", app.overlay.menu.title);
    try app.handle(.{ .key = Key.named(.esc) });
    // A left press on it renames nothing.
    try app.handle(.{ .mouse = .{ .x = rect.?.x + 2, .y = rect.?.y, .kind = .press, .button = .left } });
    try t.expect(app.overlay != .prompt);
}

/// Two accounts on the config with token files under the data root and
/// identity pins — `work` is w@example.com, `home` h@example.com — both
/// turned down by the endpoint (the fixture's 401).
fn reauthApp(f: *AccountsFixture) !App {
    try f.fx.tmp.dir.writeFile(t.io, .{ .sub_path = "data/ai_account_identity.json", .data = "{\"work\":\"w@example.com\",\"home\":\"h@example.com\"}" });
    try f.fx.tmp.dir.writeFile(t.io, .{ .sub_path = "work.error", .data = "HTTP 401: token rejected" });
    try f.fx.tmp.dir.writeFile(t.io, .{ .sub_path = "home.error", .data = "HTTP 401: token rejected" });
    var app = try f.app();
    errdefer app.deinit();
    app.cfg.ai.claude_accounts = &reauth_accounts;
    try refreshAll(&app);
    try settle(&app);
    return app;
}

const reauth_accounts = [_]app_mod.Config.ClaudeAccount{
    .{ .name = "work", .token_path = "ai_token.work", .active = true },
    .{ .name = "home", .token_path = "ai_token.home" },
};

fn exists(f: *AccountsFixture, rel: []const u8) bool {
    f.fx.tmp.dir.access(t.io, rel, .{}) catch return false;
    return true;
}

test "the silent re-capture: an expired account whose login the keychain holds is filed, once; another account's login is not" {
    var f = try AccountsFixture.init();
    defer f.fx.deinit();
    var app = try reauthApp(&f);
    defer app.deinit();
    try t.expectEqual(usage.AccountState.expired, usage.accountState(&st(&app).find("work").?.usage));
    try t.expectEqual(usage.AccountState.expired, usage.accountState(&st(&app).find("home").?.usage));
    const arena = app.frame.allocator();
    // The rule: the expired account pinned to the login's email.
    try t.expectEqualStrings("work", (try recaptureTarget(&app, arena, "w@example.com")).?);
    try t.expect((try recaptureTarget(&app, arena, "x@example.com")) == null);
    try t.expect((try recaptureTarget(&app, arena, null)) == null);
    // A login nobody on file has: nothing is written, nothing said.
    app.dismissToasts();
    try recaptureRead(&app, .{ .mode = .recapture, .blob = "fake-blob-x", .refresh_token = "rt-x", .email = "x@example.com" });
    try t.expect(!exists(&f, "data/ai_token.work") and !exists(&f, "data/ai_token.home"));
    try t.expect(app.lastToast() == null);
    try t.expectEqualStrings("rt-x", st(&app).recapture_seen.?);
    // work's login: filed under work, never home, with one toast.
    try recaptureRead(&app, .{ .mode = .recapture, .blob = "fake-blob-w", .refresh_token = "rt-w", .email = "w@example.com" });
    const tok = try f.read("data/ai_token.work");
    defer t.allocator.free(tok);
    try t.expectEqualStrings("fake-blob-w", tok);
    try t.expect(!exists(&f, "data/ai_token.home"));
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "signed work back in") != null);
    // The same login again: the file already holds it — no second toast.
    app.dismissToasts();
    try recaptureRead(&app, .{ .mode = .recapture, .blob = "fake-blob-w", .refresh_token = "rt-w", .email = "w@example.com" });
    try t.expect(app.lastToast() == null);
    try settle(&app);
}

test "Re-auth: the first read is the baseline; the login that lands is filed under the account and the watch ends" {
    var f = try AccountsFixture.init();
    defer f.fx.deinit();
    var app = try reauthApp(&f);
    defer app.deinit();
    st(&app).reauth = .{ .name = try app.gpa.dupe(u8, "work"), .pane = null };
    // Before the login: what the keychain held is the baseline, not a login.
    try reauthRead(&app, .{ .mode = .reauth, .blob = "fake-blob-old", .refresh_token = "rt-old" });
    try t.expect(st(&app).reauth.?.baseline_set);
    try t.expect(!exists(&f, "data/ai_token.work"));
    // Unchanged: still watching.
    try reauthRead(&app, .{ .mode = .reauth, .blob = "fake-blob-old", .refresh_token = "rt-old" });
    try t.expect(st(&app).reauth != null);
    // The login lands as work.
    try reauthRead(&app, .{ .mode = .reauth, .blob = "fake-blob-w", .refresh_token = "rt-w", .email = "w@example.com" });
    try t.expect(st(&app).reauth == null);
    const tok = try f.read("data/ai_token.work");
    defer t.allocator.free(tok);
    try t.expectEqualStrings("fake-blob-w", tok);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "signed work in") != null);
    try settle(&app);
}

test "Re-auth's mismatch guard: another account's login is offered to it, never filed under the one asked for; a stranger's is refused" {
    var f = try AccountsFixture.init();
    defer f.fx.deinit();
    var app = try reauthApp(&f);
    defer app.deinit();
    const arena = app.frame.allocator();
    try t.expectEqual(Verdict.capture, try reauthVerdict(&app, arena, "work", "w@example.com"));
    try t.expectEqualStrings("home", (try reauthVerdict(&app, arena, "work", "h@example.com")).other);
    try t.expectEqual(Verdict.unknown, try reauthVerdict(&app, arena, "work", "x@example.com"));
    try t.expectEqual(Verdict.unknown, try reauthVerdict(&app, arena, "work", null));
    // home's login lands on a Re-auth of work.
    st(&app).reauth = .{ .name = try app.gpa.dupe(u8, "work"), .pane = null, .baseline_set = true, .baseline = try app.gpa.dupe(u8, "rt-old") };
    try reauthRead(&app, .{ .mode = .reauth, .blob = "fake-blob-h", .refresh_token = "rt-h", .email = "h@example.com" });
    try t.expect(st(&app).reauth == null);
    try t.expect(!exists(&f, "data/ai_token.work") and !exists(&f, "data/ai_token.home"));
    try t.expect(app.overlay == .confirm);
    const fl = app.overlay.confirm.purpose.claude_file_login;
    try t.expectEqualStrings("home", fl.target);
    try t.expectEqualStrings("File under home", app.overlay.confirm.state.choices[0].label);
    try t.expectEqualStrings("Cancel", app.overlay.confirm.state.choices[1].label);
    try t.expect(std.mem.indexOf(u8, app.overlay.confirm.message, "not work") != null);
    // Cancel files nothing.
    try fileUnderAccept(&app, "home", 1);
    try t.expect(!st(&app).keychain_pending);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // File under home: the read that follows files it there, if it is still home's.
    try fileUnderRead(&app, .{ .mode = .file_under, .target = "home", .blob = "fake-blob-x", .email = "x@example.com" });
    try t.expect(!exists(&f, "data/ai_token.home"));
    try fileUnderRead(&app, .{ .mode = .file_under, .target = "home", .blob = "fake-blob-h", .email = "h@example.com" });
    const tok = try f.read("data/ai_token.home");
    defer t.allocator.free(tok);
    try t.expectEqualStrings("fake-blob-h", tok);
    try t.expect(!exists(&f, "data/ai_token.work"));
    // A stranger's login on a Re-auth of work: said, not filed, no box.
    st(&app).reauth = .{ .name = try app.gpa.dupe(u8, "work"), .pane = null, .baseline_set = true };
    try reauthRead(&app, .{ .mode = .reauth, .blob = "fake-blob-x", .refresh_token = "rt-x", .email = "x@example.com" });
    try t.expect(app.overlay != .confirm);
    try t.expect(!exists(&f, "data/ai_token.work"));
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "nothing was filed") != null);
    try settle(&app);
}
