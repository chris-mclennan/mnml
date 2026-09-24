//! AI (Phase 7): ghost text as you type, the one-shot and agentic jobs
//! behind `Pane.ai`, Claude Code / Codex as pty panes, and every `ai.*`
//! runner. The dashboard is `agents.zig`, the spend report `spend.zig`.
//!
//!   D1  every worker owns its argument strings and frees them; a result
//!       is posted as an owned `AiMsg` the handler adopts or frees;
//!   D3  one `Io.Group` for every AI worker; the ghost text has a group
//!       of its own so typing can cancel IT without touching a running
//!       agent — and cancelling kills the `claude -p` child, not just
//!       our interest in its answer. A job is cancelled by its atomic
//!       flag between turns; the confirm channel is the job's own
//!       `Io.Queue(bool)` — the worker parks on `getOne`, the confirm
//!       box answers with `putOne` (the D3 reverse channel);
//!   D2  workers never toast — they post `.err` / `.failed`.
//!
//! Local FIM is API-only in this release: `suggest_backend = "local"`
//! toasts the migration note once and sends nothing.
//!
//! Ghost text is observable (`app/ghost_chip.zig`): a statusline chip
//! for armed / in-flight / empty / error, one `:messages` line per
//! request with its latency, and `status.json`'s `"ghost"`. Three keys
//! shape it — `[ai] suggest_model` (a fast model by default: a
//! suggestion nobody waited for is worth nothing), `suggest_timeout_ms`
//! and `suggest_idle_ms`.

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
const os_path = @import("../core/os_path.zig");
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
const usage_pane = @import("usage_pane.zig");
const ghost_chip = @import("ghost_chip.zig");
const copilot_app = @import("copilot.zig");
const transcript = @import("../ai/transcript.zig");
const ai_apply = @import("ai_apply.zig");
const launch_profiles = @import("launch_profiles.zig");
const ai_grid = @import("ai_grid.zig");
const activity_bar = @import("activity_bar.zig");
const side = @import("side.zig");

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
    .@"ai.new_session_worktree" = &newSessionWorktree,
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
    .@"ai.write_pr_description" = &writePrDescription,
    .@"ai.write_branch_name" = &writeBranchName,
    .@"ai.recompose_branch" = &recomposeBranch,
    .@"ai.explain_diff" = &explainDiff,
    .@"ai.link_claude_token" = &linkClaudeToken,
    .@"ai.claude_usage" = &claudeUsage,
    .@"ai.claude_rename_account" = &claudeRenameAccount,
    .@"ai.claude_add_account" = &claudeAddAccount,
    .@"ai.claude_remove_account" = &claudeRemoveAccount,
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
    /// The ghost-text worker's own group. Separate from `group` so a
    /// keystroke can cancel the suggestion in flight — and with it the
    /// `claude -p` child — without touching an agent mid-answer.
    suggest_group: Io.Group = .init,
    /// The pane whose suggestion is in flight.
    suggest_pane: ?PaneId = null,
    /// Where that request was asked from: the document (compared, never
    /// dereferenced), its edit-log head and the cursor. An answer lands
    /// only if all three still hold (`noteRequest`).
    suggest_doc: ?*const anyopaque = null,
    suggest_seq: u64 = 0,
    suggest_cursor: usize = 0,
    /// What the chip, `:messages` and `status.json` read.
    ghost: ghost_chip.State = .{},
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
    /// The workers posting `.spend` for the meter (no pane).
    spend_group: Io.Group = .init,
    /// The grid's open slot is live: an `.empty` node the next Claude
    /// session fills (`ai_grid.zig`). Cleared when the tree has none.
    placeholder: bool = false,
    /// The quota reader's state: the per-account snapshots the chip and
    /// the usage panes read (`app/usage_pane.zig`).
    usage: usage_pane.State = .{},

    /// Cancels every worker and waits: they borrow `app.env`,
    /// `app.workspace` and post into `app.events`.
    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.group.cancel(io);
        self.suggest_group.cancel(io);
        self.spend_group.cancel(io);
        self.ghost.deinit(gpa);
        self.usage.deinit(gpa, io);
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
    /// What `ai.apply` replaces: the range the action was run on,
    /// followed along the editor's edits (`ai_apply.Anchor`).
    pub const ApplyTarget = ai_apply.Anchor;

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
    /// Owned: the text `apply` covered when the job started. A range the
    /// edit log could not follow (an undo, a reload) is still the right
    /// one if it reads exactly this.
    apply_original: ?[]u8 = null,
    /// The job's cancel flag (the `Job` outlives the pane). Closing the
    /// pane sets it: nobody will read the answer, so the child is killed
    /// rather than left to spend the user's quota finishing it.
    cancel: ?*std.atomic.Value(bool) = null,

    pub fn deinit(self: *AiPane) void {
        if (self.cancel) |c| c.store(true, .release);
        self.gpa.free(self.title);
        self.gpa.free(self.prompt);
        if (self.apply_original) |o| self.gpa.free(o);
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
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return os_path.which(app.io, &app.env, &buf, name) != null;
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
///
/// Dropping the result is not enough. With the `claude-code` backend
/// the flight is a whole `claude -p` process; leaving it to finish
/// means a machine grinding on answers for cursors that moved three
/// keystrokes ago, and the in-flight slot held the whole time. So the
/// child is killed: `suggest_group.cancel` unwinds the worker through
/// `std.process.run`'s `defer child.kill`. Only when something IS in
/// flight — the cancel is a no-op on an empty group, but the check
/// keeps a keystroke off the group's atomics.
pub fn noteEdit(app: *App) void {
    if (app.ai.debounce.in_flight != null) {
        app.ai.suggest_group.cancel(app.io);
        ghost_chip.settle(app, .cancelled, 0, null) catch {};
    }
    // `[ai] suggest_idle_ms` read here rather than baked in, so an
    // edit to the config takes on the very next keystroke.
    app.ai.debounce.idle_ms = app.cfg.ai.suggest_idle_ms;
    app.ai.debounce.noteEdit(app.now_ms);
    copilot_app.noteEdit(app);
}

/// Keys while a ghost is showing: Tab takes it, ctrl+→ a word,
/// ctrl+↓ a line; any other key dismisses it and goes on. Returns
/// true when the key was consumed.
pub fn interceptKey(app: *App, e: *EditorPane, k: Key) Allocator.Error!bool {
    const ghost = e.buf.editor.ghost_suggestion orelse return false;
    // A ghost is Insert's (or the modeless standard editor's): in vim's
    // Normal / Visual, or with the `:` line open, Tab is the mode's own
    // key and the ghost just goes — it must never land three lines of
    // text into a buffer nobody was typing in.
    if (!acceptsGhost(e)) {
        try e.buf.editor.setGhostSuggestion(null);
        app.needs_render = true;
        return false;
    }
    const plain = !k.mods.ctrl and !k.mods.alt and !k.mods.super and !k.mods.shift;
    const ctrl_only = k.mods.ctrl and !k.mods.alt and !k.mods.super and !k.mods.shift;
    if (k.code == .tab and plain) return acceptGhost(app, e, ghost.len);
    if (k.code == .right and ctrl_only) return acceptGhost(app, e, suggest.wordBoundary(ghost));
    if (k.code == .down and ctrl_only) return acceptGhost(app, e, suggest.lineBoundary(ghost));
    try e.buf.editor.setGhostSuggestion(null);
    app.needs_render = true;
    return false;
}

/// Whether a ghost may be fetched for or accepted into `e` right now:
/// a typing mode with the `:` line closed.
fn acceptsGhost(e: *const EditorPane) bool {
    if (e.buf.input.isCmdlineOpen()) return false;
    return switch (e.buf.input.mode()) {
        .none, .insert, .replace => true,
        .normal, .visual, .visual_line, .visual_block => false,
    };
}

/// Insert the first `take` bytes at the cursor; the rest stays a ghost.
fn acceptGhost(app: *App, e: *EditorPane, take_in: usize) Allocator.Error!bool {
    const ghost = e.buf.editor.ghost_suggestion orelse return false;
    const take = @min(take_in, ghost.len);
    if (take == 0) return false;
    const arena = app.frame.allocator();
    const accepted = try arena.dupe(u8, ghost[0..take]);
    const remaining = try arena.dupe(u8, ghost[take..]);
    // Before the splice, which is an edit that cancels the flight: the
    // accept telemetry needs the item that is still on screen.
    copilot_app.noteAccept(app, take, remaining.len);
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
    if (app.active) |id| if (app.panes.editor(id)) |e| try dropMovedGhost(app, e);
    if (app.ai.debounce.due(app.now_ms)) try fireSuggestion(app);
    try usage_pane.tick(app);
    usage_pane.pollTicker(app);
}

pub fn nextDeadlineMs(app: *const App) ?i64 {
    var next: ?i64 = app.ai.debounce.deadline();
    // The chip is animate: a spinner frame while a request is out, and
    // an `∅` / `!` that has to come down on its own. Without these the
    // frame would only redraw when something else asked it to, and the
    // elapsed would freeze at whatever it read when the user last typed.
    if (app.ai.debounce.in_flight != null) next = @min(next orelse std.math.maxInt(i64), app.now_ms + 100);
    for ([_]i64{ app.ai.ghost.empty_until_ms, app.ai.ghost.error_until_ms }) |until| {
        if (until > app.now_ms) next = @min(next orelse std.math.maxInt(i64), until);
    }
    if (spend.anyLoading(app)) next = @min(next orelse std.math.maxInt(i64), app.now_ms + 120);
    if (usage_pane.tickerActive(app)) next = @min(next orelse std.math.maxInt(i64), app.now_ms + 1000);
    return next;
}

fn fireSuggestion(app: *App) Allocator.Error!void {
    const st = &app.ai;
    if (!app.cfg.ai.inline_suggestions) return st.debounce.cancel();
    const id = app.active orelse return st.debounce.cancel();
    const e = app.panes.editor(id) orelse return st.debounce.cancel();
    if (e.buf.editor.ghost_suggestion != null) return st.debounce.cancel();
    if (!acceptsGhost(e)) return st.debounce.cancel();
    // A `.mnml/config.zon` written AFTER launch is not in `app.cfg`
    // (`copilot.refreshConfig`, and `lsp.refreshServers` before it).
    // Only look again when nothing has named a backend yet, so the
    // common path — a key in the home config — costs nothing.
    if (suggestBackend(app) == .unset) try copilot_app.refreshConfig(app);
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
        // Copilot is not a worker of ours: `app/copilot.zig` owns the
        // client, the privacy gate and the request. It settles the
        // same debounce and posts the same `.suggestion`.
        .copilot => return copilot_app.fireSuggestion(app, id, e),
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
    const model = try gpa.dupe(u8, suggestModel(app));
    errdefer gpa.free(model);
    const key_owned = try gpa.dupe(u8, key);
    errdefer gpa.free(key_owned);
    const cwd = try gpa.dupe(u8, app.workspace);
    errdefer gpa.free(cwd);
    // A fresh request replaces whatever the last one left on the chip.
    st.ghost.clearHolds();
    const generation = st.debounce.fire(app.now_ms);
    st.suggest_pane = id;
    noteRequest(app, e);
    st.current_accepted = false;
    st.suggest_group.concurrent(app.io, suggestWorker, .{ app.events, app.io, gpa, @as(u32, id), generation, backend, prompt, model, key_owned, cwd, &app.env, app.cfg.ai.suggest_timeout_ms }) catch {
        st.debounce.cancel();
        return error.OutOfMemory;
    };
    app.needs_render = true;
}

/// A suggestion request is going out for `e`: remember the spot it is
/// for. Both backends call this (`copilot.fireSuggestion` too).
pub fn noteRequest(app: *App, e: *const EditorPane) void {
    app.ai.suggest_doc = e.buf.doc;
    app.ai.suggest_seq = e.buf.doc.edits.head();
    app.ai.suggest_cursor = e.buf.editor.cursor;
}

/// Whether `e` is still at the spot the request in flight was made
/// from: the same document, no edit since, the cursor where it was.
fn atRequestedSpot(app: *const App, e: *const EditorPane) bool {
    const st = &app.ai;
    const doc = st.suggest_doc orelse return false;
    return doc == @as(*const anyopaque, e.buf.doc) and
        st.suggest_seq == e.buf.doc.edits.head() and
        st.suggest_cursor == e.buf.editor.cursor;
}

/// A ghost whose cursor has moved goes: a click, a jump, a motion that
/// did not pass through `interceptKey`. Run before an editor is painted
/// and on every tick.
pub fn dropMovedGhost(app: *App, e: *EditorPane) Allocator.Error!void {
    if (!e.buf.editor.ghostMoved()) return;
    try e.buf.editor.setGhostSuggestion(null);
    app.ai.current_accepted = false;
    app.needs_render = true;
}

/// `[ai] suggest_model` — a FAST model by default, and only here: the
/// panes and the agents keep `ai.model`. A suggestion is worth having
/// only if it beats the typist to the next token, so the trade the rest
/// of the app makes (the best model, however long it takes) is the
/// wrong one for this one call.
pub fn suggestModel(app: *App) []const u8 {
    return extraString(app, "suggest_model") orelse suggest.default_model;
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
///
/// Every exit but a cancel posts a `.suggestion` — an empty answer and
/// a failure included. Silence used to be the failure path, which is
/// exactly why a broken backend was indistinguishable from a slow one:
/// the app kept the request marked in flight and showed nothing, for
/// ever. The outcome travels with the result now, and the app settles
/// the clock, holds the chip and writes the `:messages` line off it.
fn suggestWorker(
    events: *event.EventQueue,
    io: Io,
    gpa: Allocator,
    pane: u32,
    generation: u32,
    backend: suggest.Backend,
    prompt: []u8,
    model: []u8,
    key: []u8,
    cwd: []u8,
    env: *const std.process.Environ.Map,
    timeout_ms: u32,
) Io.Cancelable!void {
    defer gpa.free(prompt);
    defer gpa.free(model);
    defer gpa.free(key);
    defer gpa.free(cwd);
    var raw: []u8 = undefined;
    switch (backend) {
        // The worker only ever runs for the Claude family: the picker's
        // other rows never reach `suggestWorker` (`fireSuggestion`
        // returns first), and a silent `return` here would read as a
        // request that vanished.
        .unset, .local, .copilot => return postOutcome(events, io, gpa, pane, generation, .failed, "no worker for this backend"),
        .claude_api => {
            const body = api.completionRequest(gpa, model, suggest.system_prompt, prompt, suggest.max_tokens) catch return;
            defer gpa.free(body);
            var url_arena = std.heap.ArenaAllocator.init(gpa);
            defer url_arena.deinit();
            const url = api.endpointFor(url_arena.allocator(), env) catch return;
            const res = api.post(gpa, io, url, key, body) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return postOutcome(events, io, gpa, pane, generation, .failed, "the request failed"),
            };
            defer gpa.free(res.body);
            if (res.status != 200) {
                var scratch = std.heap.ArenaAllocator.init(gpa);
                defer scratch.deinit();
                const why = api.errorMessage(scratch.allocator(), res.body) orelse "";
                const msg = std.fmt.allocPrint(scratch.allocator(), "HTTP {d} {s}", .{ res.status, why }) catch return;
                return postOutcome(events, io, gpa, pane, generation, .failed, msg);
            }
            var reply = api.parseReply(gpa, res.body) catch return;
            defer reply.deinit();
            raw = gpa.dupe(u8, reply.text) catch return;
        },
        .claude_code => {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            // The model is named here too, not only for the API: a
            // `claude -p` that picks up the CLI's own default runs the
            // big model for a one-line completion, which is where the
            // multi-second waits came from.
            // The prompt on stdin, as every job's is (`jobWorker`). A
            // keystroke cancels this worker's group, which unwinds
            // `runJob` through its kill.
            const argv = cli.claudeStdinArgv(arena.allocator(), null, model) catch return;
            const out = cli.runJob(gpa, io, argv, cwd, env, .{ .timeout_ms = timeout_ms, .stdin = prompt }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.TimedOut => return postOutcome(events, io, gpa, pane, generation, .timed_out, ""),
                else => |e| return postOutcome(events, io, gpa, pane, generation, .failed, @errorName(e)),
            };
            if (out.spawn_failed) {
                defer gpa.free(out.text);
                return postOutcome(events, io, gpa, pane, generation, .failed, spawnFailure(arena.allocator(), cli.claude_binary, out.text));
            }
            if (!out.ok) {
                defer gpa.free(out.text);
                const msg = std.fmt.allocPrint(arena.allocator(), "claude -p: {s}", .{out.text}) catch return;
                return postOutcome(events, io, gpa, pane, generation, .failed, msg);
            }
            raw = out.text;
        },
    }
    defer gpa.free(raw);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const clean = suggest.cleanCompletion(arena.allocator(), raw) catch return;
    if (clean.len == 0) return postOutcome(events, io, gpa, pane, generation, .empty, "");
    postOutcome(events, io, gpa, pane, generation, .shown, clean);
}

/// One result, whatever it says. `text` is copied; on `.failed` it is
/// the reason, on `.shown` the completion, and empty otherwise.
fn postOutcome(events: *event.EventQueue, io: Io, gpa: Allocator, pane: u32, generation: u32, outcome: event.SuggestOutcome, text: []const u8) void {
    const owned = gpa.dupe(u8, text) catch return;
    events.post(io, .{ .ai = .{ .job = 0, .msg = .{ .suggestion = .{
        .pane = pane,
        .generation = generation,
        .text = owned,
        .outcome = outcome,
    } } } });
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
            // A result for a buffer that has moved on is still worth
            // one line: the latency it cost is real, and the outcome
            // tells the reader whether the backend answers at all.
            const wanted = st.debounce.settle(s.generation);
            switch (s.outcome) {
                .empty => return ghost_chip.settle(app, .empty, 0, null),
                .timed_out => return ghost_chip.settle(app, .timeout, 0, null),
                .failed => return ghost_chip.settle(app, .failed, 0, s.text),
                .shown => {},
            }
            if (!wanted or st.suggest_pane != @as(PaneId, s.pane)) return;
            const e = app.panes.editor(s.pane) orelse return;
            if (s.text.len == 0) return;
            // Asked for one spot, answered after the cursor left it
            // without an edit (a motion, a click): it would land in the
            // wrong place, so it does not land at all.
            if (!atRequestedSpot(app, e)) return ghost_chip.settle(app, .stale, 0, null);
            try e.buf.editor.setGhostSuggestion(s.text);
            st.shown +|= 1;
            st.current_accepted = false;
            try ghost_chip.settle(app, .shown, s.text.len, null);
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
        .timed_out => |why| {
            // Said out loud: the pane may be in a hidden tab, and a job
            // that stalled for minutes is not one the user is watching.
            const p = paneOfJob(app, job_id);
            app.toast("{s}: {s}", .{ if (p) |ap| ap.title else "ai", why });
            return handle(app, job_id, .{ .failed = why });
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
        .cancel = &j.cancel,
    };
    errdefer gpa.free(pane.title);
    pane.prompt = try gpa.dupe(u8, prompt);
    errdefer gpa.free(pane.prompt);
    if (apply) |an| if (app.panes.editor(an.pane)) |e| {
        const bytes = e.buf.editor.bytes();
        if (an.start <= an.end and an.end <= bytes.len) pane.apply_original = try gpa.dupe(u8, bytes[an.start..an.end]);
    };
    errdefer if (pane.apply_original) |o| gpa.free(o);

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
    app.ai.group.concurrent(app.io, jobWorker, .{ app.events, app.io, gpa, j, mode, prompt_owned, pane.session_id, model, key_owned, cwd, &app.env, system, use_tools, write_tools, max_tokens, app.cfg.ai.cli_timeout_ms }) catch {
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
///
/// The CLI child belongs to the job (`cli.runJob`): the job's cancel
/// flag — set by `c`, by closing the pane, by a re-ask — kills and
/// reaps it within a poll, and so does `[ai] cli_timeout_ms`. Every AI
/// feature that runs a one-shot rides this path: the ai.* actions,
/// the commit and branch drafts, `git.explain_branch`, the PR text.
fn jobWorker(events: *event.EventQueue, io: Io, gpa: Allocator, j: *Job, mode: JobMode, prompt: []u8, session_id: [36]u8, model: []u8, key: []u8, cwd: []u8, env: *const std.process.Environ.Map, system: ?[]u8, use_tools: bool, write_tools: bool, max_tokens: u32, timeout_ms: u32) Io.Cancelable!void {
    defer gpa.free(prompt);
    defer gpa.free(model);
    defer gpa.free(key);
    defer gpa.free(cwd);
    defer if (system) |s| gpa.free(s);
    switch (mode) {
        .claude_cli, .codex_cli => {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            // The prompt on stdin, never in argv: argv has an OS cap a
            // whole file can pass, and `ps` shows it to every local user.
            const argv = (if (mode == .claude_cli) cli.claudeStdinArgv(arena.allocator(), &session_id, extraModel(model)) else cli.codexStdinArgv(arena.allocator())) catch return;
            const binary = if (mode == .claude_cli) cli.claude_binary else cli.codex_binary;
            const out = cli.runJob(gpa, io, argv, cwd, env, .{ .timeout_ms = timeout_ms, .cancel = &j.cancel, .stdin = prompt }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Aborted => {
                    postFailed(events, io, gpa, j.id, "cancelled");
                    return;
                },
                error.TimedOut => {
                    const why = std.fmt.allocPrint(gpa, "`{s}` gave no answer within {d} s and was stopped ([ai] cli_timeout_ms)", .{ binary, std.math.divCeil(u32, timeout_ms, 1000) catch 0 }) catch return;
                    events.post(io, .{ .ai = .{ .job = j.id, .msg = .{ .timed_out = why } } });
                    return;
                },
                else => |e| {
                    const why = std.fmt.allocPrint(gpa, "`{s}` failed: {s}", .{ binary, @errorName(e) }) catch return;
                    events.post(io, .{ .ai = .{ .job = j.id, .msg = .{ .failed = why } } });
                    return;
                },
            };
            if (out.spawn_failed) {
                defer gpa.free(out.text);
                postFailed(events, io, gpa, j.id, spawnFailure(arena.allocator(), binary, out.text));
                return;
            }
            // Text to paint, not a terminal stream: escapes dropped whole.
            const clean = blk: {
                defer gpa.free(out.text);
                break :blk cli.cleanOutput(gpa, out.text) catch return;
            };
            if (!out.ok) {
                events.post(io, .{ .ai = .{ .job = j.id, .msg = .{ .failed = clean } } });
                return;
            }
            events.post(io, .{ .ai = .{ .job = j.id, .msg = .{ .text = clean } } });
            events.post(io, .{ .ai = .{ .job = j.id, .msg = .done } });
        },
        .claude_api => try agentLoop(events, io, gpa, j, prompt, model, key, cwd, env, system, use_tools, write_tools, max_tokens, timeout_ms),
    }
}

/// Why a CLI could not be started, in the OS's words. Only a binary that
/// is not there is worth a guess at the cause; anything else is said as
/// it is, never folded into "is it installed?" — a CLI that is installed
/// and signed in must not send its user off to reinstall it.
pub fn spawnFailure(arena: Allocator, binary: []const u8, err_name: []const u8) []const u8 {
    if (std.mem.eql(u8, err_name, "FileNotFound"))
        return std.fmt.allocPrint(arena, "`{s}` could not be started (FileNotFound) — is it installed and on PATH?", .{binary}) catch "the CLI could not be started";
    return std.fmt.allocPrint(arena, "`{s}` could not be started: {s}", .{ binary, err_name }) catch "the CLI could not be started";
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
///
/// Each request is watched (`postWatched`): the job's cancel flag and
/// `[ai] cli_timeout_ms` end it mid-flight, so a server that stalls —
/// or answers its head and never its body — cannot hold the job.
fn agentLoop(events: *event.EventQueue, io: Io, gpa: Allocator, j: *Job, prompt: []const u8, model: []const u8, key: []const u8, cwd: []const u8, env: *const std.process.Environ.Map, system: ?[]const u8, use_tools: bool, write_tools: bool, max_tokens: u32, timeout_ms: u32) Io.Cancelable!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const url = api.endpointFor(arena, env) catch return;
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
        const res = postWatched(gpa, io, url, key, body, &j.cancel, timeout_ms) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Aborted => {
                postFailed(events, io, gpa, j.id, "cancelled");
                return;
            },
            error.TimedOut => {
                const why = std.fmt.allocPrint(gpa, "the API gave no answer within {d} s and the request was stopped ([ai] cli_timeout_ms)", .{std.math.divCeil(u32, timeout_ms, 1000) catch 0}) catch return;
                events.post(io, .{ .ai = .{ .job = j.id, .msg = .{ .timed_out = why } } });
                return;
            },
            else => {
                postFailed(events, io, gpa, j.id, "the request failed (network / TLS)");
                return;
            },
        };
        defer gpa.free(res.body);
        if (res.status != 200) {
            events.post(io, .{ .ai = .{ .job = j.id, .msg = .{ .failed = httpFailure(gpa, arena, res) catch return } } });
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

/// What a non-200 answer says in the pane: the status, the API's own
/// message, and — on a 429 / 529 that names one — when to try again.
/// Owned by `gpa`.
fn httpFailure(gpa: Allocator, arena: Allocator, res: api.Response) Allocator.Error![]u8 {
    const why = api.errorMessage(arena, res.body) orelse "";
    const sep: []const u8 = if (why.len > 0) " " else "";
    if (res.retry_after_s) |s| return std.fmt.allocPrint(gpa, "HTTP {d}{s}{s} — retry after {d} s", .{ res.status, sep, why, s });
    return std.fmt.allocPrint(gpa, "HTTP {d}{s}{s}", .{ res.status, sep, why });
}

const Stop = enum { aborted, timed_out };
const Watched = union(enum) {
    post: api.PostError!api.Response,
    watch: Io.Cancelable!Stop,
};

/// The flag and the clock, looked at every 100 ms.
fn watchJob(io: Io, cancel: *const std.atomic.Value(bool), timeout_ms: u32) Io.Cancelable!Stop {
    const t0 = Io.Timestamp.now(io, .awake);
    while (true) {
        if (cancel.load(.acquire)) return .aborted;
        if (t0.untilNow(io, .awake).toMilliseconds() >= timeout_ms) return .timed_out;
        try io.sleep(.fromMilliseconds(100), .awake);
    }
}

/// `api.post`, raced against the job's cancel flag and its budget: the
/// first to finish wins and the other is cancelled. A request cut off
/// mid-flight is `Aborted` / `TimedOut`; a response that lands while
/// the loser is being stopped is freed, not leaked.
fn postWatched(gpa: Allocator, io: Io, url: []const u8, key: []const u8, body: []const u8, cancel: *const std.atomic.Value(bool), timeout_ms: u32) (api.PostError || error{ Aborted, TimedOut })!api.Response {
    var buf: [2]Watched = undefined;
    var sel = Io.Select(Watched).init(io, &buf);
    sel.concurrent(.post, api.post, .{ gpa, io, url, key, body }) catch return api.post(gpa, io, url, key, body);
    sel.concurrent(.watch, watchJob, .{ io, cancel, timeout_ms }) catch {
        // No task for the watcher: the request runs unwatched.
        const first = sel.await() catch |err| {
            drainWatched(gpa, &sel);
            return err;
        };
        drainWatched(gpa, &sel);
        return first.post;
    };
    const first = sel.await() catch |err| {
        drainWatched(gpa, &sel);
        return err;
    };
    drainWatched(gpa, &sel);
    return switch (first) {
        .post => |r| r,
        .watch => |w| switch (w catch return error.Canceled) {
            .aborted => error.Aborted,
            .timed_out => error.TimedOut,
        },
    };
}

/// Cancel what is left of a `postWatched` race and free any response it
/// produced on the way out.
fn drainWatched(gpa: Allocator, sel: *Io.Select(Watched)) void {
    while (sel.cancel()) |rest| switch (rest) {
        .post => |r| if (r) |res| gpa.free(res.body) else |_| {},
        .watch => {},
    };
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
        if (suggest.isSecretBearing(rel)) return fail.f(arena, "read_file {s}: refused — it looks like it holds secrets, and those are never sent", .{rel});
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
        const detail = std.fmt.allocPrint(gpa, "write {s} ({d} bytes)?", .{ rel, content.len }) catch return fail.f(arena, "write_file: out of memory", .{});
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
        // A secret-bearing file's lines are never sent, matched or not.
        if (suggest.isSecretBearing(entry.basename)) continue;
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
    const active = app.activeEditor();
    if (active) |e| if (e.buf.doc.path) |p| if (suggest.isSecretBearing(p)) {
        // The question still goes; the file never does (the one
        // never-send list, `suggest.isSecretBearing`).
        app.toast("ai.chat: {s} not attached — it looks like it holds secrets; the question went alone", .{app.relPath(p)});
    };
    if (active) |e| if (e.buf.doc.path == null or !suggest.isSecretBearing(e.buf.doc.path.?)) {
        const path = if (e.buf.doc.path) |p| app.relPath(p) else "[scratch]";
        const lang = suggest.languageOf(e.buf.doc.path);
        if (e.buf.editor.selection()) |sel| if (sel[1] > sel[0]) {
            try prompt.print(arena, "Selection from {s}:\n\n```{s}\n{s}\n```\n\n", .{ path, lang, e.buf.editor.bytes()[sel[0]..sel[1]] });
        };
        if (prompt.items.len == 0) {
            const body = e.buf.editor.bytes();
            try prompt.print(arena, "File {s}:\n\n```{s}\n{s}\n```\n\n", .{ path, lang, body[0..@min(body.len, 12_000)] });
        }
    };
    try prompt.appendSlice(arena, q);
    _ = try ask(app, "ai: chat", prompt.items, .chat, null);
}

/// The selection, or the whole file, of the active editor.
fn actionTarget(app: *App) CommandError!struct { code: []const u8, lang: []const u8, apply: AiPane.ApplyTarget } {
    const id = app.active orelse return error.NoActivePane;
    const e = app.panes.editor(id) orelse return error.NotAnEditor;
    if (e.buf.doc.path) |p| if (suggest.isSecretBearing(p))
        return app.diag.fail(app.frame.allocator(), "ai: {s} not sent — it looks like it holds secrets", .{app.relPath(p)});
    const ed = e.buf.editor;
    const lang = suggest.languageOf(e.buf.doc.path);
    if (ed.selection()) |sel| if (sel[1] > sel[0]) {
        return .{ .code = try app.frame.allocator().dupe(u8, ed.bytes()[sel[0]..sel[1]]), .lang = lang, .apply = .take(id, e.buf.doc, sel[0], sel[1]) };
    };
    if (ed.len() == 0) return error.NoSelection;
    return .{ .code = try app.frame.allocator().dupe(u8, ed.bytes()), .lang = lang, .apply = .take(id, e.buf.doc, 0, ed.len()) };
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
        break :blk AiPane.ApplyTarget.take(id, e.buf.doc, sel[0], sel[1]);
    };
    // The block's own trailing newline is part of the proposal; the
    // fence's is not.
    const proposal = try std.fmt.allocPrint(arena, "{s}\n", .{code});
    _ = try ai_apply.open(app, source, target, p.apply_original, proposal);
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
/// every new session on the active leaf's strip; the default is the
/// grid for Claude (`ai_grid.zig`: side by side, then 2×2, 3×2, 4×2,
/// a new page past eight) and a split to the right for Codex. A named
/// placement is that placement. Null: the profile starts its sessions
/// in a worktree, and the name prompt opened instead
/// (`session_worktree.zig`).
fn openSession(app: *App, product: Product, placement: ?pty_pane.Placement) CommandError!?PaneId {
    if (route(app, if (product == .claude) .claude else .codex) == .off) return app.diag.fail(app.frame.allocator(), "{s} is routed off in [ai.routing]", .{@tagName(product)});
    showSessionsSection(app);
    if (placement == null and product == .claude and !tabsMode(app)) return ai_grid.open(app);
    const where: pty_pane.Placement = placement orelse (if (tabsMode(app)) .tab else .right);
    return launch_profiles.openSessionWith(app, product, launch_profiles.defaultName(app, product), where);
}

/// `ui.auto_show_sessions_on_ai_activate`: a new session shows the
/// SESSIONS section — where AI panes are listed — in its column; the
/// keys stay with the pane about to open.
fn showSessionsSection(app: *App) void {
    if (!app.cfg.ui.auto_show_sessions_on_ai_activate) return;
    activity_bar.enter(app, .sessions);
    side.place(app, .sessions, false);
}

/// `ui.ai_layout_mode = .tabs`; the `[ai] layout_mode` extra still
/// overrides the typed field.
pub fn tabsMode(app: *App) bool {
    if (extraString(app, "layout_mode")) |m| return std.ascii.eqlIgnoreCase(m, "tabs");
    return app.cfg.ui.ai_layout_mode == .tabs;
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

/// The tab strip's cluster chip for `product`, left click. The chip is
/// the way to the sessions, not a second launcher beside the panel's:
/// the SESSIONS section comes up either way, and only when nothing of
/// that product is running does the click also start one — the command
/// the panel's own `+ New session` row runs first
/// (`sessions.new_command`), never a copy of it.
///
/// It used to run `ai.claude_code` / `ai.codex` outright, which open a
/// session every time, so a click with one already up opened a second.
pub fn chipClick(app: *App, product: Product) CommandError!void {
    activity_bar.enter(app, .sessions);
    side.place(app, .sessions, true);
    if (findSession(app, product) != null) return;
    // Codex has no `+ New session` menu of its own; its new-session
    // command is the whole of the path.
    return command.run(app, .{ .static = switch (product) {
        .claude => @import("../sessions.zig").new_command,
        .codex => .@"ai.codex_new",
    } });
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

/// `ai.new_session_worktree`: the default profile's session in a
/// worktree of its own — the name prompt first.
fn newSessionWorktree(app: *App) CommandError!void {
    if (route(app, .claude) == .off) return app.diag.fail(app.frame.allocator(), "claude is routed off in [ai.routing]", .{});
    try @import("session_worktree.zig").openNamePrompt(app, .claude, launch_profiles.defaultName(app, .claude));
}

/// N Claude sessions: N tabs in tabs mode, else the grid — with a new
/// page every eight (`ai_grid.openBatch`).
fn openBatch(app: *App, n: usize) CommandError!void {
    if (route(app, .claude) == .off) return app.diag.fail(app.frame.allocator(), "claude is routed off in [ai.routing]", .{});
    showSessionsSection(app);
    if (!tabsMode(app)) return ai_grid.openBatch(app, n);
    var i: usize = 0;
    while (i < n) : (i += 1) _ = (try openSession(app, .claude, .tab)) orelse break;
    app.toast("opened {d} Claude session{s}", .{ n, if (n == 1) "" else "s" });
}

fn claudeCodeNewX2(app: *App) CommandError!void {
    return openBatch(app, 2);
}
fn claudeCodeNewX4(app: *App) CommandError!void {
    return openBatch(app, 4);
}
fn claudeCodeNewX8(app: *App) CommandError!void {
    return openBatch(app, 8);
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

pub const backend_rows = [_]suggest.Backend{ .claude_code, .claude_api, .copilot, .local };

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
        .{ .b = .copilot, .label = "GitHub Copilot", .detail = "your seat (free tier too) · opt in per workspace" },
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
        .copilot => try copilot_app.announcePick(app),
        .local => app.toast("{s}", .{suggest.migration_note}),
        .claude_api => app.toast("AI ghost-text: Claude API{s}", .{if (app.env.get(api.env_key) == null) " — export $ANTHROPIC_API_KEY to use it" else " · on"}),
        .claude_code => app.toast("AI ghost-text: Claude Code sub · on (run `claude` once to sign in)", .{}),
        .unset => {},
    }
}

fn suggestionStats(app: *App) CommandError!void {
    const st = &app.ai;
    // Nothing shown is not nothing to say: a session that asked five
    // times and got five timeouts used to report the same silence as
    // one that never asked.
    if (st.shown == 0 and st.ghost.latency_n == 0) return app.toast("AI ghost-text: no suggestions shown yet this session", .{});
    const line = try ghost_chip.statsLine(app.frame.allocator(), &st.ghost, st.shown, st.accepted);
    app.toast("{s}", .{line});
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

fn notInBuildCmd(app: *App) CommandError!void {
    return app.diag.fail(app.frame.allocator(), "not in this build yet", .{});
}

fn showLastResponse(app: *App) CommandError!void {
    return usage_pane.showLastResponse(app);
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
    const kept = try suggest.withholdSecretDiffs(app.frame.allocator(), diff);
    toastWithheld(app, kept.withheld);
    const prompt = try std.fmt.allocPrint(app.frame.allocator(), "Explain this diff, walking through what changed and why it might have:\n\n```diff\n{s}\n```\n", .{kept.text[0..@min(kept.text.len, 60_000)]});
    _ = try ask(app, "ai: explain diff", prompt, .git, null);
}

/// Say which files a diff going to a model left out, by name.
pub fn toastWithheld(app: *App, withheld: []const []const u8) void {
    if (withheld.len == 0) return;
    if (withheld.len == 1) {
        app.toast("ai: {s} not sent — it looks like it holds secrets", .{withheld[0]});
    } else app.toast("ai: {s} and {d} more not sent — they look like they hold secrets", .{ withheld[0], withheld.len - 1 });
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

/// `ai.link_claude_token`: the token prompt for the account — the one
/// configured, or the one picked from a menu of them. The token lands in
/// that account's own file, the one the reader reads.
fn linkClaudeToken(app: *App) CommandError!void {
    return usage_pane.chooseAccount(app, .link);
}

fn claudeAddAccount(app: *App) CommandError!void {
    return usage_pane.addCmd(app);
}

fn claudeRenameAccount(app: *App) CommandError!void {
    return usage_pane.chooseAccount(app, .rename);
}

fn claudeRemoveAccount(app: *App) CommandError!void {
    return usage_pane.chooseAccount(app, .remove);
}

/// The quota pane: the session and weekly windows per account, off
/// the reader in `src/ai/usage.zig` — the numbers the chip shows.
fn claudeUsage(app: *App) CommandError!void {
    return usage_pane.open(app, .claude);
}

fn codexUsage(app: *App) CommandError!void {
    return usage_pane.open(app, .codex);
}

/// `ai.refresh_usage`: every account and the Codex scan, now.
fn refreshUsage(app: *App) CommandError!void {
    try usage_pane.refreshAll(app);
    app.toast("refreshing usage…", .{});
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
    const gen = app.ai.debounce.fire(app.now_ms);
    app.ai.suggest_pane = id;
    app.ai.debounce.noteEdit(app.now_ms);
    const stale = try t.allocator.dupe(u8, "OLD");
    try app.handle(.{ .ai = .{ .job = 0, .msg = .{ .suggestion = .{ .pane = id, .generation = gen, .text = stale } } } });
    try t.expect(e.buf.editor.ghost_suggestion == null);
    const live_gen = app.ai.debounce.fire(app.now_ms);
    noteRequest(&app, e);
    const live = try t.allocator.dupe(u8, "NEW");
    try app.handle(.{ .ai = .{ .job = 0, .msg = .{ .suggestion = .{ .pane = id, .generation = live_gen, .text = live } } } });
    try t.expectEqualStrings("NEW", e.buf.editor.ghost_suggestion.?);
    try t.expectEqual(@as(u32, 1), app.ai.shown);
    // The cursor moves (no edit): the ghost goes with it rather than
    // riding along to the new spot.
    e.buf.editor.setCursor(0);
    try dropMovedGhost(&app, e);
    try t.expect(e.buf.editor.ghost_suggestion == null);
    // A request whose cursor moved before the answer came: dropped.
    const moved_gen = app.ai.debounce.fire(app.now_ms);
    e.buf.editor.setCursor(1);
    noteRequest(&app, e);
    e.buf.editor.setCursor(0);
    const late = try t.allocator.dupe(u8, "LATE");
    try app.handle(.{ .ai = .{ .job = 0, .msg = .{ .suggestion = .{ .pane = id, .generation = moved_gen, .text = late } } } });
    try t.expect(e.buf.editor.ghost_suggestion == null);
    try t.expect(std.mem.endsWith(u8, lastMessage(&app), "dropped (cursor moved)"));
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
            const detail = a.dupe(u8, "write a.txt (3 bytes)?") catch return;
            events.post(io, .{ .ai = .{ .job = job.id, .msg = .{ .confirm = detail } } });
            answer = job.confirm.getOne(io) catch null;
            events.post(io, .{ .ai = .{ .job = job.id, .msg = .done } });
        }
    };
    Worker.answer = null;
    try app.ai.group.concurrent(app.io, Worker.run, .{ app.events, app.io, gpa, j });
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
    // The Copilot row (third) shares nothing by itself: the toast says
    // what still has to happen, by name.
    try command.run(&app, .{ .static = .@"ai.setup_suggestions" });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqual(suggest.Backend.copilot, suggestBackend(&app));
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "ai.copilot_enable_here") != null);
    // The local row (fourth) toasts the migration note instead of
    // enabling anything.
    try command.run(&app, .{ .static = .@"ai.setup_suggestions" });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings(suggest.migration_note, app.lastToast().?);
}

test "every ai / agents / cloud_agents id has a runner" {
    // The walk over every id is a comptime loop; the default quota is the id count.
    @setEvalBranchQuota(8_000);
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

test "a ghost is Insert's: in vim Normal a Tab drops it and edits nothing; with the : line open too; in Insert it lands" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    const e = app.activeEditor().?;
    try e.buf.editor.setText("banana\n");
    e.buf.editor.setCursor(0);
    // Normal mode: Tab is `buffer.next`'s, the ghost goes.
    try e.buf.editor.setGhostSuggestion("elderberry\nfig\n");
    try app.handle(.{ .key = Key.named(.tab) });
    try t.expectEqualStrings("banana\n", e.buf.editor.bytes());
    try t.expect(e.buf.editor.ghost_suggestion == null);
    // The `:` line open: same.
    try app.handle(.{ .key = Key.char(':') });
    try e.buf.editor.setGhostSuggestion("grape");
    try app.handle(.{ .key = Key.named(.tab) });
    try t.expectEqualStrings("banana\n", e.buf.editor.bytes());
    try t.expect(e.buf.editor.ghost_suggestion == null);
    try app.handle(.{ .key = Key.named(.esc) });
    // Insert: Tab accepts.
    try app.handle(.{ .key = Key.char('i') });
    try e.buf.editor.setGhostSuggestion("apple ");
    try app.handle(.{ .key = Key.named(.tab) });
    try t.expectEqualStrings("apple banana\n", e.buf.editor.bytes());
    // The clock never fires a request outside a typing mode either.
    try app.handle(.{ .key = Key.named(.esc) });
    app.cfg.ai.inline_suggestions = true;
    app.ai.debounce.noteEdit(app.now_ms);
    try app.tick(app.now_ms + 10_000);
    try t.expect(app.ai.debounce.deadline() == null);
}

test "the strip's AI chip: a click shows SESSIONS, and starts a session only when that product has none running" {
    const build_options = @import("build_options");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 120, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    app.tree.loaded = true;
    // `tools/shims/ai/claude` stands in for the CLI (it sleeps).
    const path = try std.fmt.allocPrint(t.allocator, "{s}/ai:{s}", .{ build_options.shims_dir, app.env.get("PATH") orelse "/usr/bin:/bin" });
    defer t.allocator.free(path);
    try app.env.put("PATH", path);

    // Nothing running: the panel comes up and a session starts.
    try t.expect(findSession(&app, .claude) == null);
    try chipClick(&app, .claude);
    try t.expectEqual(side.Section.sessions, side.shown(&app, .left).?);
    const first = findSession(&app, .claude) orelse return error.NoSessionStarted;

    // One already running: the panel again, and no second session —
    // the chip is the way to the sessions, not one more launcher.
    side.place(&app, .explorer, false);
    try chipClick(&app, .claude);
    try t.expectEqual(side.Section.sessions, side.shown(&app, .left).?);
    try t.expectEqual(first, findSession(&app, .claude).?);
    var claudes: usize = 0;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .pty => |*pt| if (pty_pane.productOf(&app, pt) == .claude) {
            claudes += 1;
        },
        else => {},
    };
    try t.expectEqual(@as(usize, 1), claudes);

    // The command a click starts is the panel's own `+ New session`
    // row's, not a copy of it.
    try t.expectEqual(command.CommandId.@"ai.claude_code_new", @import("../sessions.zig").new_command);
}

test "ghost text is observable: the chip paints each phase, every request lands a `:messages` line, status.json says which" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    const id = try app.openScratch();
    const e = app.activeEditor().?;
    app.ai.backend_override = .claude_code;

    const row = struct {
        fn f(a: *App) ![]const u8 {
            try a.render();
            return @import("../ipc/screen.zig").toTestText(a.frame.allocator(), &a.screen);
        }
    }.f;
    const ghost_key = struct {
        fn f(a: *App) ![]const u8 {
            const st = try @import("driver.zig").AppDriver.statusOf(a, a.frame.allocator());
            return @import("../ipc/screen.zig").statusJson(a.frame.allocator(), st);
        }
    }.f;

    // Idle: no chip at all, and nothing to say.
    try t.expect(std.mem.indexOf(u8, try row(&app), ghost_chip_glyph) == null);
    try t.expect(std.mem.indexOf(u8, try ghost_key(&app), "\"ghost\":\"idle\"") != null);

    // Typing arms the clock: `…`.
    try app.handle(.{ .key = Key.char('x') });
    try t.expectEqual(ghost_chip.Phase.armed, ghost_chip.phase(&app));
    try t.expect(std.mem.indexOf(u8, try row(&app), ghost_chip_glyph ++ " \u{2026} ") != null);
    try t.expect(std.mem.indexOf(u8, try ghost_key(&app), "\"ghost\":\"armed\"") != null);

    // In flight: the app's spinner and the elapsed, and a frame due
    // soon so the spinner actually turns.
    app.ai.debounce.dirty_ms = app.now_ms - 400;
    try app.tick(app.now_ms);
    try t.expect(app.ai.debounce.in_flight != null);
    const gen = app.ai.debounce.in_flight.?;
    app.now_ms += 1800;
    try t.expectEqual(ghost_chip.Phase.inflight, ghost_chip.phase(&app));
    try t.expect(std.mem.indexOf(u8, try row(&app), "1.8s") != null);
    try t.expect(std.mem.indexOf(u8, try ghost_key(&app), "\"ghost\":\"inflight\"") != null);
    try t.expect(nextDeadlineMs(&app).? <= app.now_ms + 100);

    // A suggestion lands: the ghost text IS the state, so no chip —
    // and the line says how long it took and how much came back.
    const text = try t.allocator.dupe(u8, "alpha beta");
    try app.handle(.{ .ai = .{ .job = 0, .msg = .{ .suggestion = .{ .pane = id, .generation = gen, .text = text } } } });
    try t.expectEqualStrings("alpha beta", e.buf.editor.ghost_suggestion.?);
    try t.expectEqual(ghost_chip.Phase.shown, ghost_chip.phase(&app));
    try t.expect(std.mem.indexOf(u8, try row(&app), ghost_chip_glyph) == null);
    try t.expect(std.mem.indexOf(u8, try ghost_key(&app), "\"ghost\":\"shown\"") != null);
    try t.expectEqualStrings("ghost-text: claude-code · 1.8s · 10 chars", lastMessage(&app));
    // Recorded, never toasted: one toast per keystroke-pause would be
    // the opposite of the quiet the feature is for.
    try t.expect(app.toasts.items.len == 0);

    // An empty answer: `∅`, for two seconds and no longer.
    try e.buf.editor.setGhostSuggestion(null);
    app.ai.debounce.fired_ms = app.now_ms - 900;
    const nothing = try t.allocator.dupe(u8, "");
    try app.handle(.{ .ai = .{ .job = 0, .msg = .{ .suggestion = .{ .pane = id, .generation = gen, .text = nothing, .outcome = .empty } } } });
    try t.expectEqualStrings("ghost-text: claude-code · 0.9s · empty", lastMessage(&app));
    try t.expect(std.mem.indexOf(u8, try row(&app), ghost_chip_glyph ++ " \u{2205} ") != null);
    try t.expect(std.mem.indexOf(u8, try ghost_key(&app), "\"ghost\":\"empty\"") != null);
    app.now_ms += ghost_chip.empty_hold_ms;
    try t.expect(std.mem.indexOf(u8, try ghost_key(&app), "\"ghost\":\"idle\"") != null);

    // A timeout: `!`, and the reason is in the log rather than nowhere.
    app.ai.debounce.fired_ms = app.now_ms - 4000;
    const nil2 = try t.allocator.dupe(u8, "");
    try app.handle(.{ .ai = .{ .job = 0, .msg = .{ .suggestion = .{ .pane = id, .generation = gen, .text = nil2, .outcome = .timed_out } } } });
    try t.expectEqualStrings("ghost-text: claude-code · 4.0s · timeout", lastMessage(&app));
    try t.expect(std.mem.indexOf(u8, try row(&app), ghost_chip_glyph ++ " ! ") != null);
    try t.expect(std.mem.indexOf(u8, try ghost_key(&app), "\"ghost\":\"error\"") != null);

    // A failure carries its words, once — the worker's own prefix does
    // not read twice.
    app.ai.debounce.fired_ms = app.now_ms - 1200;
    const why = try t.allocator.dupe(u8, "claude -p: not signed in");
    try app.handle(.{ .ai = .{ .job = 0, .msg = .{ .suggestion = .{ .pane = id, .generation = gen, .text = why, .outcome = .failed } } } });
    try t.expectEqualStrings("ghost-text: claude-code · 1.2s · error: claude -p: not signed in", lastMessage(&app));

    // The stats grow with the mean and the last five outcomes.
    try command.run(&app, .{ .static = .@"ai.suggestion_stats" });
    const stats = app.toasts.items[app.toasts.items.len - 1].text;
    try t.expect(std.mem.indexOf(u8, stats, "mean ") != null);
    try t.expect(std.mem.indexOf(u8, stats, "last: ok, empty, timeout, error") != null);
}

const ghost_chip_glyph = @import("../ui/statusline.zig").ghost_glyph;

fn lastMessage(app: *App) []const u8 {
    const items = app.messages.items.items;
    return if (items.len == 0) "" else items[items.len - 1].text;
}

test "ghost text: typing through a request kills the claude child, not just our interest in its answer" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 80, .rows = 10 });
    defer app.deinit();
    // A worker on the ghost group, blocked in a child that sleeps far
    // longer than any test would wait for.
    const Probe = struct {
        fn run(io: Io, gpa: Allocator) Io.Cancelable!void {
            const out = cli.run(gpa, io, &.{ "/bin/sh", "-c", "sleep 30" }, "/tmp", null) catch |e| switch (e) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            gpa.free(out.text);
        }
    };
    app.ai.backend_override = .claude_code;
    try app.ai.suggest_group.concurrent(app.io, Probe.run, .{ app.io, t.allocator });
    app.ai.debounce.dirty_ms = null;
    _ = app.ai.debounce.fire(app.now_ms);
    app.now_ms += 400;

    const t0 = Io.Timestamp.now(app.io, .awake);
    noteEdit(&app); // the user types
    const elapsed = t0.untilNow(app.io, .awake).toMilliseconds();
    // The group is DRAINED, not merely ignored: a null token is
    // `Io.Group`'s own word for "no pending tasks", and the task only
    // ends when `std.process.run` unwinds through `defer child.kill`.
    // Clearing the generation — which `Debounce.noteEdit` does anyway —
    // proves nothing about the process; this does.
    try t.expect(app.ai.suggest_group.token.load(.acquire) == null);
    // And it came back at once rather than waiting out the child's 30 s.
    try t.expect(elapsed < 5_000);
    try t.expect(app.ai.debounce.in_flight == null);
    try t.expectEqualStrings("ghost-text: claude-code · 0.4s · cancelled (typed)", lastMessage(&app));
}

test "an AI job's CLI child past [ai] cli_timeout_ms is killed and reaped, the pane says why and a toast names the key" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(t.io, &buf)];
    // A `claude` that writes its pid and never answers.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "claude", .data = "#!/bin/sh\necho $$ > pid\nexec /bin/sleep 30\n" });
    try tmp.dir.setFilePermissions(t.io, "claude", .fromMode(0o755), .{});

    var app = try App.initWith(t.allocator, t.io, .{ .workspace = dir, .cols = 100, .rows = 30 });
    defer app.deinit();
    try app.env.put("PATH", dir);
    app.cfg.ai.routing.claude.backend = .sub;
    // Below the clamp on purpose: the test is about the kill, not the wait.
    app.cfg.ai.cli_timeout_ms = 1500;
    const id = try ask(&app, "ai: ask", "hello", .ask, null);
    const p = &app.panes.get(id).?.ai;
    const Ctx = struct {
        fn failed(ap: *AiPane) bool {
            return ap.status == .failed;
        }
    };
    var spent: u32 = 0;
    while (!Ctx.failed(p)) : (spent += 10) {
        if (spent > 8_000) return error.Timeout;
        try t.io.sleep(.fromMilliseconds(10), .awake);
        try app.tick(App.nowMs(app.io));
    }
    try t.expect(std.mem.indexOf(u8, p.err.?, "cli_timeout_ms") != null);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "cli_timeout_ms") != null);
    const pid_text = try tmp.dir.readFileAlloc(t.io, "pid", t.allocator, .limited(64));
    defer t.allocator.free(pid_text);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_text, " \n"), 10);
    try t.expectError(error.ProcessNotFound, std.posix.kill(pid, @enumFromInt(0)));
}

test "the API agent's read_file refuses a secret-bearing file, and grep never reads one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".env", .data = "DB_PASSWORD=hunter2-fake-value\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "config.txt", .data = "DB_PASSWORD is read from the env\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = dir, .cols = 80, .rows = 10 });
    defer app.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var j: Job = .{ .id = 1, .confirm = undefined };
    j.confirm = .init(&j.confirm_buf);
    const read_in = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\".env\"}", .{});
    const r = try executeTool(arena, t.io, t.allocator, app.events, &j, dir, "read_file", read_in, false);
    try t.expect(r.is_error);
    try t.expect(std.mem.indexOf(u8, r.text, "hunter2") == null);
    try t.expect(std.mem.indexOf(u8, r.text, "refused") != null);
    const grep_in = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"pattern\":\"DB_PASSWORD\"}", .{});
    const g = try executeTool(arena, t.io, t.allocator, app.events, &j, dir, "grep", grep_in, false);
    try t.expect(std.mem.indexOf(u8, g.text, "config.txt") != null);
    try t.expect(std.mem.indexOf(u8, g.text, "hunter2") == null);
}

test "the API backend: MNML_ANTHROPIC_BASE_URL points it at a mock; a server that never finishes is cut off by the budget" {
    // A server that answers the head and never the body.
    const Stall = struct {
        fn serve(io: Io, server: *Io.net.Server) Io.Cancelable!void {
            const stream = server.accept(io) catch return;
            defer stream.close(io);
            var rbuf: [16 * 1024]u8 = undefined;
            var reader = stream.reader(io, &rbuf);
            // The request head; the body is not read.
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                if (line.len <= 2) break;
            }
            var wbuf: [256]u8 = undefined;
            var writer = stream.writer(io, &wbuf);
            writer.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 1000\r\n\r\n{") catch return;
            writer.interface.flush() catch return;
            try io.sleep(.fromSeconds(30), .awake);
        }
    };
    const io = t.io;
    var addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Stall.serve, .{ io, &server });

    var app = try App.initWith(t.allocator, io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    const base = try std.fmt.allocPrint(t.allocator, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    defer t.allocator.free(base);
    try app.env.put(api.base_url_env, base);
    try app.env.put(api.env_key, "fake-key-for-a-mock");
    app.cfg.ai.routing.claude.backend = .api;
    app.cfg.ai.cli_timeout_ms = 1200; // below the clamp: the test is about the cut-off
    const t0 = Io.Timestamp.now(io, .awake);
    const id = try ask(&app, "ai: ask", "hello", .ask, null);
    const p = &app.panes.get(id).?.ai;
    var spent: u32 = 0;
    while (p.status == .running) : (spent += 10) {
        if (spent > 10_000) return error.Timeout;
        try io.sleep(.fromMilliseconds(10), .awake);
        try app.tick(App.nowMs(app.io));
    }
    try t.expect(t0.untilNow(io, .awake).toMilliseconds() < 8_000);
    try t.expect(std.mem.indexOf(u8, p.err.?, "the API gave no answer within 2 s") != null);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "cli_timeout_ms") != null);
}

test "an API failure says its status, the API's words and, on a 429, when to retry" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var body = "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}".*;
    const m429 = try httpFailure(t.allocator, arena.allocator(), .{ .status = 429, .body = &body, .retry_after_s = 7 });
    defer t.allocator.free(m429);
    try t.expectEqualStrings("HTTP 429 slow down — retry after 7 s", m429);
    var junk = "oops".*;
    const m500 = try httpFailure(t.allocator, arena.allocator(), .{ .status = 500, .body = &junk });
    defer t.allocator.free(m500);
    try t.expectEqualStrings("HTTP 500", m500);
}
