//! AI (Phase 7): ghost text as you type, the one-shot and agentic jobs
//! behind `Pane.ai`, Claude Code / Codex as pty panes, and every `ai.*`
//! runner. The dashboard is `agents.zig`, the spend report `spend.zig`.
//!
//!   D1  every worker owns its argument strings and frees them; a result
//!       is posted as an owned `AiMsg` the handler adopts or frees;
//!   D3  one `Io.Group` for every AI worker; the ghost text is cancelled
//!       by generation (a result for an older buffer is dropped), a job
//!       by its atomic flag between turns; the confirm channel is the
//!       job's own `Io.Queue(bool)` — the worker parks on `getOne`, the
//!       confirm box answers with `putOne` (the D3 reverse channel);
//!   D2  workers never toast — they post `.err` / `.failed`.
//!
//! Local FIM is API-only in this release: `suggest_backend = "local"`
//! toasts the migration note once and sends nothing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const Key = app_mod.Key;
const Config = app_mod.Config;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const suggest = @import("../ai/suggest.zig");
const api = @import("../ai/api_client.zig");
const cli = @import("../ai/cli.zig");
const pty_pane = @import("pty_pane.zig");
const cmd_picker = @import("cmd_picker.zig");
const cmd_view = @import("cmd_view.zig");
const settings = @import("settings.zig");
const agents = @import("agents.zig");
const spend = @import("spend.zig");
const transcript = @import("../ai/transcript.zig");
const ai_apply = @import("ai_apply.zig");
const launch_profiles = @import("launch_profiles.zig");

pub const table = .{
    .@"ai.ask" = &askCmd,
    .@"ai.explain" = &explainCmd,
    .@"ai.fix" = &fixCmd,
    .@"ai.refactor" = &refactorCmd,
    .@"ai.write_tests" = &writeTestsCmd,
    .@"ai.reask" = &reaskCmd,
    .@"ai.cancel" = &cancelCmd,
    .@"ai.promote" = &promoteCmd,
    .@"ai.apply" = &applyCmd,
    .@"ai.session_view" = &sessionViewCmd,
    .@"ai.chat" = &chatCmd,
    .@"ai.claude_code" = &claudeCode,
    .@"ai.claude_code_focus" = &claudeCodeFocus,
    .@"ai.claude_code_new" = &claudeCodeNew,
    .@"ai.claude_code_new_x2" = &claudeCodeNewX2,
    .@"ai.claude_code_new_x4" = &claudeCodeNewX4,
    .@"ai.claude_code_new_x8" = &claudeCodeNewX8,
    .@"ai.claude_code_new_left" = &claudeCodeNewLeft,
    .@"ai.claude_code_new_right" = &claudeCodeNewRight,
    .@"ai.claude_code_new_top" = &claudeCodeNewTop,
    .@"ai.claude_code_new_bottom" = &claudeCodeNewBottom,
    .@"ai.codex" = &codex,
    .@"ai.codex_new" = &codexNew,
    .@"ai.codex_new_left" = &codexNewLeft,
    .@"ai.codex_new_right" = &codexNewRight,
    .@"ai.codex_new_top" = &codexNewTop,
    .@"ai.codex_new_bottom" = &codexNewBottom,
    .@"ai.session_picker" = &sessionPicker,
    .@"ai.session_search" = &sessionSearchCmd,
    .@"ai.toggle_backend" = &toggleBackend,
    .@"ai.toggle_inline_suggestions" = &toggleInline,
    .@"ai.setup_suggestions" = &setupSuggestions,
    .@"ai.suggestion_stats" = &suggestionStats,
    .@"ai.show_config" = &showConfig,
    .@"ai.token_usage" = &tokenUsage,
    .@"ai.canary" = &canary,
    .@"ai.write_pr_description" = &writePrDescription,
    .@"ai.write_branch_name" = &writeBranchName,
    .@"ai.recompose_branch" = &recomposeBranch,
    .@"ai.explain_diff" = &explainDiff,
    .@"ai.link_claude_token" = &linkClaudeToken,
    .@"ai.claude_usage" = &claudeUsage,
    .@"ai.claude_rename_account" = &notInBuildCmd,
    .@"ai.codex_usage" = &codexUsage,
    .@"ai.show_last_response" = &showLastResponse,
    .@"ai.refresh_usage" = &refreshUsage,
    .@"ai.chip_show_session" = &chipShowSession,
    .@"ai.chip_show_weekly" = &chipShowWeekly,
    .@"ai.chip_show_both" = &chipShowBoth,
    .@"ai.chip_toggle_reset" = &chipToggleReset,
    .@"ai.chip_show_all_accounts" = &chipCycleAccounts,
    .@"ai.chip_show_all_off" = &chipAllOff,
    .@"ai.chip_show_all_compact" = &chipAllCompact,
    .@"ai.chip_show_all_ticker" = &chipAllTicker,
    .@"cloud_agents.refresh" = &cloudNotInBuild,
    .@"cloud_agents.new_run" = &cloudNotInBuild,
    .@"cloud_agents.new_run_wizard" = &cloudNotInBuild,
    .@"cloud_agents.refresh_run_detail" = &cloudNotInBuild,
    .@"cloud_agents.focus_quick_input" = &cloudNotInBuild,
    .@"cloud_agents.spawn_worker" = &cloudNotInBuild,
    .@"cloud_agents.webhook_docs" = &cloudNotInBuild,
    .@"cloud_agents.toggle_view" = &cloudToggleView,
    .@"cloud_agents.view_compact" = &cloudViewCompact,
    .@"cloud_agents.view_standard" = &cloudViewStandard,
};

/// How many API turns an agentic job may take before it is stopped.
pub const max_turns: usize = 12;
/// What a read tool hands the model at most.
pub const tool_read_cap: usize = 256 * 1024;

// ─── state ──────────────────────────────────────────────────────────────

/// One job: an ask, an action, a git prompt. Heap-allocated so the
/// worker's pointer and the queue's ring stay put; freed at deinit.
pub const Job = struct {
    id: u64,
    /// The D3 reverse channel. One slot: the worker asks, the UI answers.
    confirm: Io.Queue(bool),
    confirm_buf: [1]bool = undefined,
    cancel: std.atomic.Value(bool) = .init(false),
    /// The worker has posted its last message.
    finished: bool = false,
    /// A confirm box is open for this job; `answerConfirm` closes it.
    awaiting_confirm: bool = false,
};

/// The statusline meter's numbers (`ai.refresh_usage`).
pub const Meter = struct { tokens: u64, cost_usd: f64, sessions: usize, at_ms: i64 };

pub const ChipDetail = enum { session, weekly, both };

pub const State = struct {
    group: Io.Group = .init,
    jobs: std.ArrayListUnmanaged(*Job) = .empty,
    next_job: u64 = 1,
    debounce: suggest.Debounce = .{},
    /// The pane whose suggestion is in flight.
    suggest_pane: ?PaneId = null,
    /// A runtime pick from the setup picker; wins over the config.
    backend_override: ?suggest.Backend = null,
    hint_shown: bool = false,
    local_note_shown: bool = false,
    key_missing_toasted: bool = false,
    shown: u32 = 0,
    accepted: u32 = 0,
    current_accepted: bool = false,
    last_context_hash: ?u64 = null,
    meter: ?Meter = null,
    meter_generation: u32 = 0,
    chip_detail: ChipDetail = .both,
    chip_reset_suffix: bool = false,
    /// A default profile name set this session (`launch_profiles.setDefault`);
    /// the config borrows it until the next load.
    owned_default: ?[]u8 = null,
    cloud_compact: bool = false,
    /// The workers posting `.spend` for the meter (no pane).
    spend_group: Io.Group = .init,

    /// Cancels every worker and waits: they borrow `app.env`,
    /// `app.workspace` and post into `app.events`.
    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.group.cancel(io);
        self.spend_group.cancel(io);
        for (self.jobs.items) |j| gpa.destroy(j);
        self.jobs.deinit(gpa);
        if (self.owned_default) |d| gpa.free(d);
    }

    pub fn job(self: *State, id: u64) ?*Job {
        for (self.jobs.items) |j| if (j.id == id) return j;
        return null;
    }
};

/// `Pane.ai`: a prompt and its answer, streamed in by a job.
pub const AiPane = struct {
    pub const Status = enum { running, done, failed };
    pub const Kind = enum { ask, action, chat, git };
    pub const ApplyTarget = struct { pane: PaneId, start: usize, end: usize };

    gpa: Allocator,
    /// Owned; the tab label.
    title: []u8,
    prompt: []u8,
    answer: std.ArrayListUnmanaged(u8) = .empty,
    status: Status = .running,
    err: ?[]u8 = null,
    job: u64,
    kind: Kind,
    scroll: usize = 0,
    session_id: [36]u8,
    /// The `claude -p` session exists to resume (CLI backends only).
    has_session: bool = false,
    /// What `ai.apply` replaces.
    apply: ?ApplyTarget = null,

    pub fn deinit(self: *AiPane) void {
        self.gpa.free(self.title);
        self.gpa.free(self.prompt);
        self.answer.deinit(self.gpa);
        if (self.err) |e| self.gpa.free(e);
    }

    pub fn statusLabel(self: *const AiPane) []const u8 {
        return switch (self.status) {
            .running => "thinking…",
            .done => "done",
            .failed => "failed",
        };
    }
};

// ─── the backend the config names ───────────────────────────────────────

pub const Route = enum { cli, api, off };

/// `[ai.routing.<product>].backend`, falling back to the legacy
/// `[ai].backend`: `auto` is the CLI when the binary exists, the API
/// when a key is set, else the CLI (its own error is the clearest).
pub fn route(app: *App, product: enum { claude, codex }) Route {
    const cfg = &app.cfg.ai;
    const chosen: ?Config.AiBackend = switch (product) {
        .claude => cfg.routing.claude.backend orelse cfg.backend,
        .codex => cfg.routing.codex.backend,
    };
    return switch (chosen orelse .auto) {
        .sub => .cli,
        .api => .api,
        .off => .off,
        .auto => if (product == .claude and app.env.get(api.env_key) != null and !binaryOnPath(app, cli.claude_binary)) .api else .cli,
    };
}

fn binaryOnPath(app: *App, name: []const u8) bool {
    const path = app.env.get("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path, ':');
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len == 0 or dir.len + 1 + name.len >= buf.len) continue;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        Io.Dir.cwd().access(app.io, full, .{}) catch continue;
        return true;
    }
    return false;
}

/// `[ai] suggest_backend`, or the runtime pick from the setup picker.
pub fn suggestBackend(app: *App) suggest.Backend {
    if (app.ai.backend_override) |b| return b;
    if (app.cfg.ai.extra.get("suggest_backend")) |v| switch (v) {
        .string, .enum_literal => |s| return suggest.Backend.parse(s),
        else => {},
    };
    return .unset;
}

fn extraString(app: *App, key: []const u8) ?[]const u8 {
    const v = app.cfg.ai.extra.get(key) orelse return null;
    return switch (v) {
        .string, .enum_literal => |s| s,
        else => null,
    };
}

fn extraBool(app: *App, key: []const u8) ?bool {
    const v = app.cfg.ai.extra.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

// ─── ghost text ─────────────────────────────────────────────────────────

/// A typed edit landed: the debounce clock restarts and whatever was
/// in flight answers a buffer that no longer exists.
pub fn noteEdit(app: *App) void {
    app.ai.debounce.noteEdit(app.now_ms);
}

/// Keys while a ghost is showing: Tab takes it, ctrl+→ a word,
/// ctrl+↓ a line; any other key dismisses it and goes on. Returns
/// true when the key was consumed.
pub fn interceptKey(app: *App, e: *EditorPane, k: Key) Allocator.Error!bool {
    const ghost = e.buf.editor.ghost_suggestion orelse return false;
    const plain = !k.mods.ctrl and !k.mods.alt and !k.mods.super and !k.mods.shift;
    const ctrl_only = k.mods.ctrl and !k.mods.alt and !k.mods.super and !k.mods.shift;
    if (k.code == .tab and plain) return acceptGhost(app, e, ghost.len);
    if (k.code == .right and ctrl_only) return acceptGhost(app, e, suggest.wordBoundary(ghost));
    if (k.code == .down and ctrl_only) return acceptGhost(app, e, suggest.lineBoundary(ghost));
    try e.buf.editor.setGhostSuggestion(null);
    app.needs_render = true;
    return false;
}

/// Insert the first `take` bytes at the cursor; the rest stays a ghost.
fn acceptGhost(app: *App, e: *EditorPane, take_in: usize) Allocator.Error!bool {
    const ghost = e.buf.editor.ghost_suggestion orelse return false;
    const take = @min(take_in, ghost.len);
    if (take == 0) return false;
    const arena = app.frame.allocator();
    const accepted = try arena.dupe(u8, ghost[0..take]);
    const remaining = try arena.dupe(u8, ghost[take..]);
    const at = e.buf.editor.cursor;
    try app.splice(e, at, at, accepted);
    try e.buf.editor.setGhostSuggestion(if (remaining.len > 0) remaining else null);
    // One suggestion counts once, however many partial accepts it took;
    // a fully consumed one lets the next count again.
    if (!app.ai.current_accepted) {
        app.ai.current_accepted = true;
        app.ai.accepted +|= 1;
    }
    if (remaining.len == 0) app.ai.current_accepted = false;
    // The accept is an edit the clock must not answer with another
    // request while the rest is still showing.
    app.ai.debounce.cancel();
    app.needs_render = true;
    return true;
}

/// Every tick: fire the request once the clock is due.
pub fn tick(app: *App) Allocator.Error!void {
    if (app.ai.debounce.due(app.now_ms)) try fireSuggestion(app);
    try agents.tickAll(app);
}

pub fn nextDeadlineMs(app: *const App) ?i64 {
    var next: ?i64 = app.ai.debounce.deadline();
    if (agents.nextDeadlineMs(app)) |d| next = @min(next orelse std.math.maxInt(i64), d);
    if (spend.anyLoading(app)) next = @min(next orelse std.math.maxInt(i64), app.now_ms + 120);
    return next;
}

fn fireSuggestion(app: *App) Allocator.Error!void {
    const st = &app.ai;
    if (!app.cfg.ai.inline_suggestions) return st.debounce.cancel();
    const id = app.active orelse return st.debounce.cancel();
    const e = app.panes.editor(id) orelse return st.debounce.cancel();
    if (e.buf.editor.ghost_suggestion != null) return st.debounce.cancel();
    const backend = suggestBackend(app);
    switch (backend) {
        .unset => {
            try maybeShowHint(app);
            return st.debounce.cancel();
        },
        .local => {
            if (!st.local_note_shown) {
                st.local_note_shown = true;
                app.toast("{s}", .{suggest.migration_note});
            }
            return st.debounce.cancel();
        },
        .claude_code, .claude_api => {},
    }
    if (e.buf.doc.path) |p| if (suggest.isSecretBearing(p)) return st.debounce.cancel();
    const ctx = suggest.context(e.buf.editor.bytes(), e.buf.editor.cursor);
    if (ctx.prefix.len == 0 and ctx.suffix.len == 0) return st.debounce.cancel();
    var h = std.hash.Wyhash.init(0);
    h.update(ctx.prefix);
    h.update("\x00");
    h.update(ctx.suffix);
    const hash = h.final();
    if (st.last_context_hash == hash) return st.debounce.cancel();
    const key: []const u8 = if (backend == .claude_api) (app.env.get(api.env_key) orelse {
        if (!st.key_missing_toasted) {
            st.key_missing_toasted = true;
            app.toast("AI ghost-text: ${s} not set — pick Claude Code in ai.setup_suggestions or export the key", .{api.env_key});
        }
        return st.debounce.cancel();
    }) else "";
    st.last_context_hash = hash;
    const gpa = app.gpa;
    const lang = suggest.languageOf(e.buf.doc.path);
    const user = try suggest.userPrompt(app.frame.allocator(), lang, ctx);
    const prompt = if (backend == .claude_code) try std.mem.concat(gpa, u8, &.{ suggest.system_prompt, "\n\n", user }) else try gpa.dupe(u8, user);
    errdefer gpa.free(prompt);
    const model = try gpa.dupe(u8, extraString(app, "suggest_model") orelse suggest.default_model);
    errdefer gpa.free(model);
    const key_owned = try gpa.dupe(u8, key);
    errdefer gpa.free(key_owned);
    const cwd = try gpa.dupe(u8, app.workspace);
    errdefer gpa.free(cwd);
    const generation = st.debounce.fire();
    st.suggest_pane = id;
    st.current_accepted = false;
    st.group.concurrent(app.io, suggestWorker, .{ &app.events, app.io, gpa, @as(u32, id), generation, backend, prompt, model, key_owned, cwd, &app.env }) catch {
        st.debounce.cancel();
        return error.OutOfMemory;
    };
}

/// One-time nudge that the feature exists, for a machine that has not
/// set it up. Per machine: a marker under the home config dir. Never
/// in the `.test` runner (no home there), so no toast lands in a
/// script that did not ask for one.
fn maybeShowHint(app: *App) Allocator.Error!void {
    const st = &app.ai;
    if (st.hint_shown) return;
    st.hint_shown = true;
    const home = app.homeDir() orelse return;
    const arena = app.frame.allocator();
    const dir = try std.fs.path.join(arena, &.{ home, ".config", "mnml" });
    const marker = try std.fs.path.join(arena, &.{ dir, "ghost-text-hint-shown" });
    if (Io.Dir.cwd().access(app.io, marker, .{})) |_| return else |_| {}
    Io.Dir.cwd().createDirPath(app.io, dir) catch {};
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = marker, .data = "" }) catch {};
    try app.toastPersistent(suggest.hint_toast_id, suggest.setup_hint, .info);
}

/// The ghost-text worker. Owns every string it was handed.
fn suggestWorker(events: *event.EventQueue, io: Io, gpa: Allocator, pane: u32, generation: u32, backend: suggest.Backend, prompt: []u8, model: []u8, key: []u8, cwd: []u8, env: *const std.process.Environ.Map) Io.Cancelable!void {
    defer gpa.free(prompt);
    defer gpa.free(model);
    defer gpa.free(key);
    defer gpa.free(cwd);
    var raw: []u8 = undefined;
    switch (backend) {
        .claude_api => {
            const body = api.completionRequest(gpa, model, suggest.system_prompt, prompt, suggest.max_tokens) catch return;
            defer gpa.free(body);
            const res = api.post(gpa, io, api.endpoint, key, body) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    postErr(events, io, gpa, "ghost-text: the request failed");
                    return;
                },
            };
            defer gpa.free(res.body);
            if (res.status != 200) {
                var scratch = std.heap.ArenaAllocator.init(gpa);
                defer scratch.deinit();
                const why = api.errorMessage(scratch.allocator(), res.body) orelse "";
                const msg = std.fmt.allocPrint(gpa, "ghost-text: HTTP {d} {s}", .{ res.status, why }) catch return;
                defer gpa.free(msg);
                postErr(events, io, gpa, msg);
                return;
            }
            var reply = api.parseReply(gpa, res.body) catch return;
            defer reply.deinit();
            raw = gpa.dupe(u8, reply.text) catch return;
        },
        .claude_code => {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const argv = cli.claudeArgv(arena.allocator(), prompt, null, null) catch return;
            const out = cli.run(gpa, io, argv, cwd, env) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    postErr(events, io, gpa, "ghost-text: `claude` could not be run — is it installed and signed in?");
                    return;
                },
            };
            if (!out.ok) {
                defer gpa.free(out.text);
                const msg = std.fmt.allocPrint(gpa, "ghost-text: claude -p: {s}", .{out.text}) catch return;
                defer gpa.free(msg);
                postErr(events, io, gpa, msg);
                return;
            }
            raw = out.text;
        },
        .unset, .local => return,
    }
    defer gpa.free(raw);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const clean = suggest.cleanCompletion(arena.allocator(), raw) catch return;
    const owned = gpa.dupe(u8, clean) catch return;
    events.post(io, .{ .ai = .{ .job = 0, .msg = .{ .suggestion = .{ .pane = pane, .generation = generation, .text = owned } } } });
}

fn postErr(events: *event.EventQueue, io: Io, gpa: Allocator, msg: []const u8) void {
    const owned = gpa.dupe(u8, msg) catch return;
    events.post(io, .{ .err = .{ .source = .ai, .msg = owned } });
}

// ─── the event handler (D1) ─────────────────────────────────────────────

/// `msg` is ours to adopt or free, on every path.
pub fn handle(app: *App, job_id: u64, msg: event.AiMsg) Allocator.Error!void {
    const gpa = app.gpa;
    switch (msg) {
        .suggestion => |s| {
            defer gpa.free(s.text);
            const st = &app.ai;
            if (!st.debounce.settle(s.generation)) return;
            if (st.suggest_pane != @as(PaneId, s.pane)) return;
            const e = app.panes.editor(s.pane) orelse return;
            if (s.text.len == 0) return;
            try e.buf.editor.setGhostSuggestion(s.text);
            st.shown +|= 1;
            st.current_accepted = false;
            app.needs_render = true;
        },
        .text => |text| {
            defer gpa.free(text);
            const p = paneOfJob(app, job_id) orelse return;
            try p.answer.appendSlice(gpa, text);
            app.needs_render = true;
        },
        .done => {
            if (app.ai.job(job_id)) |j| j.finished = true;
            const p = paneOfJob(app, job_id) orelse return;
            if (p.status == .running) p.status = .done;
            app.needs_render = true;
        },
        .failed => |why| {
            if (app.ai.job(job_id)) |j| j.finished = true;
            const p = paneOfJob(app, job_id) orelse {
                gpa.free(why);
                return;
            };
            if (p.err) |old| gpa.free(old);
            p.err = why; // adopted
            p.status = .failed;
            app.needs_render = true;
        },
        .confirm => |detail| {
            const j = app.ai.job(job_id) orelse {
                gpa.free(detail);
                return;
            };
            // The message is adopted by the overlay; a job that cannot be
            // asked (its pane is gone) is told no.
            if (paneOfJob(app, job_id) == null) {
                gpa.free(detail);
                j.confirm.putOne(app.io, false) catch {};
                return;
            }
            j.awaiting_confirm = true;
            app.overlay.deinit(gpa);
            app.overlay = .{ .confirm = .{
                .state = .{ .title = "AI wants to write a file", .message = detail, .choices = &write_choices },
                .purpose = .{ .ai_tool = job_id },
                .message = detail,
            } };
            app.focus = .overlay;
            app.needs_render = true;
        },
    }
}

pub const write_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'a', .label = "Allow" }, .{ .key = 'd', .label = "Deny" } };

/// The confirm box closed: `yes` goes down the job's queue. Idempotent —
/// a box dismissed by a click outside answers no through here too.
pub fn answerConfirm(app: *App, job_id: u64, yes: bool) void {
    const j = app.ai.job(job_id) orelse return;
    if (!j.awaiting_confirm) return;
    j.awaiting_confirm = false;
    j.confirm.putOne(app.io, yes) catch {};
}

/// Called by the dispatcher before any overlay closes: a confirm that
/// belongs to a job must not leave its worker parked.
pub fn overlayClosing(app: *App) void {
    switch (app.overlay) {
        .confirm => |c| switch (c.purpose) {
            .ai_tool => |id| answerConfirm(app, id, false),
            else => {},
        },
        else => {},
    }
}

fn paneOfJob(app: *App, job_id: u64) ?*AiPane {
    if (job_id == 0) return null;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .ai => |*a| if (a.job == job_id) return a,
        else => {},
    };
    return null;
}

fn paneIdOfJob(app: *App, job_id: u64) ?PaneId {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .ai => |*a| if (a.job == job_id) return @intCast(i),
        else => {},
    };
    return null;
}

// ─── jobs ───────────────────────────────────────────────────────────────

const JobMode = enum { claude_cli, codex_cli, claude_api };

/// Start a job and its pane. `prompt` is borrowed and copied.
pub fn ask(app: *App, title: []const u8, prompt: []const u8, kind: AiPane.Kind, apply: ?AiPane.ApplyTarget) CommandError!PaneId {
    return askProduct(app, .claude, title, prompt, kind, apply);
}

// ── git ──────────────────────────────────────────────────────────────────
// The git track's hook: the same job as `ask`, on either product. Codex
// has no API backend, so its `api` route is refused here; `git.zig`
// watches the pane and takes the answer when it says done.
pub fn askProduct(app: *App, product: Product, title: []const u8, prompt: []const u8, kind: AiPane.Kind, apply: ?AiPane.ApplyTarget) CommandError!PaneId {
    const gpa = app.gpa;
    const mode: JobMode = switch (product) {
        .claude => switch (route(app, .claude)) {
            .cli => .claude_cli,
            .api => .claude_api,
            .off => return app.diag.fail(app.frame.allocator(), "AI is routed off ([ai.routing.claude] backend = \"off\")", .{}),
        },
        .codex => switch (route(app, .codex)) {
            .cli => .codex_cli,
            .api => return app.diag.fail(app.frame.allocator(), "Codex has no API backend in this build ([ai.routing.codex] backend = \"api\")", .{}),
            .off => return app.diag.fail(app.frame.allocator(), "AI is routed off ([ai.routing.codex] backend = \"off\")", .{}),
        },
    };
    const key: []const u8 = if (mode == .claude_api) (app.env.get(api.env_key) orelse return app.diag.fail(app.frame.allocator(), "AI: ${s} not set (the API backend needs it)", .{api.env_key})) else "";
    const j = try gpa.create(Job);
    errdefer gpa.destroy(j);
    j.* = .{ .id = app.ai.next_job, .confirm = undefined };
    j.confirm = .init(&j.confirm_buf);
    app.ai.next_job += 1;
    try app.ai.jobs.append(gpa, j);
    errdefer _ = app.ai.jobs.pop();

    var pane: AiPane = .{
        .gpa = gpa,
        .title = try gpa.dupe(u8, title),
        .prompt = undefined,
        .job = j.id,
        .kind = kind,
        .session_id = cli.genSessionId(app.io),
        .has_session = mode == .claude_cli,
        .apply = apply,
    };
    errdefer gpa.free(pane.title);
    pane.prompt = try gpa.dupe(u8, prompt);
    errdefer gpa.free(pane.prompt);

    const prompt_owned = try gpa.dupe(u8, prompt);
    errdefer gpa.free(prompt_owned);
    const model = try gpa.dupe(u8, extraString(app, "model") orelse api.default_model);
    errdefer gpa.free(model);
    const key_owned = try gpa.dupe(u8, key);
    errdefer gpa.free(key_owned);
    const cwd = try gpa.dupe(u8, app.workspace);
    errdefer gpa.free(cwd);
    const system: ?[]u8 = if (extraString(app, "system_prompt")) |s| try gpa.dupe(u8, s) else null;
    errdefer if (system) |s| gpa.free(s);
    const write_tools = extraBool(app, "api_write_tools") orelse false;
    const use_tools = extraBool(app, "api_tools") orelse true;
    const max_tokens: u32 = blk: {
        const v = app.cfg.ai.extra.get("max_tokens") orelse break :blk api.default_max_tokens;
        break :blk switch (v) {
            .int => |i| if (i > 0 and i < 200_000) @intCast(i) else api.default_max_tokens,
            else => api.default_max_tokens,
        };
    };

    const id = try app.panes.add(.{ .ai = pane });
    // Owned by the store from here.
    app.ai.group.concurrent(app.io, jobWorker, .{ &app.events, app.io, gpa, j, mode, prompt_owned, pane.session_id, model, key_owned, cwd, &app.env, system, use_tools, write_tools, max_tokens }) catch {
        app.panes.remove(id);
        return error.OutOfMemory;
    };
    // The answer opens beside the editor it came from.
    const layout = app.layouts.current();
    if (app.active) |cur| if (layout.leafOf(cur) != null) {
        _ = layout.split(cur, .horizontal, id) catch {};
        app.setActive(id);
        return id;
    };
    app.showPane(id);
    return id;
}
// ── end git ──────────────────────────────────────────────────────────────

/// The job worker: one `claude -p` / `codex exec`, or the agent loop
/// over the API. Owns every string it was handed.
fn jobWorker(events: *event.EventQueue, io: Io, gpa: Allocator, j: *Job, mode: JobMode, prompt: []u8, session_id: [36]u8, model: []u8, key: []u8, cwd: []u8, env: *const std.process.Environ.Map, system: ?[]u8, use_tools: bool, write_tools: bool, max_tokens: u32) Io.Cancelable!void {
    defer gpa.free(prompt);
    defer gpa.free(model);
    defer gpa.free(key);
    defer gpa.free(cwd);
    defer if (system) |s| gpa.free(s);
    switch (mode) {
        .claude_cli, .codex_cli => {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const argv = (if (mode == .claude_cli) cli.claudeArgv(arena.allocator(), prompt, &session_id, extraModel(model)) else cli.codexArgv(arena.allocator(), prompt)) catch return;
            const out = cli.run(gpa, io, argv, cwd, env) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    postFailed(events, io, gpa, j.id, if (mode == .claude_cli) "`claude` could not be run — is it installed and signed in?" else "`codex` could not be run — is it installed?");
                    return;
                },
            };
            if (!out.ok) {
                events.post(io, .{ .ai = .{ .job = j.id, .msg = .{ .failed = out.text } } });
                return;
            }
            events.post(io, .{ .ai = .{ .job = j.id, .msg = .{ .text = out.text } } });
            events.post(io, .{ .ai = .{ .job = j.id, .msg = .done } });
        },
        .claude_api => try agentLoop(events, io, gpa, j, prompt, model, key, cwd, system, use_tools, write_tools, max_tokens),
    }
}

/// `[ai] model` is for the API; the CLI takes it only when it looks
/// like a Claude Code alias or a full model id.
fn extraModel(model: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, model, api.default_model)) return null;
    return model;
}

fn postFailed(events: *event.EventQueue, io: Io, gpa: Allocator, job_id: u64, msg: []const u8) void {
    const owned = gpa.dupe(u8, msg) catch return;
    events.post(io, .{ .ai = .{ .job = job_id, .msg = .{ .failed = owned } } });
}

/// request → (tool calls) → request until the model stops. Text of
/// every turn is posted as it lands; a write waits on the confirm.
fn agentLoop(events: *event.EventQueue, io: Io, gpa: Allocator, j: *Job, prompt: []const u8, model: []const u8, key: []const u8, cwd: []const u8, system: ?[]const u8, use_tools: bool, write_tools: bool, max_tokens: u32) Io.Cancelable!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sys = api.agentSystemPrompt(arena, system, write_tools) catch return;
    var messages: std.ArrayListUnmanaged(api.Message) = .empty;
    messages.append(arena, .{ .role = "user", .blocks = arena.dupe(api.Block, &.{.{ .text = prompt }}) catch return }) catch return;
    var turn: usize = 0;
    while (turn < max_turns) : (turn += 1) {
        if (j.cancel.load(.acquire)) {
            postFailed(events, io, gpa, j.id, "cancelled");
            return;
        }
        try io.checkCancel();
        const body = api.encodeRequest(gpa, .{
            .model = model,
            .max_tokens = max_tokens,
            .system = sys,
            .messages = messages.items,
            .tools = if (!use_tools) .none else if (write_tools) .with_write else .read_only,
        }) catch return;
        defer gpa.free(body);
        const res = api.post(gpa, io, api.endpoint, key, body) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                postFailed(events, io, gpa, j.id, "the request failed (network / TLS)");
                return;
            },
        };
        defer gpa.free(res.body);
        if (res.status != 200) {
            const why = api.errorMessage(arena, res.body) orelse "";
            const msg = std.fmt.allocPrint(gpa, "HTTP {d} {s}", .{ res.status, why }) catch return;
            events.post(io, .{ .ai = .{ .job = j.id, .msg = .{ .failed = msg } } });
            return;
        }
        var reply = api.parseReply(gpa, res.body) catch {
            postFailed(events, io, gpa, j.id, "the reply was not a message");
            return;
        };
        defer reply.deinit();
        if (reply.text.len > 0) {
            const chunk = std.mem.concat(gpa, u8, &.{ reply.text, "\n" }) catch return;
            events.post(io, .{ .ai = .{ .job = j.id, .msg = .{ .text = chunk } } });
        }
        if (reply.tool_uses.len == 0 or !std.mem.eql(u8, reply.stop_reason, "tool_use")) break;
        // The assistant turn, then our results, both on the loop arena.
        var assistant: std.ArrayListUnmanaged(api.Block) = .empty;
        if (reply.text.len > 0) assistant.append(arena, .{ .text = arena.dupe(u8, reply.text) catch return }) catch return;
        var results: std.ArrayListUnmanaged(api.Block) = .empty;
        for (reply.tool_uses) |tu| {
            assistant.append(arena, .{ .tool_use = .{
                .id = arena.dupe(u8, tu.id) catch return,
                .name = arena.dupe(u8, tu.name) catch return,
                .input_json = arena.dupe(u8, tu.input_json) catch return,
            } }) catch return;
            const r = try executeTool(arena, io, gpa, events, j, cwd, tu.name, tu.input, write_tools);
            results.append(arena, .{ .tool_result = .{ .tool_use_id = arena.dupe(u8, tu.id) catch return, .content = r.text, .is_error = r.is_error } }) catch return;
            const note = std.fmt.allocPrint(gpa, "⚙ {s}\n", .{r.note}) catch return;
            events.post(io, .{ .ai = .{ .job = j.id, .msg = .{ .text = note } } });
        }
        messages.append(arena, .{ .role = "assistant", .blocks = assistant.items }) catch return;
        messages.append(arena, .{ .role = "user", .blocks = results.items }) catch return;
    }
    events.post(io, .{ .ai = .{ .job = j.id, .msg = .done } });
}

const ToolResult = struct { text: []const u8, note: []const u8, is_error: bool = false };

/// The workspace tools, on the worker. Paths are workspace-relative
/// and may not climb out. `write_file` asks the UI first.
fn executeTool(arena: Allocator, io: Io, gpa: Allocator, events: *event.EventQueue, j: *Job, cwd: []const u8, name: []const u8, input: std.json.Value, write_tools: bool) Io.Cancelable!ToolResult {
    const fail = struct {
        fn f(a: Allocator, comptime fmt: []const u8, args: anytype) ToolResult {
            const m = std.fmt.allocPrint(a, fmt, args) catch "error";
            return .{ .text = m, .note = m, .is_error = true };
        }
    };
    var root = Io.Dir.cwd().openDir(io, cwd, .{ .iterate = true }) catch return fail.f(arena, "workspace unreadable", .{});
    defer root.close(io);
    if (std.mem.eql(u8, name, "read_file")) {
        const rel = safeRel(api.inputStr(input, "path") orelse "") orelse return fail.f(arena, "read_file: bad path", .{});
        const text = root.readFileAlloc(io, rel, arena, .limited(tool_read_cap)) catch |err| return fail.f(arena, "read_file {s}: {s}", .{ rel, @errorName(err) });
        return .{ .text = text, .note = std.fmt.allocPrint(arena, "read {s} ({d} bytes)", .{ rel, text.len }) catch "read" };
    }
    if (std.mem.eql(u8, name, "list_directory")) {
        const rel_in = api.inputStr(input, "path") orelse ".";
        const rel = safeRel(if (rel_in.len == 0) "." else rel_in) orelse return fail.f(arena, "list_directory: bad path", .{});
        var dir = root.openDir(io, rel, .{ .iterate = true }) catch |err| return fail.f(arena, "list_directory {s}: {s}", .{ rel, @errorName(err) });
        defer dir.close(io);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var it = dir.iterate();
        var n: usize = 0;
        while (it.next(io) catch null) |entry| {
            if (n >= 500) break;
            n += 1;
            out.appendSlice(arena, entry.name) catch break;
            if (entry.kind == .directory) out.append(arena, '/') catch break;
            out.append(arena, '\n') catch break;
        }
        return .{ .text = out.items, .note = std.fmt.allocPrint(arena, "listed {s} ({d} entries)", .{ rel, n }) catch "listed" };
    }
    if (std.mem.eql(u8, name, "grep")) {
        const pattern = api.inputStr(input, "pattern") orelse return fail.f(arena, "grep: no pattern", .{});
        if (pattern.len == 0) return fail.f(arena, "grep: empty pattern", .{});
        const hits = try grepWorkspace(arena, io, gpa, root, pattern);
        return .{ .text = if (hits.len == 0) "(no matches)" else hits, .note = std.fmt.allocPrint(arena, "grep {s}", .{pattern}) catch "grep" };
    }
    if (std.mem.eql(u8, name, "write_file")) {
        if (!write_tools) return fail.f(arena, "write_file: disabled (set [ai] api_write_tools = true to enable it)", .{});
        const rel = safeRel(api.inputStr(input, "path") orelse "") orelse return fail.f(arena, "write_file: bad path", .{});
        const content = api.inputStr(input, "content") orelse "";
        const detail = std.fmt.allocPrint(gpa, "  write {s} ({d} bytes)?", .{ rel, content.len }) catch return fail.f(arena, "write_file: out of memory", .{});
        events.post(io, .{ .ai = .{ .job = j.id, .msg = .{ .confirm = detail } } });
        // D3: park on the job's queue until the confirm box answers.
        const yes = j.confirm.getOne(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => false,
        };
        if (!yes) return fail.f(arena, "write_file {s}: denied by the user", .{rel});
        if (std.fs.path.dirname(rel)) |d| root.createDirPath(io, d) catch {};
        root.writeFile(io, .{ .sub_path = rel, .data = content }) catch |err| return fail.f(arena, "write_file {s}: {s}", .{ rel, @errorName(err) });
        const note = std.fmt.allocPrint(arena, "wrote {s} ({d} bytes)", .{ rel, content.len }) catch "wrote";
        return .{ .text = note, .note = note };
    }
    return fail.f(arena, "unknown tool {s}", .{name});
}

/// A workspace-relative path that stays inside the workspace.
pub fn safeRel(p: []const u8) ?[]const u8 {
    if (p.len == 0) return null;
    if (std.fs.path.isAbsolute(p)) return null;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return null;
    return p;
}

const grep_skip = [_][]const u8{ ".git", "node_modules", "target", "zig-out", ".zig-cache", "zig-cache", ".mnml", "vendor", "dist", "build" };
const grep_cap: usize = 200;

fn grepWorkspace(arena: Allocator, io: Io, gpa: Allocator, root: Io.Dir, pattern: []const u8) Io.Cancelable![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var walker = root.walk(gpa) catch return "";
    defer walker.deinit();
    var hits: usize = 0;
    while (walker.next(io) catch null) |entry| {
        if (hits >= grep_cap) break;
        if (entry.kind == .directory) {
            var skip = entry.basename.len > 0 and entry.basename[0] == '.';
            for (grep_skip) |s| if (std.mem.eql(u8, entry.basename, s)) {
                skip = true;
            };
            if (skip) walker.leave(io);
            continue;
        }
        if (entry.kind != .file) continue;
        try io.checkCancel();
        const st = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        if (st.size > 1024 * 1024) continue;
        const text = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(1024 * 1024)) catch continue;
        defer gpa.free(text);
        if (std.mem.indexOfScalar(u8, text[0..@min(text.len, 4096)], 0) != null) continue;
        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            if (std.mem.indexOf(u8, line, pattern) == null) continue;
            out.print(arena, "{s}:{d}: {s}\n", .{ entry.path, line_no, transcript.firstLine(line, 200) }) catch break;
            hits += 1;
            if (hits >= grep_cap) break;
        }
    }
    return out.items;
}

// ─── the Pane.ai keys ───────────────────────────────────────────────────

/// Keys on an answer pane. False lets the chord chain see the key.
pub fn paneKey(app: *App, id: PaneId, p: *AiPane, k: Key) Allocator.Error!bool {
    switch (k.code) {
        .down => p.scroll += 1,
        .up => p.scroll -|= 1,
        .page_down => p.scroll += @max(app.pane_rows, 1),
        .page_up => p.scroll -|= @max(app.pane_rows, 1),
        .home => p.scroll = 0,
        .esc => try app.forceClosePane(id),
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'j' => p.scroll += 1,
                'k' => p.scroll -|= 1,
                'g' => p.scroll = 0,
                'q' => try app.forceClosePane(id),
                'r' => runToast(app, reaskCmd(app)),
                'c' => runToast(app, cancelCmd(app)),
                'a' => runToast(app, applyCmd(app)),
                'p' => runToast(app, promoteCmd(app)),
                'y' => {
                    try app.clipboard.setYank(p.answer.items, false);
                    app.toast("copied the answer", .{});
                },
                else => return false,
            }
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

pub fn scrollBy(p: *AiPane, delta: i64) void {
    const cur: i64 = @intCast(p.scroll);
    p.scroll = @intCast(@max(cur + delta, 0));
}

fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| {
        if (err == error.Canceled) return;
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("ai: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

fn activeAi(app: *App) CommandError!*AiPane {
    const id = app.active orelse return error.NoActivePane;
    const p = app.panes.get(id) orelse return error.NoActivePane;
    return switch (p.*) {
        .ai => |*a| a,
        else => app.diag.fail(app.frame.allocator(), "not an AI pane", .{}),
    };
}

// ─── commands: ask / actions ────────────────────────────────────────────

fn askCmd(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "Ask Claude"), .purpose = .ai_ask } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The prompt's accept: a bare question.
pub fn askAccept(app: *App, text: []const u8) CommandError!void {
    const q = std.mem.trim(u8, text, " \t");
    if (q.len == 0) return;
    _ = try ask(app, "ai: ask", q, .ask, null);
}

/// `ai.chat` — the question rides with the active file and selection.
fn chatCmd(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "Chat with Claude (file + selection as context)"), .purpose = .ai_chat } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn chatAccept(app: *App, text: []const u8) CommandError!void {
    const q = std.mem.trim(u8, text, " \t");
    if (q.len == 0) return;
    const arena = app.frame.allocator();
    var prompt: std.ArrayListUnmanaged(u8) = .empty;
    if (app.activeEditor()) |e| {
        const path = if (e.buf.doc.path) |p| app.relPath(p) else "[scratch]";
        const lang = suggest.languageOf(e.buf.doc.path);
        if (e.buf.editor.selection()) |sel| if (sel[1] > sel[0]) {
            try prompt.print(arena, "Selection from {s}:\n\n```{s}\n{s}\n```\n\n", .{ path, lang, e.buf.editor.bytes()[sel[0]..sel[1]] });
        };
        if (prompt.items.len == 0) {
            const body = e.buf.editor.bytes();
            try prompt.print(arena, "File {s}:\n\n```{s}\n{s}\n```\n\n", .{ path, lang, body[0..@min(body.len, 12_000)] });
        }
    }
    try prompt.appendSlice(arena, q);
    _ = try ask(app, "ai: chat", prompt.items, .chat, null);
}

/// The selection, or the whole file, of the active editor.
fn actionTarget(app: *App) CommandError!struct { code: []const u8, lang: []const u8, apply: AiPane.ApplyTarget } {
    const id = app.active orelse return error.NoActivePane;
    const e = app.panes.editor(id) orelse return error.NotAnEditor;
    const ed = e.buf.editor;
    const lang = suggest.languageOf(e.buf.doc.path);
    if (ed.selection()) |sel| if (sel[1] > sel[0]) {
        return .{ .code = try app.frame.allocator().dupe(u8, ed.bytes()[sel[0]..sel[1]]), .lang = lang, .apply = .{ .pane = id, .start = sel[0], .end = sel[1] } };
    };
    if (ed.len() == 0) return error.NoSelection;
    return .{ .code = try app.frame.allocator().dupe(u8, ed.bytes()), .lang = lang, .apply = .{ .pane = id, .start = 0, .end = ed.len() } };
}

fn action(app: *App, what: []const u8) CommandError!void {
    const target = try actionTarget(app);
    const prompt = try cli.actionPrompt(app.frame.allocator(), what, target.code, target.lang);
    const title = try std.fmt.allocPrint(app.frame.allocator(), "ai: {s}", .{what});
    _ = try ask(app, title, prompt, .action, target.apply);
}

fn explainCmd(app: *App) CommandError!void {
    return action(app, "explain");
}
fn fixCmd(app: *App) CommandError!void {
    return action(app, "fix");
}
fn refactorCmd(app: *App) CommandError!void {
    return action(app, "refactor");
}
fn writeTestsCmd(app: *App) CommandError!void {
    return action(app, "write_tests");
}

/// `r`: the same prompt again, a fresh session, in place of this pane.
fn reaskCmd(app: *App) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    const p = try activeAi(app);
    const prompt = try app.frame.allocator().dupe(u8, p.prompt);
    const title = try app.frame.allocator().dupe(u8, p.title);
    const kind = p.kind;
    const apply = p.apply;
    if (app.ai.job(p.job)) |j| j.cancel.store(true, .release);
    try app.forceClosePane(id);
    _ = try ask(app, title, prompt, kind, apply);
}

fn cancelCmd(app: *App) CommandError!void {
    const p = try activeAi(app);
    if (p.status != .running) return app.diag.fail(app.frame.allocator(), "nothing running", .{});
    if (app.ai.job(p.job)) |j| {
        j.cancel.store(true, .release);
        answerConfirm(app, j.id, false);
    }
    p.status = .failed;
    if (p.err) |old| app.gpa.free(old);
    p.err = try app.gpa.dupe(u8, "cancelled");
    app.toast("ai: cancelled", .{});
}

/// `p`: continue the one-shot interactively — `claude --resume <id>`.
fn promoteCmd(app: *App) CommandError!void {
    const p = try activeAi(app);
    if (!p.has_session) return app.diag.fail(app.frame.allocator(), "no CLI session to resume (the API backend has none)", .{});
    const argv = try cli.claudeResumeArgv(app.frame.allocator(), &p.session_id);
    _ = try pty_pane.open(app, .{ .argv = argv, .label = "claude", .placement = .tab, .kind = .command });
}

/// `a`: the first code block becomes a proposal for what the action
/// was run on, reviewed hunk by hunk in `Pane.ai_apply` before any of
/// it reaches the editor (`ai_apply.zig`).
fn applyCmd(app: *App) CommandError!void {
    const source = app.active orelse return error.NoActivePane;
    const p = try activeAi(app);
    const arena = app.frame.allocator();
    const code = cli.firstCodeBlock(p.answer.items) orelse return app.diag.fail(arena, "no code block in the answer", .{});
    const target = p.apply orelse blk: {
        const id = app.last_editor orelse return app.diag.fail(arena, "no editor to apply to", .{});
        const e = app.panes.editor(id) orelse return app.diag.fail(arena, "no editor to apply to", .{});
        const sel = e.buf.editor.selection() orelse [2]usize{ 0, e.buf.editor.len() };
        break :blk AiPane.ApplyTarget{ .pane = id, .start = sel[0], .end = sel[1] };
    };
    // The block's own trailing newline is part of the proposal; the
    // fence's is not.
    const proposal = try std.fmt.allocPrint(arena, "{s}\n", .{code});
    _ = try ai_apply.open(app, source, target.pane, target.start, target.end, proposal);
}

/// `ai.session_view`: the transcript file of this pane's session, live
/// through the file watcher.
fn sessionViewCmd(app: *App) CommandError!void {
    const p = try activeAi(app);
    if (!p.has_session) return app.diag.fail(app.frame.allocator(), "no CLI session (the API backend writes no transcript)", .{});
    const path = try transcriptPath(app, &p.session_id);
    _ = app.openEditor(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(app.frame.allocator(), "transcript not on disk yet: {s}", .{app.relPath(path)}),
    };
}

/// `<home>/.claude/projects/<encoded workspace>/<sid>.jsonl`.
pub fn transcriptPath(app: *App, session_id: []const u8) CommandError![]const u8 {
    const home = app.homeDir() orelse return app.diag.fail(app.frame.allocator(), "no home directory", .{});
    const arena = app.frame.allocator();
    const enc = try encodeWorkspace(arena, app.workspace);
    const name = try std.fmt.allocPrint(arena, "{s}.jsonl", .{session_id});
    return std.fs.path.join(arena, &.{ home, ".claude", "projects", enc, name });
}

/// Claude Code's directory name for a workspace: every `/` (and `.`)
/// becomes `-`.
pub fn encodeWorkspace(arena: Allocator, ws: []const u8) Allocator.Error![]u8 {
    const out = try arena.dupe(u8, ws);
    for (out) |*c| if (c.* == '/' or c.* == '.') {
        c.* = '-';
    };
    return out;
}

// ─── commands: sessions as pty panes ────────────────────────────────────

pub const Product = launch_profiles.Product;

/// Open an interactive session with the product's default launch
/// profile (`launch_profiles.zig`). `ai_layout_mode = "tabs"` puts
/// every new session on the active leaf's strip; the default splits.
fn openSession(app: *App, product: Product, placement: ?pty_pane.Placement) CommandError!PaneId {
    if (route(app, if (product == .claude) .claude else .codex) == .off) return app.diag.fail(app.frame.allocator(), "{s} is routed off in [ai.routing]", .{@tagName(product)});
    // changed (ui-polish): `ui.ai_layout_mode` is the typed field; the
    // `[ai] layout_mode` extra still overrides it.
    const tabs = if (extraString(app, "layout_mode")) |m| std.ascii.eqlIgnoreCase(m, "tabs") else app.cfg.ui.ai_layout_mode == .tabs;
    const where: pty_pane.Placement = placement orelse (if (tabs) .tab else .right);
    return launch_profiles.openSessionWith(app, product, launch_profiles.defaultName(app, product), where);
}

/// The live session pane of `product`, if one is open — the bare
/// binary or one of its profile shims.
pub fn findSession(app: *App, product: Product) ?PaneId {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .pty => |*term| if (term.exit == null and term.argv.len > 0 and launch_profiles.isProductArgv(app, term.argv[0], product)) return @intCast(i),
        else => {},
    };
    return null;
}

fn claudeCode(app: *App) CommandError!void {
    _ = try openSession(app, .claude, null);
}

/// Focus the running session, or start one.
fn claudeCodeFocus(app: *App) CommandError!void {
    if (findSession(app, .claude)) |id| return app.showPane(id);
    _ = try openSession(app, .claude, null);
}

fn claudeCodeNew(app: *App) CommandError!void {
    _ = try openSession(app, .claude, null);
}

/// N sessions: a grid (split right, then each column split down) or
/// N tabs, per `ai_layout_mode`.
fn openBatch(app: *App, product: Product, n: usize) CommandError!void {
    // changed (ui-polish): `ui.ai_layout_mode` is the typed field; the
    // `[ai] layout_mode` extra still overrides it.
    const tabs = if (extraString(app, "layout_mode")) |m| std.ascii.eqlIgnoreCase(m, "tabs") else app.cfg.ui.ai_layout_mode == .tabs;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const placement: pty_pane.Placement = if (tabs) .tab else if (i == 0) .right else if (i % 2 == 1) .below else .right;
        _ = try openSession(app, product, placement);
    }
    app.toast("opened {d} {s} session{s}", .{ n, @tagName(product), if (n == 1) "" else "s" });
}

fn claudeCodeNewX2(app: *App) CommandError!void {
    return openBatch(app, .claude, 2);
}
fn claudeCodeNewX4(app: *App) CommandError!void {
    return openBatch(app, .claude, 4);
}
fn claudeCodeNewX8(app: *App) CommandError!void {
    return openBatch(app, .claude, 8);
}
fn claudeCodeNewLeft(app: *App) CommandError!void {
    _ = try openSession(app, .claude, .left);
}
fn claudeCodeNewRight(app: *App) CommandError!void {
    _ = try openSession(app, .claude, .right);
}
fn claudeCodeNewTop(app: *App) CommandError!void {
    _ = try openSession(app, .claude, .above);
}
fn claudeCodeNewBottom(app: *App) CommandError!void {
    _ = try openSession(app, .claude, .below);
}
fn codex(app: *App) CommandError!void {
    if (findSession(app, .codex)) |id| return app.showPane(id);
    _ = try openSession(app, .codex, null);
}
fn codexNew(app: *App) CommandError!void {
    _ = try openSession(app, .codex, null);
}
fn codexNewLeft(app: *App) CommandError!void {
    _ = try openSession(app, .codex, .left);
}
fn codexNewRight(app: *App) CommandError!void {
    _ = try openSession(app, .codex, .right);
}
fn codexNewTop(app: *App) CommandError!void {
    _ = try openSession(app, .codex, .above);
}
fn codexNewBottom(app: *App) CommandError!void {
    _ = try openSession(app, .codex, .below);
}

/// `ai.session_picker`: this workspace's transcripts, newest first;
/// the pick resumes it.
fn sessionPicker(app: *App) CommandError!void {
    const gpa = app.gpa;
    const home = app.homeDir() orelse return app.diag.fail(app.frame.allocator(), "no home directory", .{});
    const arena = app.frame.allocator();
    const enc = try encodeWorkspace(arena, app.workspace);
    const dir_path = try std.fs.path.join(arena, &.{ home, ".claude", "projects", enc });
    var dir = Io.Dir.cwd().openDir(app.io, dir_path, .{ .iterate = true }) catch return app.diag.fail(arena, "no Claude sessions for this workspace yet", .{});
    defer dir.close(app.io);
    const Entry = struct { name: []u8, mtime: i64 };
    var found: std.ArrayListUnmanaged(Entry) = .empty;
    defer found.deinit(arena);
    var it = dir.iterate();
    while (it.next(app.io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const st = dir.statFile(app.io, entry.name, .{}) catch continue;
        try found.append(arena, .{ .name = try arena.dupe(u8, entry.name[0 .. entry.name.len - ".jsonl".len]), .mtime = st.mtime.toSeconds() });
    }
    if (found.items.len == 0) return app.diag.fail(arena, "no Claude sessions for this workspace yet", .{});
    std.mem.sort(Entry, found.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.mtime > b.mtime;
        }
    }.lt);
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (found.items) |f| {
        try labels.append(gpa, try gpa.dupe(u8, f.name));
        try details.append(gpa, try std.fmt.allocPrint(gpa, "{d}", .{f.mtime}));
    }
    try cmd_picker.openPickerWith(app, "Claude sessions (this workspace)", .ai_session, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
}

/// The session picker's accept: `claude --resume <id>`.
pub fn sessionAccept(app: *App, session_id: []const u8) CommandError!void {
    const argv = try cli.claudeResumeArgv(app.frame.allocator(), session_id);
    _ = try pty_pane.open(app, .{ .argv = argv, .label = "claude", .placement = .right, .kind = .command });
}

/// `ai.session_search`: a substring over every transcript, into the
/// quickfix list.
fn sessionSearchCmd(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "search all Claude transcripts:"), .purpose = .ai_search } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn sessionSearchAccept(app: *App, query_in: []const u8) CommandError!void {
    const query = std.mem.trim(u8, query_in, " \t");
    if (query.len == 0) return;
    const gpa = app.gpa;
    const home = app.homeDir() orelse return app.diag.fail(app.frame.allocator(), "no home directory", .{});
    const arena = app.frame.allocator();
    const root_path = try std.fs.path.join(arena, &.{ home, ".claude", "projects" });
    var root = Io.Dir.cwd().openDir(app.io, root_path, .{ .iterate = true }) catch return app.diag.fail(arena, "no Claude transcripts under ~/.claude/projects", .{});
    defer root.close(app.io);
    var entries: std.ArrayListUnmanaged(app_mod.ListPane.Entry) = .empty;
    errdefer {
        for (entries.items) |e| {
            gpa.free(e.text);
            if (e.path) |p| gpa.free(p);
        }
        entries.deinit(gpa);
    }
    var walker = root.walk(gpa) catch return error.OutOfMemory;
    defer walker.deinit();
    var files: usize = 0;
    while (walker.next(app.io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".jsonl")) continue;
        files += 1;
        if (entries.items.len >= 500) break;
        const st = entry.dir.statFile(app.io, entry.basename, .{}) catch continue;
        if (st.size > 64 * 1024 * 1024) continue;
        const text = entry.dir.readFileAlloc(app.io, entry.basename, gpa, .limited(64 * 1024 * 1024)) catch continue;
        defer gpa.free(text);
        var line_no: u32 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            const at = std.mem.indexOf(u8, line, query) orelse continue;
            const from = at -| 60;
            const snippet = transcript.firstLine(line[from..@min(line.len, at + query.len + 100)], 200);
            const abs = try std.fs.path.join(gpa, &.{ root_path, entry.path });
            errdefer gpa.free(abs);
            try entries.append(gpa, .{ .text = try gpa.dupe(u8, snippet), .path = abs, .line = line_no, .col = @intCast(at + 1) });
            if (entries.items.len >= 500) break;
        }
    }
    if (entries.items.len == 0) return app.diag.fail(arena, "\"{s}\": no matches in {d} transcripts", .{ query, files });
    app.toast("{d} match{s} for \"{s}\"", .{ entries.items.len, if (entries.items.len == 1) "" else "es", query });
    try cmd_view.openListPane(app, .quickfix, try entries.toOwnedSlice(gpa));
}

// ─── commands: setup / config ───────────────────────────────────────────

fn toggleBackend(app: *App) CommandError!void {
    const cur = app.cfg.ai.routing.claude.backend orelse app.cfg.ai.backend orelse .auto;
    const next: Config.AiBackend = switch (cur) {
        .auto => .api,
        .api => .sub,
        .sub => .off,
        .off => .auto,
    };
    app.cfg.ai.routing.claude.backend = next;
    _ = try settings.persist(app, .home, &.{ "ai", "routing", "claude", "backend" }, next);
    app.toast("AI backend: {s} ({s})", .{ @tagName(next), switch (route(app, .claude)) {
        .cli => "claude CLI",
        .api => "Messages API",
        .off => "off",
    } });
}

fn toggleInline(app: *App) CommandError!void {
    const next = !app.cfg.ai.inline_suggestions;
    if (next and suggestBackend(app) == .unset) return setupSuggestions(app);
    app.cfg.ai.inline_suggestions = next;
    _ = try settings.persist(app, .home, &.{ "ai", "inline_suggestions" }, next);
    if (!next) {
        app.ai.debounce.cancel();
        if (app.activeEditor()) |e| try e.buf.editor.setGhostSuggestion(null);
    }
    app.toast("AI ghost-text: {s}", .{if (next) "on" else "off"});
}

pub const backend_rows = [_]suggest.Backend{ .claude_code, .claude_api, .local };

/// `ai.setup_suggestions`: the backend picker (change it any time).
fn setupSuggestions(app: *App) CommandError!void {
    const gpa = app.gpa;
    const cur = suggestBackend(app);
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    const rows = [_]struct { b: suggest.Backend, label: []const u8, detail: []const u8 }{
        .{ .b = .claude_code, .label = "Claude Code sub", .detail = "reuses your Max/Pro plan · no separate API key · ~1s" },
        .{ .b = .claude_api, .label = "Claude API", .detail = "needs $ANTHROPIC_API_KEY · ~1s · works now" },
        .{ .b = .local, .label = "Local model (embedded)", .detail = "not in this release — a migration note for now" },
    };
    for (rows) |r| {
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}", .{ if (cur == r.b) "● " else "  ", r.label }));
        try details.append(gpa, try gpa.dupe(u8, r.detail));
    }
    try labels.append(gpa, try gpa.dupe(u8, "  Turn off inline suggestions"));
    try details.append(gpa, try gpa.dupe(u8, "disable AI ghost-text"));
    try cmd_picker.openPickerWith(app, "AI inline suggestions — pick a backend", .ai_suggest_backend, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
}

/// The picker's accept, by unfiltered row.
pub fn setupAccept(app: *App, row: usize) CommandError!void {
    if (row >= backend_rows.len) {
        app.cfg.ai.inline_suggestions = false;
        _ = try settings.persist(app, .home, &.{ "ai", "inline_suggestions" }, false);
        app.ai.debounce.cancel();
        if (app.activeEditor()) |e| try e.buf.editor.setGhostSuggestion(null);
        app.toast("AI ghost-text: off", .{});
        return;
    }
    const b = backend_rows[row];
    app.ai.backend_override = b;
    app.ai.local_note_shown = false;
    app.ai.key_missing_toasted = false;
    app.cfg.ai.inline_suggestions = true;
    _ = try settings.persist(app, .home, &.{ "ai", "suggest_backend" }, b.token());
    _ = try settings.persist(app, .home, &.{ "ai", "inline_suggestions" }, true);
    switch (b) {
        .local => app.toast("{s}", .{suggest.migration_note}),
        .claude_api => app.toast("AI ghost-text: Claude API{s}", .{if (app.env.get(api.env_key) == null) " — export $ANTHROPIC_API_KEY to use it" else " · on"}),
        .claude_code => app.toast("AI ghost-text: Claude Code sub · on (run `claude` once to sign in)", .{}),
        .unset => {},
    }
}

fn suggestionStats(app: *App) CommandError!void {
    const st = &app.ai;
    if (st.shown == 0) return app.toast("AI ghost-text: no suggestions shown yet this session", .{});
    const pct = @as(u64, st.accepted) * 100 / @as(u64, st.shown);
    app.toast("AI ghost-text: {d} of {d} accepted ({d}%)", .{ st.accepted, st.shown, pct });
}

fn showConfig(app: *App) CommandError!void {
    const r = route(app, .claude);
    app.toast("AI: backend {s} · model {s} · tools {s}{s} · ghost-text {s} ({s})", .{
        switch (r) {
            .cli => "claude CLI",
            .api => "Messages API",
            .off => "off",
        },
        extraString(app, "model") orelse api.default_model,
        if (extraBool(app, "api_tools") orelse true) "on" else "off",
        if (extraBool(app, "api_write_tools") orelse false) " +write" else "",
        if (app.cfg.ai.inline_suggestions) "on" else "off",
        suggestBackend(app).label(),
    });
}

fn tokenUsage(app: *App) CommandError!void {
    if (app.ai.meter) |m| {
        var buf: [16]u8 = undefined;
        return app.toast("AI (24h): {s} tokens · ${d:.4} · {d} sessions", .{ transcript.fmtTokens(&buf, m.tokens), m.cost_usd, m.sessions });
    }
    return spend.refreshMeter(app);
}

fn canary(app: *App) CommandError!void {
    return app.diag.fail(app.frame.allocator(), "the API-key canary log is not in this build", .{});
}

fn notInBuildCmd(app: *App) CommandError!void {
    return app.diag.fail(app.frame.allocator(), "not in this build yet", .{});
}

fn showLastResponse(app: *App) CommandError!void {
    return app.diag.fail(app.frame.allocator(), "the quota endpoint is not in this build; ai.spend_today reads the local transcripts", .{});
}

// ─── commands: git prompts ──────────────────────────────────────────────

fn gitOut(app: *App, argv: []const []const u8) CommandError![]const u8 {
    const arena = app.frame.allocator();
    const result = std.process.run(app.gpa, app.io, .{ .argv = argv, .cwd = .{ .path = app.workspace }, .stdout_limit = .limited(512 * 1024) }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "git: {s}", .{@errorName(err)}),
    };
    defer app.gpa.free(result.stdout);
    defer app.gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return app.diag.fail(arena, "git: {s}", .{std.mem.trim(u8, result.stderr, " \n")});
    return arena.dupe(u8, result.stdout);
}

fn explainDiff(app: *App) CommandError!void {
    var diff = try gitOut(app, &.{ "git", "diff", "--cached" });
    if (std.mem.trim(u8, diff, " \n").len == 0) diff = try gitOut(app, &.{ "git", "diff" });
    if (std.mem.trim(u8, diff, " \n").len == 0) return app.diag.fail(app.frame.allocator(), "nothing to explain: the working tree is clean", .{});
    const prompt = try std.fmt.allocPrint(app.frame.allocator(), "Explain this diff, walking through what changed and why it might have:\n\n```diff\n{s}\n```\n", .{diff[0..@min(diff.len, 60_000)]});
    _ = try ask(app, "ai: explain diff", prompt, .git, null);
}

fn writePrDescription(app: *App) CommandError!void {
    const log = try gitOut(app, &.{ "git", "log", "--oneline", "main..HEAD" });
    const diff = try gitOut(app, &.{ "git", "diff", "main...HEAD", "--stat" });
    const prompt = try std.fmt.allocPrint(app.frame.allocator(), "Draft a pull-request description (title, summary, testing notes) for this branch.\n\nCommits:\n{s}\n\nFiles:\n{s}\n", .{ log, diff });
    _ = try ask(app, "ai: PR description", prompt, .git, null);
}

fn recomposeBranch(app: *App) CommandError!void {
    const log = try gitOut(app, &.{ "git", "log", "--format=%h %s%n%b", "main..HEAD" });
    if (std.mem.trim(u8, log, " \n").len == 0) return app.diag.fail(app.frame.allocator(), "no commits past main", .{});
    const prompt = try std.fmt.allocPrint(app.frame.allocator(), "Rewrite these commit messages to be clear and conventional. Do not change history yourself — list the new messages, one per commit, oldest first.\n\n{s}", .{log});
    _ = try ask(app, "ai: recompose branch", prompt, .git, null);
}

fn writeBranchName(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "Describe the branch (a branch name is suggested)"), .purpose = .ai_branch_name } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn branchNameAccept(app: *App, text: []const u8) CommandError!void {
    const d = std.mem.trim(u8, text, " \t");
    if (d.len == 0) return;
    const prompt = try std.fmt.allocPrint(app.frame.allocator(), "Suggest three git branch names (kebab-case, under 40 chars, with a type prefix like feat/ or fix/) for: {s}", .{d});
    _ = try ask(app, "ai: branch name", prompt, .git, null);
}

// ─── commands: the usage meter ──────────────────────────────────────────

fn linkClaudeToken(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    var st = app_mod.Prompt.init(app.gpa, "Paste the Claude Code OAuth token");
    st.secret = true;
    app.overlay = .{ .prompt = .{ .state = st, .purpose = .ai_token } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// `<home>/.config/mnml/ai_token`, mode 0600.
pub fn tokenAccept(app: *App, token_in: []const u8) CommandError!void {
    const token = std.mem.trim(u8, token_in, " \t\r\n");
    if (token.len == 0) return;
    const arena = app.frame.allocator();
    const home = app.homeDir() orelse return app.diag.fail(arena, "no home directory to keep the token in", .{});
    const dir = try std.fs.path.join(arena, &.{ home, ".config", "mnml" });
    Io.Dir.cwd().createDirPath(app.io, dir) catch {};
    const path = try std.fs.path.join(arena, &.{ dir, "ai_token" });
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = token }) catch |err| return app.diag.fail(arena, "could not write {s}: {s}", .{ path, @errorName(err) });
    app.toast("Claude token linked ({s})", .{app.relPath(path)});
}

fn claudeUsage(app: *App) CommandError!void {
    app.toast("Claude usage: the quota endpoint is not in this build — showing the local 24h spend", .{});
    return spend.open(app);
}

fn codexUsage(app: *App) CommandError!void {
    app.toast("Codex usage: the local 24h spend includes ~/.codex/sessions", .{});
    return spend.open(app);
}

fn refreshUsage(app: *App) CommandError!void {
    return spend.refreshMeter(app);
}

fn chipShowSession(app: *App) CommandError!void {
    app.ai.chip_detail = .session;
    app.toast("AI chip: session only", .{});
}
fn chipShowWeekly(app: *App) CommandError!void {
    app.ai.chip_detail = .weekly;
    app.toast("AI chip: weekly only", .{});
}
fn chipShowBoth(app: *App) CommandError!void {
    app.ai.chip_detail = .both;
    app.toast("AI chip: session · weekly", .{});
}
fn chipToggleReset(app: *App) CommandError!void {
    app.ai.chip_reset_suffix = !app.ai.chip_reset_suffix;
    app.toast("AI chip: reset countdown {s}", .{if (app.ai.chip_reset_suffix) "on" else "off"});
}

fn setMeterMode(app: *App, mode: Config.ClaudeMeterMode) CommandError!void {
    app.cfg.ai.claude_meter_mode = mode;
    app.cfg.ai.claude_show_all_accounts = mode != .off;
    _ = try settings.persist(app, .home, &.{ "ai", "claude_meter_mode" }, mode);
    app.toast("AI chip: {s}", .{switch (mode) {
        .off => "active account only",
        .compact => "all accounts, compact",
        .ticker => "all accounts, ticker",
    }});
    app.needs_render = true;
}

fn chipCycleAccounts(app: *App) CommandError!void {
    return setMeterMode(app, switch (app.cfg.ai.claude_meter_mode) {
        .off => .compact,
        .compact => .ticker,
        .ticker => .off,
    });
}
fn chipAllOff(app: *App) CommandError!void {
    return setMeterMode(app, .off);
}
fn chipAllCompact(app: *App) CommandError!void {
    return setMeterMode(app, .compact);
}
fn chipAllTicker(app: *App) CommandError!void {
    return setMeterMode(app, .ticker);
}

// ─── cloud agents ───────────────────────────────────────────────────────

fn cloudNotInBuild(app: *App) CommandError!void {
    return app.diag.fail(app.frame.allocator(), "cloud agents (AWS ECS / Managed Agents) are not in this build yet", .{});
}

fn cloudToggleView(app: *App) CommandError!void {
    app.ai.cloud_compact = !app.ai.cloud_compact;
    app.toast("cloud agents: {s} rows", .{if (app.ai.cloud_compact) "compact" else "standard"});
}
fn cloudViewCompact(app: *App) CommandError!void {
    app.ai.cloud_compact = true;
    app.toast("cloud agents: compact rows", .{});
}
fn cloudViewStandard(app: *App) CommandError!void {
    app.ai.cloud_compact = false;
    app.toast("cloud agents: standard rows", .{});
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const screen_mod = @import("../ipc/screen.zig");

fn screenText(app: *App) ![]u8 {
    try app.render();
    return screen_mod.toTestText(t.allocator, &app.screen);
}

test "ghost text: Tab accepts at the cursor, ctrl+right a word, ctrl+down a line, any other key dismisses" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 10 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.editor.setText("hello");
    try e.buf.editor.setGhostSuggestion("GHOSTX");
    const before = try screenText(&app);
    defer t.allocator.free(before);
    try t.expect(std.mem.indexOf(u8, before, "GHOSTX") != null);
    try app.handle(.{ .key = Key.named(.tab) });
    try t.expectEqualStrings("GHOSTXhello", e.buf.editor.bytes());
    try t.expect(e.buf.editor.ghost_suggestion == null);
    try t.expect(e.buf.doc.dirty);
    try t.expectEqual(@as(u32, 1), app.ai.accepted);
    // Dismiss: the key goes on to the editor (cursor moved right).
    try e.buf.editor.setGhostSuggestion("DISMISSZ");
    const cur = e.buf.editor.cursor;
    try app.handle(.{ .key = Key.named(.right) });
    try t.expect(e.buf.editor.ghost_suggestion == null);
    try t.expectEqual(cur + 1, e.buf.editor.cursor);
    // Partial accepts chain.
    try e.buf.editor.setText("");
    try e.buf.editor.setGhostSuggestion("ALPHA BETA\nGAMMA");
    try app.handle(.{ .key = .{ .code = .right, .mods = .{ .ctrl = true } } });
    try t.expectEqualStrings("ALPHA", e.buf.editor.bytes());
    try t.expectEqualStrings(" BETA\nGAMMA", e.buf.editor.ghost_suggestion.?);
    try app.handle(.{ .key = .{ .code = .down, .mods = .{ .ctrl = true } } });
    try t.expectEqualStrings("ALPHA BETA\n", e.buf.editor.bytes());
    try t.expectEqualStrings("GAMMA", e.buf.editor.ghost_suggestion.?);
    try app.handle(.{ .key = Key.named(.tab) });
    try t.expectEqualStrings("ALPHA BETA\nGAMMA", e.buf.editor.bytes());
    // One suggestion, however many partial accepts, counts once.
    try t.expectEqual(@as(u32, 2), app.ai.accepted);
}

test "ghost text: typing arms the debounce; a stale generation's result is dropped, the live one lands" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 10 });
    defer app.deinit();
    app.tree.visible = false;
    const id = try app.openScratch();
    const e = app.activeEditor().?;
    try app.handle(.{ .key = Key.char('x') });
    try t.expect(app.ai.debounce.dirty_ms != null);
    try t.expectEqual(@as(?i64, app.now_ms + suggest.debounce_ms), nextDeadlineMs(&app));
    // Nothing is set up: the clock fires into the hint path and cancels.
    try app.tick(app.now_ms + 400);
    try t.expect(app.ai.debounce.dirty_ms == null);
    try t.expect(e.buf.editor.ghost_suggestion == null);
    // A worker's result for a generation that typing has moved past.
    const gen = app.ai.debounce.fire();
    app.ai.suggest_pane = id;
    app.ai.debounce.noteEdit(app.now_ms);
    const stale = try t.allocator.dupe(u8, "OLD");
    try app.handle(.{ .ai = .{ .job = 0, .msg = .{ .suggestion = .{ .pane = id, .generation = gen, .text = stale } } } });
    try t.expect(e.buf.editor.ghost_suggestion == null);
    const live_gen = app.ai.debounce.fire();
    const live = try t.allocator.dupe(u8, "NEW");
    try app.handle(.{ .ai = .{ .job = 0, .msg = .{ .suggestion = .{ .pane = id, .generation = live_gen, .text = live } } } });
    try t.expectEqualStrings("NEW", e.buf.editor.ghost_suggestion.?);
    try t.expectEqual(@as(u32, 1), app.ai.shown);
}

test "the confirm channel: a worker parks on the job's queue; the UI's answer releases it" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 10 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const gpa = app.gpa;
    const j = try gpa.create(Job);
    j.* = .{ .id = app.ai.next_job, .confirm = undefined };
    j.confirm = .init(&j.confirm_buf);
    app.ai.next_job += 1;
    try app.ai.jobs.append(gpa, j);
    const pane: AiPane = .{ .gpa = gpa, .title = try gpa.dupe(u8, "ai: test"), .prompt = try gpa.dupe(u8, "p"), .job = j.id, .kind = .ask, .session_id = cli.genSessionId(app.io) };
    const pid = try app.panes.add(.{ .ai = pane });
    app.showPane(pid);
    const Worker = struct {
        var answer: ?bool = null;
        fn run(events: *event.EventQueue, io: Io, a: Allocator, job: *Job) Io.Cancelable!void {
            const detail = a.dupe(u8, "  write a.txt (3 bytes)?") catch return;
            events.post(io, .{ .ai = .{ .job = job.id, .msg = .{ .confirm = detail } } });
            answer = job.confirm.getOne(io) catch null;
            events.post(io, .{ .ai = .{ .job = job.id, .msg = .done } });
        }
    };
    Worker.answer = null;
    try app.ai.group.concurrent(app.io, Worker.run, .{ &app.events, app.io, gpa, j });
    // The confirm box opens once the event is pumped.
    var waited: usize = 0;
    while (app.overlay != .confirm and waited < 200) : (waited += 1) {
        try app.tick(app.now_ms);
        app.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    try t.expect(app.overlay == .confirm);
    try t.expectEqualStrings("AI wants to write a file", app.overlay.confirm.state.title);
    try t.expect(j.awaiting_confirm);
    // `a` allows: the worker wakes with true and finishes.
    try app.handle(.{ .key = Key.char('a') });
    try t.expect(app.overlay == .none);
    waited = 0;
    while (Worker.answer == null and waited < 200) : (waited += 1) {
        try app.tick(app.now_ms);
        app.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    try t.expectEqual(@as(?bool, true), Worker.answer);
    try app.ai.group.await(app.io);
    try app.tick(app.now_ms);
    try t.expect(j.finished);
    try t.expect(app.panes.get(pid).?.ai.status == .done);
}

test "a dismissed confirm box answers no, so the worker is never left parked" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 10 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const gpa = app.gpa;
    const j = try gpa.create(Job);
    j.* = .{ .id = 77, .confirm = undefined };
    j.confirm = .init(&j.confirm_buf);
    try app.ai.jobs.append(gpa, j);
    const pane: AiPane = .{ .gpa = gpa, .title = try gpa.dupe(u8, "ai: test"), .prompt = try gpa.dupe(u8, "p"), .job = 77, .kind = .ask, .session_id = cli.genSessionId(app.io) };
    _ = try app.panes.add(.{ .ai = pane });
    const detail = try gpa.dupe(u8, "write?");
    try app.handle(.{ .ai = .{ .job = 77, .msg = .{ .confirm = detail } } });
    try t.expect(app.overlay == .confirm);
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.overlay == .none);
    try t.expect(!j.awaiting_confirm);
    try t.expectEqual(false, try j.confirm.getOne(app.io));
}

test "the setup picker lists the backends and Esc leaves the config alone; a pick persists it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = buf[0..n], .data_root = buf[0..n], .cols = 80, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"ai.setup_suggestions" });
    try t.expect(app.overlay == .picker);
    const txt = try screenText(&app);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "pick a backend") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Claude API") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Local model") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Turn off inline suggestions") != null);
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.overlay == .none);
    try t.expectEqual(suggest.Backend.unset, suggestBackend(&app));
    // Pick the API row.
    try command.run(&app, .{ .static = .@"ai.setup_suggestions" });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqual(suggest.Backend.claude_api, suggestBackend(&app));
    const text = try tmp.dir.readFileAlloc(t.io, "config.zon", t.allocator, .unlimited);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".suggest_backend = \"claude-api\"") != null);
    // The local row toasts the migration note instead of enabling anything.
    try command.run(&app, .{ .static = .@"ai.setup_suggestions" });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings(suggest.migration_note, app.lastToast().?);
}

test "every ai / agents / cloud_agents id has a runner" {
    inline for (@typeInfo(command.CommandId).@"enum".fields) |f| {
        const name = f.name;
        if (std.mem.startsWith(u8, name, "ai.") or std.mem.startsWith(u8, name, "agents.") or std.mem.startsWith(u8, name, "cloud_agents.")) {
            const id: command.CommandId = @enumFromInt(f.value);
            if (command.runners.get(id) == null) {
                std.debug.print("no runner: {s}\n", .{name});
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "safeRel keeps paths inside the workspace" {
    try t.expectEqualStrings("src/a.zig", safeRel("src/a.zig").?);
    try t.expect(safeRel("../etc/passwd") == null);
    try t.expect(safeRel("/abs") == null);
    try t.expect(safeRel("a/../../b") == null);
    try t.expect(safeRel("") == null);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("-Users-me-Projects-mnml-zig", try encodeWorkspace(arena.allocator(), "/Users/me/Projects/mnml.zig"));
}
