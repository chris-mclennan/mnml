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

    pub fn title(p: *const UsagePane) []const u8 {
        return switch (p.product) {
            .claude => "Claude usage",
            .codex => "Codex usage",
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
const Sched = struct { name: []u8, last_at: u64 = 0, pending: bool = false };

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

    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.group.cancel(io);
        if (self.cfg_arena) |*a| a.deinit();
        for (self.accounts.items) |*a| a.arena.deinit();
        self.accounts.deinit(gpa);
        for (self.sched.items) |s| gpa.free(s.name);
        self.sched.deinit(gpa);
        if (self.codex_error) |e| gpa.free(e);
        if (self.keychain_rt) |k| gpa.free(k);
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
        try spawnKeychain(app, false);
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
    st(app).group.concurrent(app.io, claudeWorker, .{ &app.events, app.io, gpa, job }) catch return error.OutOfMemory;
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
    s.group.concurrent(app.io, codexWorker, .{ &app.events, app.io, gpa, job }) catch {
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

const KeychainJob = struct { capture: bool };

fn spawnKeychain(app: *App, capture: bool) Allocator.Error!void {
    const gpa = app.gpa;
    const s = st(app);
    const job = try gpa.create(KeychainJob);
    job.* = .{ .capture = capture };
    s.keychain_pending = true;
    s.group.concurrent(app.io, keychainWorker, .{ &app.events, app.io, gpa, job }) catch {
        s.keychain_pending = false;
        gpa.destroy(job);
        return error.OutOfMemory;
    };
}

fn keychainWorker(events: *event.EventQueue, io: Io, gpa: Allocator, job: *KeychainJob) Io.Cancelable!void {
    defer gpa.destroy(job);
    const r = usage.Result.create(gpa) catch return;
    errdefer r.destroy(gpa);
    const arena = r.arena.allocator();
    var k: usage.Keychain = .{ .capture = job.capture };
    if (usage.readKeychain(gpa, io, arena)) |blob| {
        k.blob = blob;
        k.refresh_token = usage.refreshTokenOf(arena, blob);
        if (job.capture) {
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
    } else k.err = "the keychain has no Claude Code login (run `claude login`)";
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
            if (s.schedFor(c.name)) |sched| sched.pending = false;
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
                    next.usage = try dupeUsage(fa, f.usage);
                    if (f.email) |e| next.email = try fa.dupe(u8, e);
                    if (f.org) |o| next.org = try fa.dupe(u8, o);
                    if (f.warning) |w| app.toast("{s}", .{w});
                },
                .err => |e| {
                    if (old) |o| {
                        next.usage = try dupeUsage(fa, o.usage);
                        if (o.email) |em| next.email = try fa.dupe(u8, em);
                        if (o.org) |og| next.org = try fa.dupe(u8, og);
                    }
                    usage.applyFetchError(&next.usage, .{ .message = try fa.dupe(u8, e.message), .retry_after = e.retry_after, .needs_reauth = e.needs_reauth }, now);
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
            if (k.capture) try captureLogin(app, k);
        },
    }
    app.needs_render = true;
}

fn dupeUsage(arena: Allocator, u: usage.Usage) Allocator.Error!usage.Usage {
    var out = u;
    const scoped = try arena.alloc(usage.Scoped, u.scoped.len);
    for (u.scoped, 0..) |sc, i| scoped[i] = .{ .model = try arena.dupe(u8, sc.model), .percent = sc.percent, .resets_at = sc.resets_at };
    out.scoped = scoped;
    if (u.last_error) |e| out.last_error = try arena.dupe(u8, e);
    return out;
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
    const tgt = target orelse return app.toast("the keychain login ({s}) matches no account on file — press L to log in as the one you want, then R", .{k.email orelse "unknown"});
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
    const literal = try config_persist.listLiteral(arena, elems, true, " " ** 12);
    _ = try settings.persistLiteral(app, .home, &.{ "ai", "claude_accounts" }, literal);
}

/// `ai.claude_add_account`, `a` in the Claude pane, the pane's and the
/// chip's menus: the name first, then the token prompt for it.
pub fn addCmd(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "Name the Claude account to add"), .purpose = .claude_account_add } };
    app.overlay.prompt.state.placeholder = "work, personal, a client's name…";
    app.focus = .overlay;
    app.needs_render = true;
}

/// The name prompt's accept: the account joins `ai.claude_accounts` in
/// the home config with a token file of its own under the data root —
/// the first one added is the active one — its fetch starts, and the
/// token prompt opens for it.
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
    try openTokenPrompt(app, name);
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
    ps.placeholder = "esc links it later: L logs in, R captures";
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
        app.toast("{s} is not linked yet — in the usage pane, L logs in as it and R captures the login", .{name});
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
        .link => "Link which Claude account?",
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
                        try spawnKeychain(app, true);
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
/// any account, a row of account `i`'s block, account `i`'s pencil.
pub const hit_kebab: u32 = 1;
pub const hit_body: u32 = 2;
pub const hit_account_base: u32 = 0x100;
pub const hit_pencil_base: u32 = 0x1000;

/// The account a block or pencil id names, in the order the pane lists them.
pub fn accountOfHit(app: *App, id: u32) ?[]const u8 {
    const base: u32 = if (id >= hit_pencil_base) hit_pencil_base else if (id >= hit_account_base) hit_account_base else return null;
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
        if (hit_id >= hit_pencil_base and !right) return toastFail(app, openRenamePrompt(app, name));
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

/// One account's menu, titled with its name: link a token to it, rename
/// it, remove it; then the pane's own rows.
pub fn openAccountMenu(app: *App, name: []const u8, x: u16, y: u16) Allocator.Error!void {
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const n = try mem.allocator().dupe(u8, name);
    const rows = try context_menus.items(app, &.{
        .{ .label = "Link a token…", .action = .{ .claude_account = .{ .act = .link, .name = n } } },
        .{ .label = "Rename…", .action = .{ .claude_account = .{ .act = .rename, .name = n } } },
        .{ .label = "Remove…", .action = .{ .claude_account = .{ .act = .remove, .name = n } } },
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
    for (s.accounts.items, 0..) |*a, i| views[i] = a.view();
    usage_view.draw(ui, id, area, p, .{
        .accounts = views,
        .codex = s.codex,
        .now = now,
        .tz = if (st(app).tz_override) |o| .{ .fixed = o } else .local,
        .loading = s.anyPending(),
    }, app.active == id and app.focus == .pane);
}

// ─── the chip ───────────────────────────────────────────────────────────

pub const ClaudeChip = struct { text: []const u8 };

/// The statusline's Claude chip: one account (`ai.chip_show_*` picks
/// the detail, `ai.chip_toggle_reset` the countdown), or every account
/// as `claude_meter_mode` says — compact (the sparkline) or ticker
/// (one at a time, 4 s each, its letter first). One account configured
/// is always the single chip.
pub fn claudeChip(app: *App, arena: Allocator, glyph: []const u8) Allocator.Error![]const u8 {
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
            return (try usage.compactChip(arena, rows, opts)).text;
        },
        .ticker => {
            const a = &s.accounts.items[usage.tickerIndex(now, n)];
            return usage.singleChip(arena, &a.usage, usage.abbrev(a.name), opts);
        },
        .off => {
            const a = s.active() orelse return std.fmt.allocPrint(arena, " {s} … ", .{glyph});
            return usage.singleChip(arena, &a.usage, null, opts);
        },
    }
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
    if (u.needs_reauth) return "not logged in";
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

test "the pane's states: fetching, not linked, needs re-auth with the guided steps" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "accounts", .data = "ghost\n*locked\n" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "locked.error", .data = "needs-reauth: the keychain login is other@example.com, not locked's" });
    var app = try fx.app();
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"ai.claude_usage" });
    // Before any result: the empty state.
    try app.render();
    var txt = try screen_mod.toTestText(t.allocator, &app.screen);
    try t.expect(std.mem.indexOf(u8, txt, "fetching… (link a token via `:ai.link_claude_token`)") != null);
    t.allocator.free(txt);
    try settle(&app);
    try app.render();
    txt = try screen_mod.toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "no data yet · last error: not linked") != null);
    // Backed off on our side, not the server's: no 429 wording.
    try t.expect(std.mem.indexOf(u8, txt, "next fetch in 600s") != null);
    try t.expect(std.mem.indexOf(u8, txt, "(429)") == null);
    try t.expect(std.mem.indexOf(u8, txt, "token expired — needs re-auth") != null);
    try t.expect(std.mem.indexOf(u8, txt, "1. press L to run `claude login` (as locked)") != null);
    try t.expect(std.mem.indexOf(u8, txt, "2. press R to capture it from the keychain") != null);
    try t.expect(std.mem.indexOf(u8, txt, "the keychain login is other@example.com") != null);
    try t.expect(std.mem.indexOf(u8, txt, "(active) locked") != null);
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
    try t.expectEqualStrings(" G ▇! →P ", try claudeChip(&app, arena, "G"));
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
    try t.expectEqualStrings("/data/ai_token.personal", cfg[0].token_path);
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

test "ai.claude_add_account: a name, then its token — the account joins the home config beside the default with a token file of its own (0600), and is fetched" {
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
