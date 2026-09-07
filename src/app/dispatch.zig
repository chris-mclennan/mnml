//! Keys and mouse into the App: overlays first, then the find bar, then
//! the chord chain and the focused editor, with the `AppCommand`s the
//! editor cannot express handled at the bottom of this file.
//!
//! The chord chain is vim's `timeoutlen` machine (Rust `tui/chord.rs`):
//! a bound prefix waits for its next key; a prefix that is also bound on
//! its own fires when the wait runs out (`expireChords`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const command = @import("../core/command.zig");
const keymap = @import("../core/keymap.zig");
const key_mod = @import("../core/key.zig");
const Key = key_mod.Key;
const Chord = key_mod.Chord;
const Mouse = key_mod.Mouse;
const input = @import("../input/mod.zig");
const edit_op = @import("../editor/edit_op.zig");
const EditOp = edit_op.EditOp;
const whichkey = @import("whichkey.zig");
const find_history = @import("find_history.zig");
const auto_refresh = @import("auto_refresh.zig");
const clock_mod = @import("clock.zig");
const coverage = @import("coverage.zig");
const menu_bar = @import("menu_bar.zig");
const activity_bar = @import("activity_bar.zig");
const browser_open = @import("browser_open.zig");
const ex = @import("ex.zig");
const find_mod = @import("find.zig");
const cmd_find = @import("cmd_find.zig");
const cmd_file = @import("cmd_file.zig");
const cmd_tab = @import("cmd_tab.zig");
const macros_store = @import("macros_store.zig");
const marks_store = @import("marks_store.zig");
const cmd_picker = @import("cmd_picker.zig");
const settings_app = @import("settings.zig");
const first_launch = @import("first_launch.zig");
const Prompt = app_mod.Prompt;
const Confirm = app_mod.Confirm;
const Picker = app_mod.Picker;
const FindBar = app_mod.FindBar;
const fuzzy = @import("../ui/fuzzy.zig");
const todos = @import("../todos.zig");
const notes = @import("../notes.zig");
const findings = @import("../findings.zig");
const sessions = @import("../sessions.zig");
const dock = @import("dock.zig");
const snippets = @import("snippets.zig");
const outline = @import("outline.zig");
const md_preview = @import("md_preview.zig");
const cmd_view = @import("cmd_view.zig");
const context_menus = @import("context_menus.zig");
const cheatsheet = @import("cheatsheet.zig");
const script_pane = @import("script_pane.zig");
const render = @import("render.zig");
const statusline_app = @import("statusline.zig");
const layout_mod = @import("layout.zig");
const select = @import("../editor/select.zig");
const scrollbar = @import("../ui/scrollbar.zig");
const statusline = @import("../ui/statusline.zig");
const bufferline = @import("../ui/bufferline.zig");
const cmd_term = @import("cmd_term.zig");
const ai_apply = @import("ai_apply.zig");
const launch_profiles = @import("launch_profiles.zig");
const tests_pane = @import("tests_pane.zig");
const flaky = @import("flaky.zig");
const toast_mod = @import("../ui/toast.zig");
const discovery = @import("discovery.zig");
const help_app = @import("help.zig");
const HelpUi = app_mod.HelpUi;
const image_pane = @import("image_pane.zig");
const tree_mod = @import("tree.zig");
const info_view_app = @import("info_view.zig");
const Rect = @import("../ui/rect.zig");
const pty_pane = @import("pty_pane.zig");
const request_pane = @import("request_pane.zig");
const http_app = @import("http.zig");
const decor = @import("lsp_decor.zig");
const rename_app = @import("lsp_rename.zig");
const http_panel = @import("http_panel.zig");
const ws_pane = @import("ws_pane.zig");
const browser_pane = @import("browser_pane.zig");
const mount_pane = @import("mount_pane.zig");
const integrations = @import("integrations.zig");
const marketplace = @import("marketplace.zig");
const integrations_view = @import("../ui/integrations_view.zig");
const ipc = @import("../ipc/root.zig");
const cmd_browser = @import("cmd_browser.zig");
const cmd_http = @import("cmd_http.zig");
const runners = @import("runners.zig");
const git_app = @import("git.zig");
const git_palette = @import("git_palette.zig");
const ai_app = @import("ai.zig");
const agents = @import("agents.zig");
const spend = @import("spend.zig");
const grep = @import("grep.zig");
const jumplist = @import("jumplist.zig");
const dap = @import("dap.zig");
const lsp = @import("lsp.zig");
const files_pane = @import("files_pane.zig");
const trash = @import("trash.zig");
const ex_verbs = @import("ex_verbs.zig");
const flash = @import("flash.zig");

// ─── keys ───────────────────────────────────────────────────────────────

/// One key. The cursor is snapshotted around it so a big jump lands on
/// the jumplist (`jumplist.afterKey`).
pub fn key(app: *App, k: Key) Allocator.Error!void {
    const before = try jumplist.snapshot(app);
    try keyInner(app, k);
    try jumplist.afterKey(app, before);
}

fn keyInner(app: *App, k: Key) Allocator.Error!void {
    app.needs_render = true;
    switch (app.overlay) {
        .none => {},
        else => return overlayKey(app, k),
    }
    if (app.find_bar != null) return findBarKey(app, k);
    // Armed flash labels take the next key ahead of everything the
    // editor could do with it: a label jumps, Esc disarms, anything
    // else disarms and carries on below.
    if (app.flash != null and flash.interceptKey(app, k)) return;
    // F10 / Alt+<letter> summon a menu-bar menu (`app/menu_bar.zig`).
    if (try menu_bar.interceptKey(app, k)) return;
    // The completion / hover / peek popups take their keys first: an
    // open completion popup owns Tab / Enter ahead of a ghost's Tab. An
    // accept that edited the text leaves any ghost stale — drop it.
    const seq_before: ?u64 = if (app.activeEditor()) |e| e.buf.doc.edits.head() else null;
    if (try lsp.interceptKey(app, k)) {
        if (seq_before) |before| if (app.activeEditor()) |e| {
            if (e.buf.doc.edits.head() != before and e.buf.editor.ghost_suggestion != null) try e.buf.editor.setGhostSuggestion(null);
        };
        return;
    }
    if (app.focus == .tree and app.tree.visible) {
        if (try app.tree.handleKey(app, k)) return;
        _ = try chordChain(app, k);
        return;
    }
    if (app.focus == .panel and (app.right_panel != null or (app.focus.panel == .git and app.git_palette.active))) {
        const took = switch (app.focus.panel) {
            .todos => try todos.handleKey(app, k),
            .notes => try notes.handleKey(app, k),
            .findings => try findings.handleKey(app, k),
            .git => try git_palette.handleKey(app, k),
            .diagnostics => try lsp.panelKey(app, k),
            .http => try http_panel.handleKey(app, k),
            .sessions => try sessions.handleKey(app, k),
        };
        if (took) return;
        _ = try chordChain(app, k);
        return;
    }

    const pane_id = app.active;
    // The non-editor panes take their own keys first.
    if (pane_id) |id| if (app.panes.get(id)) |p| switch (p.*) {
        .pty => |*term| return ptyKey(app, id, term, k),
        .outline => {
            if (try outline.handleKey(app, id, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .md_preview => {
            if (try md_preview.handleKey(app, id, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .cheatsheet => |*c| {
            if (try cheatsheet.handleKey(app, c, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .script => |*s| {
            if (try script_pane.handleKey(app, s, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .list => |*l| {
            if (try listPaneKey(app, id, l, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .git_status => |*s| {
            if (try git_app.statusPaneKey(app, id, s, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .diff => |*d| {
            if (try git_app.diffKey(app, id, d, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .git_graph => |*g| {
            if (try git_app.graphKey(app, id, g, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .ai => |*a| {
            if (try ai_app.paneKey(app, id, a, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .claude_agents => |*a| {
            if (try agents.handleKey(app, id, a, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .spend_report => |*s| {
            if (try spend.handleKey(app, id, s, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .grep => |*g| {
            if (try grep.handleKey(app, id, g, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .debug => |*d| {
            if (try dap.debugKey(app, id, d, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .dap_repl => |*r| {
            if (try dap.replKey(app, id, r, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .request => |*rp| {
            if (try request_pane.handleKey(app, id, rp, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .websocket => |*w| {
            if (try ws_pane.handleKey(app, id, w, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .browser => |*b| {
            if (try browser_pane.handleKey(app, id, b, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .mount => |*mp| {
            if (try mount_pane.handleKey(app, id, mp, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .integrations => |*ip| {
            if (try integrations.handleKey(app, id, ip, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .ai_apply => |*ap| {
            if (try ai_apply.handleKey(app, id, ap, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .tests => |*tp| {
            if (try tests_pane.handleKey(app, id, tp, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .flaky => |*fp| {
            if (try flaky.handleKey(app, id, fp, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .marketplace => |*mk| {
            if (try marketplace.handleKey(app, id, mk, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .files => |*f| {
            if (try files_pane.handleKey(app, id, f, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .image => |*im| {
            if (try image_pane.handleKey(app, id, im, k)) return;
            _ = try chordChain(app, k);
            return;
        },
        .editor => {},
    };
    // A ghost suggestion owns Tab / ctrl+→ / ctrl+↓ ahead of the chord
    // chain; any other key dismisses it and goes on as usual.
    if (pane_id) |id| if (app.panes.editor(id)) |e| if (e.buf.editor.ghost_suggestion != null) {
        if (try ai_app.interceptKey(app, e, k)) return;
    };
    const ed: ?*EditorPane = if (pane_id) |id| app.panes.editor(id) else null;
    const mode: input.EditingMode = if (ed) |e| e.buf.input.mode() else .none;
    const cmdline_open = if (ed) |e| e.buf.input.isCmdlineOpen() else false;
    const op_pending = if (ed) |e| e.buf.input.isOpPending() else false;
    const modal = mode == .normal or mode.isVisual();
    const bare_space = k.code == .char and k.code.char == ' ' and k.mods.eql(.{});
    const typing_mode = mode == .insert or mode == .replace;
    const plain = !k.mods.ctrl and !k.mods.alt and !k.mods.super;
    // The chord chain is skipped when the editor owns the key outright:
    // the `:` line takes everything; bare space is text unless vim is
    // modal with nothing pending; a typing mode keeps every unmodified
    // key; and in vim's modal states every plain key is a vim key —
    // `g`, `d`, `z`… are the handler's prefixes, never chord prefixes
    // (the keymap's `g d` is the same command the handler emits).
    // A pending chord owns the next key outright: `space` is armed, so
    // the `e` of `<leader>e` is the chain's, not the end-of-word motion
    // (the same rule `ptyKey` applies).
    const editor_first = app.chord.len == 0 and ed != null and (cmdline_open or (bare_space and (!modal or op_pending)) or (typing_mode and plain) or (op_pending and plain) or (modal and plain and !bare_space));
    if (!editor_first and app.chord.len == 0 and ed == null) {
        // No pane: only chords do anything.
        _ = try chordChain(app, k);
        return;
    }
    if (!editor_first) {
        if (try chordChain(app, k)) return;
    }
    const e = ed orelse return;
    if (try snippets.interceptKey(app, pane_id.?, e, k)) return;
    const consumed = try feedEditor(app, pane_id.?, e, k);
    if (!consumed and editor_first) _ = try chordChain(app, k);
}

/// The list panes: j/k move, enter acts, esc closes the pane.
fn listPaneKey(app: *App, id: PaneId, l: *app_mod.ListPane, k: Key) Allocator.Error!bool {
    const n = l.entries.items.len;
    switch (k.code) {
        .down => l.cursor = @min(l.cursor + 1, n -| 1),
        .up => l.cursor -|= 1,
        .home => l.cursor = 0,
        .end => l.cursor = n -| 1,
        .enter => try listPaneEnter(app, id, l),
        .esc => try app.forceClosePane(id),
        .char => |c| switch (c) {
            'j' => l.cursor = @min(l.cursor + 1, n -| 1),
            'k' => l.cursor -|= 1,
            'g' => l.cursor = 0,
            'G' => l.cursor = n -| 1,
            'q' => try app.forceClosePane(id),
            else => return false,
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// A focused pty pane takes every plain key (Esc included — terminal
/// programs need it; the app's chords are the way out). A modified
/// chord goes to the chord chain first when the keymap binds it, except
/// the ones a terminal owns outright (`pty_pane.childOwned`). An exited
/// pane closes on any plain key.
fn ptyKey(app: *App, id: PaneId, p: *pty_pane.PtyPane, k: Key) Allocator.Error!void {
    if (app.chord.len > 0) {
        _ = try chordChain(app, k);
        return;
    }
    const modified = k.mods.ctrl or k.mods.alt or k.mods.super;
    if (p.exit != null) {
        if (modified and try chordChain(app, k)) return;
        try app.forceClosePane(id);
        return;
    }
    if (modified and !pty_pane.childOwned(k)) {
        const bound = app.keymap.resolveSeq(&.{Chord.of(k)}) != .none;
        if (bound and try chordChain(app, k)) return;
    }
    pty_pane.feedKey(app, p, k);
}

/// Feed one key to the editor and act on what it reports. Returns
/// false when the editor did not want the key.
fn feedEditor(app: *App, pane_id: PaneId, e: *EditorPane, k: Key) Allocator.Error!bool {
    const arena = app.frame.allocator();
    const before_mode = e.buf.input.mode();
    const mark = markPrefix(e);
    const mark_key: ?u8 = if (k.typed()) |c| (if (c < 128 and std.ascii.isAlphabetic(@intCast(c))) @as(u8, @intCast(c)) else null) else null;
    const had_mark: bool = if (mark != null and mark_key != null) e.buf.doc.marks.contains(mark_key.?) else false;
    const trigger = before_mode == .insert and isAbbrevTrigger(k);
    const was_recording = e.buf.isRecording();
    const wrap_width: ?usize = if (e.wrap orelse app.cfg.ui.wrap) app.pane_cols else null;
    cmd_find.seedCtxMatches(e);
    app.attachSeams(e);

    const ev = try e.buf.feedKey(k, &app.clipboard, app.pane_rows, wrap_width, arena);
    if (e.buf.last_unsupported) |name| {
        app.toast("{s}: not supported yet", .{name});
        e.buf.last_unsupported = null;
    }
    switch (ev) {
        .unhandled => return false,
        .noop => {},
        .redraw => {},
        .edited => {
            e.syntax.dirty = true;
            flash.cancel(app);
            snippets.afterEdit(app, pane_id, e);
            ai_app.noteEdit(app);
            if (trigger) try expandAbbreviation(app, e);
            try lsp.onTyped(app, pane_id, e, k);
        },
        .app => |cmd| try handleAppCommand(app, pane_id, e, cmd),
    }
    // An app command may have opened or closed panes (`:e b.txt` grows
    // the store and moves every pane): `e` is stale from here. Look the
    // pane up again, and stop if it is gone.
    const still = app.panes.editor(pane_id) orelse return true;
    // A recording that just stopped is on the clipboard: persist it.
    if (was_recording and !still.buf.isRecording()) macros_store.afterRecording(app);
    // Local marks toast from here: the buffer handles them silently.
    // Global (uppercase) ones toast in `marks_store`, which also knows
    // whether the set was refused.
    if (mark != null and mark_key != null and ev != .unhandled and !marks_store.isGlobal(mark_key.?)) {
        const c = mark_key.?;
        switch (mark.?) {
            .set => app.toast("mark '{c} set", .{c}),
            .jump => if (!had_mark) app.toast("no mark '{c}", .{c}) else {
                const p = still.buf.editor.rowCol();
                app.toast("→ '{c} {d}:{d}", .{ c, p.row + 1, p.col + 1 });
            },
        }
    }
    // The pane mirrors the editor's block anchor for the `I` / `A` / `c`
    // / `r` app commands, which arrive after the handler has already
    // left V-BLOCK.
    const after_mode = still.buf.input.mode();
    if (after_mode == .visual_block and before_mode != .visual_block) still.block_anchor = still.buf.editor.block_anchor orelse still.buf.editor.cursor;
    if (after_mode != .visual_block) still.block_anchor = null;
    try finishDeferredInserts(app);
    return true;
}

const MarkPrefix = enum { set, jump };

fn markPrefix(e: *const EditorPane) ?MarkPrefix {
    return switch (e.buf.input) {
        .vim => |*v| switch (v.prefix) {
            .mark_set => .set,
            .mark_jump_line, .mark_jump_exact => .jump,
            else => null,
        },
        .standard => null,
    };
}

/// Chars that complete the word before them (vim's abbreviation trigger).
fn isAbbrevTrigger(k: Key) bool {
    const c = k.typed() orelse return k.code == .enter or k.code == .tab;
    return switch (c) {
        ' ', '\t', '.', ',', ';', ':', '!', '?', ')', ']', '}', '"', '\'', '`' => true,
        else => false,
    };
}

/// After a trigger char landed in Insert mode: the identifier before it
/// is looked up and replaced by its expansion; the cursor stays after
/// the trigger.
fn expandAbbreviation(app: *App, e: *EditorPane) Allocator.Error!void {
    if (app.abbrevs.count() == 0) return;
    const text = e.buf.editor.bytes();
    const cursor = e.buf.editor.cursor;
    if (cursor < 2 or cursor > text.len) return;
    const trigger_end = cursor - 1;
    var start = trigger_end;
    while (start > 0 and find_mod.isWord(text[start - 1])) start -= 1;
    if (start == trigger_end) return;
    const expansion = app.abbrevs.get(text[start..trigger_end]) orelse return;
    const copy = try app.frame.allocator().dupe(u8, expansion);
    try app.splice(e, start, trigger_end, copy);
    // `replace_range` leaves the cursor at the end of the expansion; the
    // trigger char follows it.
    e.buf.editor.setCursor(@min(start + copy.len + 1, e.buf.editor.len()));
}

// ─── the chord chain ────────────────────────────────────────────────────

fn chordChain(app: *App, k: Key) Allocator.Error!bool {
    const c = Chord.of(k);
    if (app.chord.len >= keymap.max_seq) app.chord.clear(app.gpa);
    app.chord.seq[app.chord.len] = c;
    app.chord.len += 1;
    switch (app.keymap.resolveSeq(app.chord.seq[0..app.chord.len])) {
        .run => |t| {
            app.chord.clear(app.gpa);
            try runTarget(app, t);
            return true;
        },
        .pending_with_fallback => |t| {
            try setFallback(app, t);
            app.chord.deadline_ms = app.now_ms + @as(i64, @intCast(app.cfg.editor.chord_timeout_ms));
            return true;
        },
        .pending => {
            try setFallback(app, null);
            app.chord.deadline_ms = app.now_ms + @as(i64, @intCast(app.cfg.editor.chord_timeout_ms));
            return true;
        },
        .none => {
            const fallback = app.chord.fallback;
            app.chord.fallback = null;
            const was_first = app.chord.len == 1;
            // A leader chain the keymap does not know may still be an
            // entry of the which-key menu itself (`space n`, `space s v`):
            // the popup owns every key under an armed leader, however
            // fast it was typed.
            const menu = if (!was_first and k.code != .esc) leaderLookup(app.chord.seq[0..app.chord.len]) else null;
            app.chord.clear(app.gpa);
            if (menu) |hit| {
                if (fallback) |fb| freeTarget(app, fb);
                try runLeaderHit(app, hit);
                return true;
            }
            // Esc on a pending chord cancels it: no fallback (a leader
            // popup on Esc is the opposite of what was asked), no retry.
            if (!was_first and k.code == .esc) {
                if (fallback) |fb| freeTarget(app, fb);
                return true;
            }
            var fired = false;
            if (fallback) |fb| {
                defer freeTarget(app, fb);
                try runTarget(app, fb);
                fired = true;
            }
            if (was_first) return false;
            // A chain that bottomed out: retry the current key alone —
            // but only a char could start a fresh chain; a navigation
            // key falls through (swallowed when a fallback just fired).
            if (k.code != .char) return fired;
            app.chord.seq[0] = c;
            app.chord.len = 1;
            switch (app.keymap.resolveSeq(app.chord.seq[0..1])) {
                .run => |t| {
                    app.chord.clear(app.gpa);
                    try runTarget(app, t);
                    return true;
                },
                .pending_with_fallback => |t| {
                    try setFallback(app, t);
                    app.chord.deadline_ms = app.now_ms + @as(i64, @intCast(app.cfg.editor.chord_timeout_ms));
                    return true;
                },
                .pending => {
                    app.chord.deadline_ms = app.now_ms + @as(i64, @intCast(app.cfg.editor.chord_timeout_ms));
                    return true;
                },
                .none => {
                    app.chord.clear(app.gpa);
                    return fired;
                },
            }
        },
    }
}

fn setFallback(app: *App, t: ?keymap.Target) Allocator.Error!void {
    if (app.chord.fallback) |old| freeTarget(app, old);
    app.chord.fallback = if (t) |target| switch (target) {
        .static => |id| .{ .static = id },
        .named => |s| .{ .named = try app.gpa.dupe(u8, s) },
    } else null;
}

fn freeTarget(app: *App, t: keymap.Target) void {
    switch (t) {
        .named => |s| app.gpa.free(s),
        .static => {},
    }
}

fn runTarget(app: *App, t: keymap.Target) Allocator.Error!void {
    const result = switch (t) {
        .static => |id| command.run(app, .{ .static = id }),
        .named => |name| command.runNamed(app, name),
    };
    result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {}, // toasted by `command.run`
    };
}

/// A pending chord chain times out: fire its fallback, drop the prefix.
/// A leader chain with no fallback of its own — `space w`, a prefix of
/// `space w K` — resolves to the which-key entry it names, as
/// `timeoutlen` picks the shorter mapping.
pub fn expireChords(app: *App) Allocator.Error!void {
    if (app.chord.deadline_ms == null) return;
    const fallback = app.chord.fallback;
    app.chord.fallback = null;
    const menu = if (fallback == null) leaderLookup(app.chord.seq[0..app.chord.len]) else null;
    app.chord.clear(app.gpa);
    if (fallback) |fb| {
        defer freeTarget(app, fb);
        try runTarget(app, fb);
    } else if (menu) |hit| try runLeaderHit(app, hit);
    app.needs_render = true;
}

const LeaderHit = struct { node: *const whichkey.Node, path: [whichkey.max_depth]u8, len: usize };

/// The which-key node a chord chain names: `seq[0]` the bare leader and
/// every later chord a plain char (shifted letters are the uppercase
/// entries — `space T`).
fn leaderLookup(seq: []const Chord) ?LeaderHit {
    if (seq.len < 2 or seq.len - 1 > whichkey.max_depth) return null;
    if (!seq[0].eql(Chord.of(Key.char(' ')))) return null;
    var hit: LeaderHit = .{ .node = undefined, .path = undefined, .len = seq.len - 1 };
    for (seq[1..], 0..) |c, i| {
        const ch = switch (c.code) {
            .char => |v| v,
            else => return null,
        };
        if (c.mods.ctrl or c.mods.alt or c.mods.super or ch >= 128) return null;
        hit.path[i] = if (c.mods.shift and ch >= 'a' and ch <= 'z') @intCast(ch - ('a' - 'A')) else @intCast(ch);
    }
    hit.node = whichkey.lookup(hit.path[0..hit.len]) orelse return null;
    return hit;
}

/// A leaf runs; a group opens the popup at that path.
fn runLeaderHit(app: *App, hit: LeaderHit) Allocator.Error!void {
    switch (hit.node.*) {
        .cmd => |c| command.run(app, .{ .static = c.id }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .dead => |d| app.toast("{s}: not a command in this build", .{d.id}),
        .group => {
            app.overlay.deinit(app.gpa);
            var state: whichkey.State = .{};
            @memcpy(state.path[0..hit.len], hit.path[0..hit.len]);
            state.len = hit.len;
            app.overlay = .{ .which_key = state };
            app.focus = .overlay;
        },
    }
    app.needs_render = true;
}

// ─── overlays ───────────────────────────────────────────────────────────

fn restoreFocus(app: *App) void {
    app.focus = if (app.active) |a| .{ .pane = a } else .tree;
}

fn closeOverlay(app: *App) void {
    // A confirm that a worker is parked on answers no before it goes.
    ai_app.overlayClosing(app);
    menu_bar.menuClosed(app);
    http_app.overlayClosing(app);
    // Esc on a `:s///c` box keeps what was replaced and stops.
    if (app.overlay == .confirm and app.overlay.confirm.purpose == .replace_confirm) ex_verbs.cancelConfirm(app);
    git_app.overlayClosing(app);
    const back: ?app_mod.FocusId = if (app.overlay == .menu) app.overlay.menu.return_focus else if (app.overlay == .prompt) app.overlay.prompt.return_focus else if (app.overlay == .confirm) app.overlay.confirm.return_focus else null;
    app.overlay.deinit(app.gpa);
    if (back) |f| {
        app.focus = f;
        if (f == .panel and app.right_panel == null) restoreFocus(app);
    } else restoreFocus(app);
}

/// Scroll a leaf's tab strip by one tab: down / `›` hides one more on
/// the left when tabs are hidden on the right, up / `‹` brings one
/// back. The window stays anchored to the current active tab so the
/// next paint does not snap it back.
fn tabStripStep(app: *App, leaf_idx: u32, delta: i8) Allocator.Error!void {
    const lid = (try app.layouts.current().leafAt(app.frame.allocator(), leaf_idx)) orelse return;
    return tabStripStepLid(app, lid, delta);
}

/// Scroll a leaf's strip by one, addressed by its node id (the pane
/// wheel path has the id, not the paint ordinal).
fn tabStripStepLid(app: *App, lid: layout_mod.NodeId, delta: i8) Allocator.Error!void {
    const layout = app.layouts.current();
    const leaf = layout.leaf(lid) orelse return;
    if (delta > 0) {
        if (leaf.strip_hidden_right == 0) return;
        leaf.strip_first += 1;
    } else {
        if (leaf.strip_first == 0) return;
        leaf.strip_first -= 1;
    }
    leaf.strip_anchor = leaf.active;
    app.needs_render = true;
}

/// Enter on a menu row: a parent opens its child, a leaf runs.
fn menuEnter(app: *App, idx: usize) Allocator.Error!void {
    const m = &app.overlay.menu;
    if (idx >= m.items.len) return;
    if (m.items[idx].submenu.len > 0) return context_menus.openSubmenu(app, idx);
    try runMenuAction(app, m.items[idx].action);
}

/// → / l on a menu row: a parent opens its child; in a curatable menu a
/// leaf opens the pin / hide / copy-id list.
fn menuOpenRight(app: *App, idx: usize) Allocator.Error!void {
    const m = &app.overlay.menu;
    if (idx >= m.items.len) return;
    if (m.items[idx].submenu.len > 0) return context_menus.openSubmenu(app, idx);
    if (m.curatable) try context_menus.openCuration(app, idx, m.items[idx]);
}

/// → / l inside a child: in a curatable menu a command row opens its
/// pin / hide / copy-id list; elsewhere it runs the row.
fn subOpenRight(app: *App) Allocator.Error!void {
    const m = &app.overlay.menu;
    const sub = &(m.sub orelse return);
    if (sub.cursor >= sub.items.len) return;
    const item = sub.items[sub.cursor];
    if (m.curatable and item.action == .command and !isCuration(item)) return context_menus.openCuration(app, sub.parent, item);
    try runMenuAction(app, item.action);
}

/// The curation list's own rows must run, not re-open themselves.
fn isCuration(item: command.MenuItem) bool {
    return switch (item.action) {
        .command => |id| id == .@"menu.pin_row" or id == .@"menu.unpin_row" or id == .@"menu.hide_row" or id == .@"menu.copy_id",
        else => false,
    };
}

/// A menu row was chosen: close the menu, then act.
/// Tests reach a menu row's action without a pointer to click.
pub fn runMenuActionForTest(app: *App, action: command.MenuAction) Allocator.Error!void {
    return runMenuAction(app, action);
}

fn runMenuAction(app: *App, action: command.MenuAction) Allocator.Error!void {
    // The `{{VAR}}` a quick-fix menu was opened on rides through the
    // close to the row's command.
    const quick_fix = http_app.takeQuickFix(app);
    closeOverlay(app);
    app.http.quick_fix_var = quick_fix;
    switch (action) {
        .command => |id| command.run(app, .{ .static = id }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .dyn => |slot| command.run(app, .{ .dyn = slot }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .set_panel_sort => |s| switch (s.panel) {
            .todos => try todos.setSort(app, s.sort),
            .notes => try notes.setSort(app, s.sort),
            .findings => try findings.setSort(app, s.sort),
            .sessions, .git, .diagnostics, .http => {},
        },
        .ai_profile => |a| launch_profiles.menuAction(app, a) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (app.diag.msg) |m| app.toast("{s}", .{m});
                app.diag.clear();
            },
        },
        .dock_set => |s| dock.setSetting(app, s.id, s.setting),
        .toggle_auto_refresh => |p| try auto_refresh.toggle(app, p),
        .set_coverage_mode => |m| try coverage.setMode(app, m),
        .menu_bar => |i| try menu_bar.openIndex(app, i),
        .git_palette => |a| try git_palette.menuAction(app, a),
        .none => {},
    }
}

fn overlayKey(app: *App, k: Key) Allocator.Error!void {
    const gpa = app.gpa;
    switch (app.overlay) {
        .none => {},
        .prompt => |*p| {
            // A path prompt — a workspace to add, a rename / move-to
            // destination — completes folders on Tab; any other key ends
            // the cycle. The worktree prompt is `<path> [branch]`: its
            // path is the first word.
            const path_prompt: ?bool = if (p.purpose == .add_workspace or p.purpose == .rename or p.purpose == .move_paths) false else if (p.purpose == .git and app.git.prompt == .worktree_add) true else null;
            if (path_prompt) |first_word| {
                if (k.code == .tab) return promptPathComplete(app, &p.state, first_word);
                dropComplete(app);
            }
            switch (try Prompt.handleKey(&p.state, gpa, k)) {
                .consumed => {},
                .cancel => closeOverlay(app),
                .submit => {
                    const text = try app.frame.allocator().dupe(u8, p.state.buf.items);
                    const purpose = p.purpose;
                    p.purpose = .goto_line; // ownership moved here
                    closeOverlay(app);
                    defer purpose.deinit(app.gpa);
                    try acceptPrompt(app, purpose, text);
                },
            }
        },
        .confirm => |*c| switch (Confirm.handleKey(&c.state, k)) {
            .consumed => {},
            .cancel => closeOverlay(app),
            .choose => |i| {
                const purpose = c.purpose;
                c.purpose = .quit; // ownership moved here
                closeOverlay(app);
                defer purpose.deinit(app.gpa);
                try acceptConfirm(app, purpose, i);
            },
        },
        .which_key => |*w| {
            if (k.code == .esc) return closeOverlay(app);
            const c = k.typed() orelse return closeOverlay(app);
            if (c >= 128 or w.len >= whichkey.max_depth) return closeOverlay(app);
            w.path[w.len] = @intCast(c);
            w.len += 1;
            const node = whichkey.lookup(w.slice()) orelse return closeOverlay(app);
            switch (node.*) {
                .group => {},
                .dead => |d| {
                    closeOverlay(app);
                    app.toast("{s}: not a command in this build", .{d.id});
                },
                .cmd => |cmd| {
                    closeOverlay(app);
                    command.run(app, .{ .static = cmd.id }) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {},
                    };
                },
            }
        },
        .picker => |*p| switch (try Picker.handleKey(&p.state, gpa, k, p.filtered.items.len)) {
            .consumed => cmd_picker.preview(app),
            .ignored => try widgetFallthrough(app, k),
            .cancel => {
                cmd_picker.cancel(app);
                closeOverlay(app);
            },
            .changed => {
                try refilterPicker(app);
                cmd_picker.preview(app);
            },
            .accept => |i| try cmd_picker.accept(app, i),
        },
        .settings => try settings_app.key(app, k),
        .wizard => try first_launch.key(app, k),
        .info => closeOverlay(app),
        // The discovery panel: F1 and Esc close it, as Rust's does.
        .discovery => if (k.code == .esc or (k.code == .f and k.code.f == 1)) closeOverlay(app),
        .help => try help_app.key(app, k),
        .menu => |*m| {
            // A menu-bar menu: ← / → step to the neighbouring menu.
            if (try menu_bar.menuKey(app, k)) return;
            // The child owns the keys while it is open: ← / h step back
            // out of it, Enter / → / l run its row.
            if (m.sub) |*sub| {
                const slast = sub.items.len -| 1;
                switch (k.code) {
                    .esc => closeOverlay(app),
                    .left => m.closeSub(gpa),
                    .enter => if (sub.items.len > 0) try runMenuAction(app, sub.items[sub.cursor].action),
                    .right => try subOpenRight(app),
                    .up => sub.cursor -|= 1,
                    .down => sub.cursor = @min(sub.cursor + 1, slast),
                    .home => sub.cursor = 0,
                    .end => sub.cursor = slast,
                    .char => |c| switch (c) {
                        'h' => m.closeSub(gpa),
                        'l' => try subOpenRight(app),
                        'k' => sub.cursor -|= 1,
                        'j' => sub.cursor = @min(sub.cursor + 1, slast),
                        'q' => closeOverlay(app),
                        else => {},
                    },
                    else => {},
                }
                return;
            }
            const last = m.items.len -| 1;
            switch (k.code) {
                .esc => closeOverlay(app),
                // Enter on a parent row opens it rather than firing —
                // the row has no action of its own.
                .enter => try menuEnter(app, m.cursor),
                .right => try menuOpenRight(app, m.cursor),
                .up => m.cursor -|= 1,
                .down => m.cursor = @min(m.cursor + 1, last),
                .home => m.cursor = 0,
                .end => m.cursor = last,
                .char => |c| switch (c) {
                    'k' => m.cursor -|= 1,
                    'j' => m.cursor = @min(m.cursor + 1, last),
                    'l' => try menuOpenRight(app, m.cursor),
                    'q' => closeOverlay(app),
                    else => {},
                },
                else => {},
            }
        },
    }
}

/// Rust's `refilter`: the label alone is scored (the palette's carries
/// the group and the id), then priority desc, score desc, index asc.
/// The command palette pins an exact id and boosts an id that contains
/// the query (`Picker.rank`).
pub fn refilterPicker(app: *App) Allocator.Error!void {
    const p = &app.overlay.picker;
    p.filtered.clearRetainingCapacity();
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const items = try arena.alloc(Picker.Item, p.labels.len);
    for (p.labels, 0..) |label, i| items[i] = .{ .label = label };
    const ids: []const []const u8 = if (p.kind == .commands) try cmd_picker.commandIds(app, arena) else &.{};
    const order = try Picker.rank(arena, p.state.query.items, items, .{ .priority = p.priority, .score_bonus = p.score_bonus, .ids = ids });
    try p.filtered.ensureTotalCapacity(app.gpa, order.len);
    for (order) |i| p.filtered.appendAssumeCapacity(@intCast(i));
    if (p.state.cursor >= p.filtered.items.len) p.state.cursor = 0;
}

fn acceptPrompt(app: *App, purpose: app_mod.PromptPurpose, text: []const u8) Allocator.Error!void {
    switch (purpose) {
        .goto_line => {
            const t = std.mem.trim(u8, text, " \t");
            if (t.len == 0) return;
            const colon = std.mem.indexOfScalar(u8, t, ':');
            const line_s = if (colon) |i| t[0..i] else t;
            const n = std.fmt.parseInt(usize, std.mem.trim(u8, line_s, " "), 10) catch {
                app.toast("not a number: \"{s}\"", .{t});
                return;
            };
            const col: usize = if (colon) |i| (std.fmt.parseInt(usize, std.mem.trim(u8, t[i + 1 ..], " "), 10) catch 1) -| 1 else 0;
            const e = app.activeEditor() orelse return;
            e.buf.editor.placeCursor(@min(n -| 1, e.buf.editor.lineCount() - 1), col);
        },
        .tab_width => try context_menus.acceptTabWidth(app, text),
        .image_open => try image_pane.acceptOpen(app, text),
        .replace => try cmd_find.replaceAll(app, text),
        .filter_shell => try filterThroughShell(app, text),
        .git => try toastOnFail(app, git_app.acceptPrompt(app, text)),
        .new_todo => todos.appendTodo(app, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => {},
            else => if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("todo: {s}", .{@errorName(err)}),
        },
        .new_file => |dir| try tree_mod.acceptNewFile(app, dir, text),
        .new_note => |dir| try notes.acceptNew(app, dir, text),
        .new_finding => |dir| try findings.acceptNew(app, dir, text),
        .sessions_rename => |id| try sessions.acceptRename(app, id, text),
        .dock_new_text => |c| try dock.acceptNewText(app, c, text),
        .dock_new_log => |c| try dock.acceptNewLog(app, c, text),
        .dock_edit => |id| try dock.acceptEdit(app, id, text),
        .dock_rename => |id| try dock.acceptRename(app, id, text),
        .new_folder => |dir| try tree_mod.acceptNewFolder(app, dir, text),
        .rename => |from| try tree_mod.acceptRename(app, from, text),
        .move_paths => |ps| try files_pane.acceptMoveTo(app, @ptrCast(ps), text),
        .npm_run_script => try toastOnFail(app, runners.npmRunScriptAccept(app, text)),
        .go_run_path => try toastOnFail(app, runners.goRunPathAccept(app, text)),
        .ai_ask => try toastOnFail(app, ai_app.askAccept(app, text)),
        .ai_chat => try toastOnFail(app, ai_app.chatAccept(app, text)),
        .ai_search => try toastOnFail(app, ai_app.sessionSearchAccept(app, text)),
        .mount_open => try toastOnFail(app, mount_pane.acceptPrompt(app, text)),
        .term_rename => |id| try toastOnFail(app, cmd_term.renameAccept(app, id, text)),
        .grep_query => try grep.acceptQuery(app, text),
        .grep_replace => try grep.acceptReplace(app, text),
        .add_workspace => try tree_mod.acceptAddWorkspace(app, text),
        .ai_branch_name => try toastOnFail(app, ai_app.branchNameAccept(app, text)),
        .ai_token => try toastOnFail(app, ai_app.tokenAccept(app, text)),
        .dap_add_watch => try dap.acceptWatch(app, text),
        .dap_bp_condition => |b| try dap.acceptCondition(app, b.path, b.line, text),
        .dap_hit_count => |b| try dap.acceptHitCount(app, b.path, b.line, text),
        .dap_set_variable => |sv| try dap.acceptSetVariable(app, sv.parent_ref, sv.name, text),
        .lsp_rename => try lsp.acceptRename(app, text),
        .lsp_workspace_symbol => try lsp.acceptWorkspaceSymbol(app, text),
        .ws_url, .ws_message => try ws_pane.acceptPrompt(app, purpose, text),
        .browser_url, .browser_navigate, .browser_eval, .browser_add_cookie, .browser_add_storage => try cmd_browser.acceptPrompt(app, purpose, text),
        .http_env_add_key, .http_env_edit_value, .http_auth_value, .auth_preset_name, .http_save_as, .http_save_response, .http_new_env, .http_new_chain, .http_new_collection, .http_new_request, .http_lookup_var => try cmd_http.acceptPrompt(app, purpose, text),
    }
}

/// A command-shaped call from an overlay: its reason is toasted the way
/// `command.run` would have.
fn toastOnFail(app: *App, result: command.CommandError!void) Allocator.Error!void {
    result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => {},
        else => if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("{s}", .{@errorName(err)}),
    };
}

fn acceptConfirm(app: *App, purpose: app_mod.ConfirmPurpose, choice: usize) Allocator.Error!void {
    switch (purpose) {
        .trust_workspace => try @import("trust.zig").answer(app, choice),
        .replace_confirm => try ex_verbs.answerConfirm(app, choice),
        .review_trust => try @import("workspace_trust.zig").answerReview(app, choice),
        .close_pane => |id| switch (choice) {
            0 => {
                const e = app.panes.editor(id) orelse return;
                if (e.buf.doc.path == null) {
                    app.toast("can't save a scratch buffer — pick Discard or Cancel", .{});
                    return;
                }
                e.buf.save(app.io) catch |err| {
                    app.toast("save failed: {s}", .{@errorName(err)});
                    return;
                };
                try app.forceClosePane(id);
            },
            1 => try app.forceClosePane(id),
            else => {},
        },
        .quit => switch (choice) {
            0 => {
                cmd_file.saveAll(app) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return, // toasted; the quit is off
                };
                app.quit = true;
            },
            1 => app.quit = true,
            else => {},
        },
        .delete_paths => |d| {
            try trash.acceptDelete(app, @ptrCast(d.paths), d.permanent_only, choice);
            if (choice == 0) for (d.paths) |p| {
                notes.onPathRemoved(app, p);
                findings.onPathRemoved(app, p);
            };
        },
        .empty_trash => try trash.acceptEmpty(app, choice),
        .delete_path => |rel| if (choice == 0) {
            try tree_mod.acceptDelete(app, rel);
            notes.onPathRemoved(app, rel);
            findings.onPathRemoved(app, rel);
        },
        .move_path => |mv| if (choice == 0) {
            if (mv.copy) try tree_mod.acceptCopy(app, mv.from, mv.into) else try tree_mod.acceptMove(app, mv.from, mv.into);
        },
        .delete_session => |path| if (choice == 0) try sessions.acceptDelete(app, path),
        .install_tool => |idx| try toastOnFail(app, runners.installAccept(app, idx, choice)),
        .git => try toastOnFail(app, git_app.acceptConfirm(app, choice)),
        .ai_tool => |job| ai_app.answerConfirm(app, job, choice == 0),
        .kill_pids => |pids| if (choice == 0) try agents.killAccept(app, pids),
        .remove_integration => |id| if (choice == 0) try integrations.removeAccept(app, id),
    }
}

// ─── the find bar ───────────────────────────────────────────────────────

fn findBarKey(app: *App, k: Key) Allocator.Error!void {
    const fb = &app.find_bar.?;
    switch (try FindBar.handleKey(&fb.state, app.gpa, k)) {
        .consumed, .focus_toggle => {},
        .ignored => try widgetFallthrough(app, k),
        .toggle_regex, .toggle_case => try cmd_find.liveUpdate(app),
        .cancel => app.closeFindBar(true),
        .changed => try cmd_find.liveUpdate(app),
        .submit => try cmd_find.acceptFromBar(app),
        .next => try cmd_find.stepFromBar(app, 1),
        .prev => try cmd_find.stepFromBar(app, -1),
        .history_prev => try find_history.recall(app, -1),
        .history_next => try find_history.recall(app, 1),
        .replace_one => try cmd_find.replaceCurrent(app),
        .replace_all => {
            const text = try app.frame.allocator().dupe(u8, fb.state.replace.items);
            try cmd_find.replaceAll(app, text);
        },
    }
}

/// A modified chord (or a function key) a text widget did not claim
/// goes to the keymap as a single chord: Ctrl+S saves from the find bar
/// and the palette, the way VS Code binds save with no `when` clause,
/// and the widget stays. Leader prefixes (`ctrl+k …`) stay with the
/// widget — a pending chain has nowhere to finish while it holds the
/// keys. Plain keys never leave the widget.
fn widgetFallthrough(app: *App, k: Key) Allocator.Error!void {
    if (!(k.mods.ctrl or k.mods.alt or k.mods.super) and k.code != .f) return;
    switch (app.keymap.resolveSeq(&.{Chord.of(k)})) {
        .run, .pending_with_fallback => |t| try runTarget(app, t),
        .pending, .none => {},
    }
}

// ─── paste ──────────────────────────────────────────────────────────────

pub fn paste(app: *App, text: []const u8) Allocator.Error!void {
    switch (app.overlay) {
        .prompt => |*p| return Prompt.paste(&p.state, app.gpa, text),
        .picker => |*p| {
            try Picker.paste(&p.state, app.gpa, text);
            return refilterPicker(app);
        },
        else => {},
    }
    if (app.find_bar) |*fb| return FindBar.paste(&fb.state, app.gpa, text);
    if (app.active) |id| if (app.panes.pty(id)) |p| {
        if (app.focus == .pane) return pty_pane.paste(app, p, text);
    };
    if (app.active) |id| if (app.panes.get(id)) |p| if (p.asRequest()) |rp| {
        if (app.focus == .pane) return request_pane.paste(app, rp, text);
    };
    if (app.active) |id| if (app.panes.get(id)) |p| if (p.asWebsocket()) |w| {
        if (app.focus == .pane) return ws_pane.paste(app, w, text);
    };
    if (app.active) |id| if (app.panes.get(id)) |p| if (p.asMount()) |mp| {
        if (app.focus == .pane) return mount_pane.paste(app, mp, text);
    };
    const e = app.activeEditor() orelse return;
    const copy = try app.frame.allocator().dupe(u8, text);
    _ = try app.applyOps(e, &.{.{ .insert_str = copy }});
}

// ─── mouse ──────────────────────────────────────────────────────────────
// One `switch` on the hit under the pointer (D6). A press may start a
// gesture (`app.drag`) that the following drag events feed and the
// release completes; the hit under the release decides where a tab or
// a tree file lands. `count` is the wheel batch (`scroll.zig`).

pub fn mouse(app: *App, m: Mouse, count: u16) Allocator.Error!void {
    app.needs_render = true;
    app.hover = .{ .x = m.x, .y = m.y };
    app.hover_live = m.kind == .motion or m.kind == .drag;
    if (m.kind == .drag or m.kind == .release) {
        if (app.drag != null) return continueDrag(app, m);
    }
    if (m.kind == .motion) return;
    // A press anywhere puts flash's labels away.
    if (m.kind == .press) flash.cancel(app);
    // The click-discovery panel: a press on one of its rows flashes the
    // family it names; a press anywhere else closes it (Rust).
    if (m.kind == .press and app.overlay == .discovery) {
        if (app.hits.at(m.x, m.y)) |under| if (under == .overlay_item) return discovery.flashRow(app, under.overlay_item);
        closeOverlay(app);
        return;
    }
    const target = app.hits.at(m.x, m.y) orelse {
        if (m.kind == .press) pressOutside(app);
        return;
    };
    // A press anywhere but on the overlay itself dismisses it; the
    // press then goes on to whatever it landed on. A menu closes, a
    // picker puts its preview back (the themes picker), the settings
    // box keeps its writes; the read-only overlays close on any press
    // and swallow it. A press on the overlay's own items routes below.
    if (m.kind == .press) {
        switch (app.overlay) {
            .menu => if (target != .menu_item) closeOverlay(app),
            .info => {
                closeOverlay(app);
                return;
            },
            // The help box: a press off its rows and bar closes it.
            .help => if (target != .overlay_item and target != .scrollbar) {
                closeOverlay(app);
                return;
            },
            .settings => if (target != .overlay_item) settings_app.close(app),
            .picker => if (target != .overlay_item and target != .scrollbar) {
                cmd_picker.cancel(app);
                closeOverlay(app);
            },
            else => {},
        }
    }
    const wheel = m.kind == .scroll_up or m.kind == .scroll_down;
    // A notch on a pane's tab-strip row (a gap between tabs falls through
    // to the pane) scrolls the strip, not the buffer.
    if (wheel and target == .pane) {
        if (!app.zen) if (hitRect(app, m.x, m.y)) |r| if (r.h >= 2 and m.y == r.y) {
            if (app.layouts.current().leafOf(target.pane)) |lid| return tabStripStepLid(app, lid, if (m.kind == .scroll_down) 1 else -1);
        };
    }
    switch (target) {
        // The list panels (D6): one prong per hit kind, routed by panel.
        .row => |pr| switch (pr.panel) {
            .todos => try todos.rowMouse(app, pr.idx, m),
            .notes => try notes.rowMouse(app, pr.idx, m),
            .findings => try findings.rowMouse(app, pr.idx, m),
            .sessions => try sessions.rowMouse(app, pr.idx, m),
            .git => try git_palette.rowMouse(app, pr.idx, m),
            .diagnostics => try lsp.rowMouse(app, pr.idx, m),
            .http => try http_panel.rowMouse(app, pr.idx, m),
        },
        .kebab => |pr| switch (pr.panel) {
            .todos => try todos.kebabMouse(app, pr.idx, m),
            .notes => try notes.kebabMouse(app, pr.idx, m),
            .findings => try findings.kebabMouse(app, pr.idx, m),
            .sessions => try sessions.kebabMouse(app, pr.idx, m),
            .git => {},
            .http => try http_panel.kebabMouse(app, pr.idx, m),
            .diagnostics => {},
        },
        .chip => |c| switch (c.panel) {
            .todos => try todos.chipMouse(app, c.kind, m),
            .notes => try notes.chipMouse(app, c.kind, m),
            .findings => try findings.chipMouse(app, c.kind, m),
            .sessions => try sessions.chipMouse(app, c.kind, m),
            .git => try git_palette.chipMouse(app, c.kind, m),
            .diagnostics => try lsp.chipMouse(app, m),
            .http => try http_panel.chipMouse(app, c.kind, m),
        },
        .filter_input => |p| switch (p) {
            .todos => todos.filterMouse(app, m),
            .notes => notes.filterMouse(app, m),
            .findings => findings.filterMouse(app, m),
            .sessions => sessions.filterMouse(app, m),
            .git => git_palette.filterMouse(app, m),
            .diagnostics => lsp.filterMouse(app, m),
            .http => http_panel.filterMouse(app, m),
        },
        .scrollbar => |sb| switch (sb.owner) {
            .panel => |p| switch (p) {
                .todos => if (hitRect(app, m.x, m.y)) |r| todos.scrollbarMouse(app, r, m),
                .notes => if (hitRect(app, m.x, m.y)) |r| notes.scrollbarMouse(app, r, m),
                .findings => if (hitRect(app, m.x, m.y)) |r| findings.scrollbarMouse(app, r, m),
                .sessions => if (hitRect(app, m.x, m.y)) |r| sessions.scrollbarMouse(app, r, m),
                .git => if (hitRect(app, m.x, m.y)) |r| git_palette.scrollbarMouse(app, r, m),
                .diagnostics => if (hitRect(app, m.x, m.y)) |r| lsp.scrollbarMouse(app, r, m),
                .http => if (hitRect(app, m.x, m.y)) |r| http_panel.scrollbarMouse(app, r, m),
            },
            .pane => |id| {
                // The picker's bar: the wheel walks the cursor, a press
                // on the track jumps the list to that fraction.
                if (id == HelpUi.scrollbar_owner and app.overlay == .help) {
                    if (wheel) {
                        const lines: isize = @intCast(app.cfg.ui.wheel_lines * count);
                        help_app.wheel(app, if (m.kind == .scroll_down) lines else -lines);
                    } else if (m.kind == .press and m.button == .left) {
                        const track = hitRect(app, m.x, m.y) orelse return;
                        const h = &app.overlay.help;
                        if (track.h > 0) h.scroll = @min((@as(usize, m.y - track.y) * h.line_count) / track.h, h.line_count -| h.body_rows);
                        app.needs_render = true;
                    }
                    return;
                }
                if (id == Picker.scrollbar_owner and app.overlay == .picker) {
                    const p = &app.overlay.picker;
                    if (wheel) {
                        const lines: isize = @intCast(app.cfg.ui.wheel_lines * count);
                        Picker.wheel(&p.state, if (m.kind == .scroll_down) lines else -lines, p.filtered.items.len);
                    } else if (m.kind == .press and m.button == .left) {
                        const track = hitRect(app, m.x, m.y) orelse return;
                        const n = p.filtered.items.len;
                        if (track.h > 0 and n > 0) p.state.cursor = @min((@as(usize, m.y - track.y) * n) / track.h, n - 1);
                    }
                    cmd_picker.preview(app);
                    return;
                }
                if (wheel) return wheelOnPane(app, id, m, count);
                if (m.kind != .press or m.button != .left) return;
                const track = hitRect(app, m.x, m.y) orelse return;
                try beginScrollbarDrag(app, id, track, m.y);
            },
            .tree => if (hitRect(app, m.x, m.y)) |r| app.tree.scrollbarMouse(app, r, m),
        },
        // A section header folds on a press; Alt folds or opens every
        // directory inside the primary with it (Rust `tree_toggle`).
        .tree_root => |root| {
            if (wheel) return treeWheel(app, m, count);
            if (m.kind != .press or m.button != .left) return;
            if (app.overlay != .none) closeOverlay(app);
            try app.tree.toggleRoot(app, root, m.mods.alt);
        },
        .tree_chip => |c| {
            if (wheel) return treeWheel(app, m, count);
            if (m.kind != .press or m.button != .left) return;
            if (app.overlay != .none) closeOverlay(app);
            try tree_mod.chipClick(app, c);
        },
        .info_view => |part| {
            if (m.kind == .press and app.overlay != .none and part != .kebab) closeOverlay(app);
            try info_view_app.mouse(app, part, m);
        },
        .menu_item => |mi| if (m.kind == .press) {
            if (app.overlay != .menu) return;
            const menu = &app.overlay.menu;
            switch (mi.menu) {
                // A parent row opens its child; a leaf runs.
                0 => {
                    if (mi.idx >= menu.items.len) return;
                    menu.cursor = mi.idx;
                    try menuEnter(app, mi.idx);
                },
                // A child row.
                1 => if (menu.sub) |*sub| {
                    if (mi.idx >= sub.items.len) return;
                    try runMenuAction(app, sub.items[mi.idx].action);
                },
                // The kebab on a top-level row / on a child row.
                2 => {
                    if (mi.idx >= menu.items.len) return;
                    menu.cursor = mi.idx;
                    try context_menus.openCuration(app, mi.idx, menu.items[mi.idx]);
                },
                3 => if (menu.sub) |*sub| {
                    if (mi.idx >= sub.items.len) return;
                    const parent = sub.parent;
                    const item = sub.items[mi.idx];
                    try context_menus.openCuration(app, parent, item);
                },
                else => {},
            }
        },
        .editor_cell => |cell| {
            if (wheel) return wheelOnPane(app, cell.pane, m, count);
            if (m.kind != .press) return;
            // The outline and the preview reuse the cell hit: a row is a
            // jump, a row is a scroll target.
            if (app.panes.get(cell.pane)) |p| switch (p.*) {
                .outline => {
                    if (m.button == .left) {
                        if (app.overlay != .none) closeOverlay(app);
                        outline.clickRow(app, cell.pane, cell.line, cell.col);
                    }
                    return;
                },
                .md_preview => {
                    if (app.overlay != .none) closeOverlay(app);
                    app.showPane(cell.pane);
                    return;
                },
                else => {},
            };
            if (app.overlay != .none) closeOverlay(app);
            if (app.active != cell.pane) app.showPane(cell.pane);
            const e = app.panes.editor(cell.pane) orelse return;
            const ed = e.buf.editor;
            const line = @min(cell.line, ed.lineCount() - 1);
            // The column under the pointer: the hit's first column plus the offset.
            const hit_rect = hitRect(app, m.x, m.y) orelse return;
            const col = cell.col + (m.x - hit_rect.x);
            const byte = @min(ed.byteAtCol(line, col), ed.lineEnd(line));
            // `ui.click_echo`: the word under a left press underlines
            // for 120 ms — "did that click land?".
            if (m.button == .left and app.cfg.ui.click_echo) {
                const r = find_mod.wordAt(ed.bytes(), byte) orelse find_mod.Range{ .start = byte, .end = @min(byte + 1, ed.len()) };
                app.click_echo = .{ .pane = cell.pane, .start = r.start, .end = r.end, .until_ms = app.now_ms + app_mod.click_echo_ms };
            }
            switch (m.button) {
                .right => {
                    // Right-click inside a selection keeps it; elsewhere it moves the cursor.
                    if (ed.selection()) |sel| {
                        if (byte < sel[0] or byte > sel[1]) {
                            ed.anchor = null;
                            ed.setCursor(byte);
                        }
                    } else ed.setCursor(byte);
                    try context_menus.openEditorMenu(app, m.x, m.y);
                },
                .middle => {
                    ed.anchor = null;
                    ed.setCursor(byte);
                    // X11's middle click pastes the primary selection: `"*`.
                    // Falls back to the unnamed register where the sink cannot read.
                    app.clipboard.setPendingRegister('*');
                    const text = app.clipboard.text();
                    if (text.len > 0) {
                        const copy = try app.frame.allocator().dupe(u8, text);
                        _ = try app.applyOps(e, &.{.{ .insert_str = copy }});
                    }
                },
                else => try editorPress(app, cell.pane, e, byte, m),
            }
        },
        .tab => |tb| {
            if (wheel) return tabStripStep(app, tb.leaf, if (m.kind == .scroll_down) 1 else -1);
            const layout = app.layouts.current();
            const lid = (try layout.leafAt(app.frame.allocator(), tb.leaf)) orelse return;
            const leaf = layout.leaf(lid) orelse return;
            if (tb.idx >= leaf.tabs.items.len) return;
            const pane = leaf.tabs.items[tb.idx];
            if (m.kind != .press) return;
            if (app.overlay != .none) closeOverlay(app);
            switch (m.button) {
                .middle => try app.closePane(pane, false),
                .right => try context_menus.openTabMenu(app, pane, m.x, m.y),
                else => {
                    app.showPane(pane);
                    app.drag = .{ .tab = .{ .pane = pane, .x = m.x, .y = m.y } };
                },
            }
        },
        .tab_close => |tb| {
            if (wheel or m.kind != .press or m.button != .left) return;
            const layout = app.layouts.current();
            const lid = (try layout.leafAt(app.frame.allocator(), tb.leaf)) orelse return;
            const leaf = layout.leaf(lid) orelse return;
            if (tb.idx >= leaf.tabs.items.len) return;
            if (app.overlay != .none) closeOverlay(app);
            try app.closePane(leaf.tabs.items[tb.idx], false);
        },
        .breadcrumb => |bc| {
            // A segment opens a Files pane at the directory it names.
            if (wheel or m.kind != .press or m.button != .left) return;
            const e = app.panes.editor(bc.pane) orelse return;
            const path = e.buf.doc.path orelse return;
            const dir = (try render.breadcrumbDir(app, app.frame.allocator(), path, bc.idx)) orelse return;
            if (app.overlay != .none) closeOverlay(app);
            _ = try files_pane.open(app, dir);
        },
        .overlay_item => |i| {
            // The wheel over the Settings box scrolls its list; over the
            // picker it walks the cursor, as Rust's does.
            if (wheel and app.overlay == .settings) {
                const lines: isize = @intCast(app.cfg.ui.wheel_lines * count);
                return settings_app.wheel(app, if (m.kind == .scroll_down) lines else -lines);
            }
            if (wheel and app.overlay == .picker) {
                const lines: isize = @intCast(app.cfg.ui.wheel_lines * count);
                Picker.wheel(&app.overlay.picker.state, if (m.kind == .scroll_down) lines else -lines, app.overlay.picker.filtered.items.len);
                cmd_picker.preview(app);
                return;
            }
            if (wheel and app.overlay == .help) {
                const lines: isize = @intCast(app.cfg.ui.wheel_lines * count);
                return help_app.wheel(app, if (m.kind == .scroll_down) lines else -lines);
            }
            if (m.kind != .press) return;
            switch (app.overlay) {
                .confirm => |*c| {
                    const purpose = c.purpose;
                    c.purpose = .quit; // ownership moved to `acceptConfirm`
                    closeOverlay(app);
                    defer purpose.deinit(app.gpa);
                    try acceptConfirm(app, purpose, i);
                },
                .picker => try cmd_picker.accept(app, i),
                .help => try help_app.click(app, i),
                .which_key => |*w| {
                    const kids = whichkey.continuations(w.slice());
                    if (i >= kids.len) return;
                    try overlayKey(app, Key.char(kids[i].key));
                },
                .settings => try settings_app.click(app, i),
                .wizard => first_launch.click(app, i),
                // The find bar's chips, the rename preview and the completion
                // popup register their rows here with no overlay up.
                else => if (app.find_bar != null) try cmd_find.chipClick(app, i) else if (app.lsp.rename.preview != null) rename_app.click(app, i) else if (app.lsp.completion != null) try lsp.clickCompletion(app, i),
            }
        },
        .pane => |id| {
            if (app.panes.pty(id)) |p| {
                // The child tracks the mouse: every report goes to it,
                // pane-relative (the tab strip is the rect's first row).
                // Otherwise the wheel scrolls the scrollback.
                if (m.kind == .press) {
                    if (app.overlay != .none) closeOverlay(app);
                    if (app.active != id or app.focus != .pane) app.showPane(id);
                }
                if (p.encoding().mouse == .none) {
                    if (wheel) return wheelOnPane(app, id, m, count);
                    return;
                }
                const r = hitRect(app, m.x, m.y) orelse return;
                const strip: u16 = if (r.h >= 2) 1 else 0;
                pty_pane.mouse(app, p, m, .{ .x = r.x, .y = r.y + strip });
                return;
            }
            if (wheel) return wheelOnPane(app, id, m, count);
            if (m.kind != .press) return;
            if (app.overlay != .none) closeOverlay(app);
            if (app.active != id) app.showPane(id) else app.focus = .{ .pane = id };
            if (m.button == .right) {
                if (app.panes.editor(id) != null) try context_menus.openEditorMenu(app, m.x, m.y);
            }
        },
        .script_hit => |sh| {
            // A mount forwards the wheel and the pointer; the rest of
            // the panes only hear presses.
            if (app.panes.get(sh.pane)) |mp_pane| if (mp_pane.asMount()) |mp| {
                if (wheel) return mount_pane.wheel(mp, sh.id, m, hitRect(app, m.x, m.y), count);
                if (m.kind == .motion) return mount_pane.hover(mp, sh.id, m, hitRect(app, m.x, m.y));
            };
            if (wheel) return wheelOnPane(app, sh.pane, m, count);
            if (m.kind != .press) return;
            if (m.button != .left and m.button != .right) return;
            if (app.overlay != .none) closeOverlay(app);
            if (app.active != sh.pane) app.showPane(sh.pane);
            const pane = app.panes.get(sh.pane) orelse return;
            switch (pane.*) {
                .cheatsheet => |*c| if (m.button == .left) try cheatsheet.click(app, c, sh.id),
                .script => |*s| script_pane.click(app, s, sh.id, m),
                .list => |*l| if (m.button == .left) {
                    if (sh.id < l.entries.items.len) {
                        if (l.cursor == sh.id) try listPaneEnter(app, sh.pane, l) else l.cursor = sh.id;
                    }
                },
                .git_status => |*s| try git_app.statusPaneClick(app, s, sh.id, m),
                .diff => |*d| try git_app.diffClick(app, sh.pane, d, sh.id, m),
                .git_graph => |*g| try git_app.graphClick(app, sh.pane, g, sh.id, m),
                .claude_agents => |*a| try agents.click(app, sh.pane, a, sh.id, m),
                .spend_report => |*s| try spend.click(app, sh.pane, s, sh.id, m),
                .grep => |*g| try grep.click(app, sh.pane, g, sh.id, m),
                .debug, .dap_repl => try dap.click(app, sh.pane, sh.id),
                .request => |*rp| try request_pane.click(app, sh.pane, rp, sh.id, m, hitRect(app, m.x, m.y)),
                .websocket => {},
                .browser => |*b| if (m.button == .left) try browser_pane.click(app, b, sh.id),
                .mount => |*mp| try mount_pane.click(app, sh.pane, mp, sh.id, m, hitRect(app, m.x, m.y)),
                .integrations => |*ip| try integrations.click(app, sh.pane, ip, sh.id, m),
                .marketplace => |*mk| try marketplace.click(app, mk, sh.id, m),
                // A code lens segment sits above `lens_hit_base`; the
                // `{{VAR}}` spans below it.
                .editor => |*e| if (sh.id >= decor.lens_hit_base) {
                    if (m.button == .left) try decor.scriptHit(app, sh.pane, sh.id);
                } else try http_app.editorVarClick(app, sh.pane, e, sh.id, m),
                .ai_apply => |*ap| ai_apply.click(app, ap, sh.id, m),
                .tests => |*tp| try tests_pane.click(app, tp, sh.id, m),
                .flaky => |*fp| flaky.click(app, fp, sh.id, m),
                .files => |*f| try files_pane.click(app, sh.pane, f, sh.id, m),
                .outline, .md_preview, .image, .pty, .ai => {},
            }
        },
        .tree_node => |idx| switch (m.kind) {
            .press => {
                if (app.overlay != .none) closeOverlay(app);
                if (idx >= app.tree.rows.items.len) return;
                switch (m.button) {
                    .right => try context_menus.openTreeMenu(app, idx, m.x, m.y),
                    .left => {
                        app.tree.cursor = idx;
                        if (app.activeBuffer()) |b| b.input.onBlur();
                        app.focus = .tree;
                        const row = app.tree.rows.items[idx];
                        if (row.is_dir) {
                            // The chevron (and the name): toggle now.
                            try app.tree.activate(app, idx);
                        } else {
                            // A file opens on release, so a hold becomes a drag.
                            app.drag = .{ .tree = .{ .idx = idx, .copy = m.mods.alt } };
                        }
                    },
                    else => app.tree.cursor = idx,
                }
            },
            .scroll_up, .scroll_down => treeWheel(app, m, count),
            else => {},
        },
        .divider => |id| {
            if (m.kind != .press or m.button != .left) return;
            if (app.overlay != .none) closeOverlay(app);
            try beginDividerDrag(app, id);
        },
        .statusline_seg => |seg| {
            if (m.kind != .press) return;
            if (app.overlay != .none) closeOverlay(app);
            const right = m.button == .right;
            switch (seg) {
                statusline.seg_mode => if (right) try context_menus.openModeMenu(app, m.x, m.y) else try runCmd(app, .@"editor.toggle_keymap"),
                statusline.seg_position => try runCmd(app, .@"editor.goto_line"),
                // The file chip is words on hover and a menu on the right
                // button; a left click does nothing, as in Rust.
                statusline.seg_file => if (right) try context_menus.openFileChipMenu(app, m.x, m.y),
                statusline.seg_language => {
                    const lang: []const u8 = if (app.activeEditor()) |e| (e.buf.doc.language orelse "—") else "—";
                    app.toast("language: {s} (via file extension)", .{lang});
                },
                statusline.seg_restricted => try runCmd(app, .@"workspace.review_trust"),
                else => if (statusline_app.SegId.of(seg)) |id| switch (id) {
                    .branch => if (right) try context_menus.openBranchMenu(app, m.x, m.y) else try runCmd(app, .@"git.status_pane"),
                    .pr => if (statusline_app.currentPr(app)) |pr| git_app.openExternal(app, pr.url),
                    .diagnostics => if (right) try context_menus.openDiagnosticsMenu(app, m.x, m.y) else try runCmd(app, .@"lsp.diagnostics"),
                    .symbol => try runCmd(app, .@"outline.show"),
                    .macro => try runCmd(app, .@"vim.macro_toggle"),
                    .find => try runCmd(app, .@"find.find"),
                    .test_run => if (tests_pane.find(app)) |id_pane| {
                        app.setActive(id_pane);
                        app.focus = .{ .pane = id_pane };
                    },
                    .ai_claude, .ai_codex => try runCmd(app, .@"ai.spend_today"),
                    .coverage => if (right) try coverage.openModeMenu(app, m.x, m.y) else try runCmd(app, .@"coverage.toast"),
                    .transfer => if (right) try runCmd(app, .@"transfer.cancel_all"),
                    .lsp => try runCmd(app, .@"lsp.symbols"),
                    .wrap => try runCmd(app, .@"view.toggle_wrap"),
                    .autosave => app.toast("autosave: {d}s (`[editor] autosave_secs` to change)", .{app.cfg.editor.autosave_secs}),
                    .filesize => if (app.activeEditor()) |e| {
                        const n = e.buf.editor.bytes().len;
                        app.toast("{s}: {d} byte{s} · {d} line{s}", .{ if (e.buf.doc.path) |pth| std.fs.path.basename(pth) else "[scratch]", n, if (n == 1) "" else "s", e.buf.editor.lineCount(), if (e.buf.editor.lineCount() == 1) "" else "s" });
                    },
                    .sel => {},
                    .stress => if (right) try context_menus.openStressMenu(app, m.x, m.y) else try runCmd(app, .@"perf.toast_stress"),
                    .bell => if (right) try context_menus.openBellMenu(app, m.x, m.y) else try runCmd(app, .@"messages.show"),
                    .clock => if (right) try clock_mod.openMenu(app, m.x, m.y) else try runCmd(app, if (app.clock.mode == .utc) .@"clock.local" else .@"clock.utc"),
                    .workspace => try runCmd(app, if (app.git.repos.items.len > 1) .@"git.switch_repo" else .@"view.switch_workspace"),
                    _ => {},
                } else if (seg >= statusline.seg_dyn_base and !right) {
                    // A host's segment: its `click_command`, on a left click.
                    try ipc.effects.clickSegment(app, seg - statusline.seg_dyn_base);
                },
            }
        },
        .dock => |d| try dock.mouse(app, d.id, d.part, m),
        .rail => |part| try activity_bar.mouse(app, part, m),
        .git_palette => |part| try git_palette.partMouse(app, part, m),
        .welcome => |row| {
            // The welcome pane: a recent file opens, a shortcut row runs
            // its command.
            if (wheel or m.kind != .press or m.button != .left) return;
            switch (row.kind) {
                .recent => if (render.welcomeRecentPath(app, row.idx)) |path| {
                    const copy = try app.frame.allocator().dupe(u8, path);
                    _ = app.openPath(copy) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {},
                    };
                },
                .shortcut => {
                    const rows = try render.welcomeShortcuts(app, app.frame.allocator());
                    if (row.idx < rows.len) try runCmd(app, rows[row.idx].command);
                },
            }
        },
        .button => |id| {
            // The strip's markers and `+`: a wheel scrolls the strip, a
            // press on a marker steps it.
            if (render.Button.tabScrollOf(id)) |ts| return tabStripStep(app, @intCast(ts.leaf), if (wheel) (if (m.kind == .scroll_down) @as(i8, 1) else -1) else (if (ts.dir == .right) @as(i8, 1) else -1));
            if (wheel) {
                if (render.Button.newTabLeaf(id)) |leaf_idx| return tabStripStep(app, @intCast(leaf_idx), if (m.kind == .scroll_down) 1 else -1);
                return;
            }
            if (m.kind != .press) return;
            // The strip's markdown chip (`render.drawMdChip`).
            if (id == md_preview.button_edit) return runCmd(app, .@"markdown.edit_raw");
            if (id == md_preview.button_preview) return runCmd(app, .@"markdown.preview");
            if (id == toast_mod.undo_button) {
                // The Undo chip: left commits the undo, right drops the offer.
                if (m.button == .right) app.dropUndo() else try app.takeUndo();
                return;
            }
            if (id >= toast_mod.button_base) {
                // Toasts: newest first as painted; index i is the i-th from the end.
                const i = id - toast_mod.button_base;
                if (i < app.toasts.items.len) {
                    const at = app.toasts.items.len - 1 - i;
                    if (m.button == .right) {
                        if (app.overlay != .none) closeOverlay(app);
                        return context_menus.openToastMenu(app, at, m.x, m.y);
                    }
                    app.dismissToastAt(at);
                }
                return;
            }
            if (app.overlay != .none) closeOverlay(app);
            // The palette bar's integration chips.
            if (id >= integrations_view.chip_base and id < integrations_view.chip_base + integrations_view.max_chips) {
                return integrations.chipClick(app, id - integrations_view.chip_base, m);
            }
            if (menu_bar.buttonOf(id)) |which| {
                const r = hitRect(app, m.x, m.y) orelse Rect.init(m.x, m.y, 1, 1);
                return menu_bar.open(app, which, r.x, m.y + 1);
            }
            if (id == menu_bar.overflow_button) {
                const r = hitRect(app, m.x, m.y) orelse Rect.init(m.x, m.y, 1, 1);
                return menu_bar.openOverflow(app, r.x, m.y + 1);
            }
            if (render.Button.newTabLeaf(id)) |leaf_idx| {
                if (m.button == .right) return context_menus.openNewTabMenu(app, m.x, m.y);
                // Git mode's `+` brings a closed repo back (Rust `git.reopen_repo`).
                if (app.git_palette.active) return runCmd(app, .@"git.reopen_repo");
                const layout = app.layouts.current();
                if (try layout.leafAt(app.frame.allocator(), leaf_idx)) |lid| {
                    if (layout.leaf(lid)) |leaf| app.setActive(leaf.active);
                }
                _ = app.openScratch() catch return error.OutOfMemory;
                return;
            }
            // The right cluster's tab-page chips: a chip shows its page,
            // the `×` on the active one closes it.
            if (render.Button.tabPageOf(id)) |page| return cmd_tab.switchTab(app, page);
            if (render.Button.tabPageCloseOf(id)) |page| {
                cmd_tab.switchTab(app, page);
                return runCmd(app, .@"tab.close");
            }
            switch (@as(render.Button, @enumFromInt(id))) {
                .palette => try runCmd(app, .palette),
                .toggle_tree => try runCmd(app, .@"view.toggle_tree"),
                .toggle_right_panel => try runCmd(app, .@"view.toggle_right_panel"),
                .back => try runCmd(app, .@"buffer.prev"),
                .forward => try runCmd(app, .@"buffer.next"),
                .dropdown => try runCmd(app, .@"picker.recent"),
                .new_tab_page => try runCmd(app, .@"tab.new"),
                .tabs_label => try runCmd(app, .@"tab.picker"),
                // The pill swaps to the configured alternate; without one
                // it opens the picker so the click never dead-ends.
                .theme_toggle => try runCmd(app, if (app.cfg.ui.theme_toggle != null) .@"theme.toggle" else .@"theme.pick"),
                .window_close => try runCmd(app, .@"app.quit"),
                // The strip's cluster acts on the leaf it sits on.
                .split_term => {
                    focusLeafAt(app, m.x, m.y);
                    try runCmd(app, .@"term.shell");
                },
                .split_right => {
                    focusLeafAt(app, m.x, m.y);
                    try runCmd(app, .@"view.split_right");
                },
                .split_down => {
                    focusLeafAt(app, m.x, m.y);
                    try runCmd(app, .@"view.split_down");
                },
                .split_max => {
                    focusLeafAt(app, m.x, m.y);
                    try runCmd(app, .@"view.zen");
                },
                .hidden_tabs => try runCmd(app, .@"picker.buffers"),
                .ai_claude => try runCmd(app, .@"ai.claude_code"),
                .ai_codex => try runCmd(app, .@"ai.codex"),
                else => {},
            }
        },
        .link => {},
    }
}

/// The pane whose rect holds `(x, y)` becomes active — a strip's
/// buttons act on their own leaf, wherever the focus was.
fn focusLeafAt(app: *App, x: u16, y: u16) void {
    for (app.hits.items.items) |h| if (h.target == .pane and h.rect.contains(x, y)) {
        app.setActive(h.target.pane);
        return;
    };
}

fn runCmd(app: *App, id: command.CommandId) Allocator.Error!void {
    command.run(app, .{ .static = id }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

/// A press on nothing: menus and the read-only overlays close, the
/// settings overlay keeps its writes and closes, a picker puts its
/// preview back (the themes picker) and closes.
fn pressOutside(app: *App) void {
    switch (app.overlay) {
        .menu, .info, .discovery, .help => closeOverlay(app),
        .settings => settings_app.close(app),
        .picker => {
            cmd_picker.cancel(app);
            closeOverlay(app);
        },
        else => {},
    }
}

// ── the editor: click, drag-select, double / triple ──

/// A left press in the text: shift extends the selection; a second
/// press within the double-click window selects the word, a third the
/// line; and the press anchors a drag-select at its granularity.
fn editorPress(app: *App, pane: PaneId, e: *EditorPane, byte: usize, m: Mouse) Allocator.Error!void {
    const ed = e.buf.editor;
    const now = app.now_ms;
    var count: u8 = 1;
    if (app.last_click) |lc| {
        if (lc.x == m.x and lc.y == m.y and now - lc.at_ms <= app_mod.double_click_ms) count = @min(lc.count + 1, 3);
    }
    app.last_click = .{ .at_ms = now, .x = m.x, .y = m.y, .count = count };
    if (m.mods.shift) {
        if (ed.anchor == null) ed.anchor = ed.cursor;
        ed.setCursor(byte);
        app.drag = .{ .select = .{ .pane = pane, .unit = .char, .anchor = ed.anchor.? } };
        return;
    }
    const unit: app_mod.SelectUnit = switch (count) {
        1 => .char,
        2 => .word,
        else => .line,
    };
    ed.anchor = null;
    ed.setCursor(byte);
    switch (unit) {
        .char => {},
        .word => {
            const b = select.wordBoundsAt(ed, byte);
            if (b[1] > b[0]) ed.setSelection(b[0], b[1]);
        },
        .line => {
            const line = ed.lineOfByte(byte);
            ed.setSelection(ed.lineStart(line), @min(ed.lineEnd(line) + 1, ed.len()));
        },
    }
    if (ed.anchor != null) e.buf.input.requestVisualMode();
    app.drag = .{ .select = .{ .pane = pane, .unit = unit, .anchor = byte } };
}

/// The byte under a pointer cell of an editor, if the cell is one.
fn byteUnder(app: *App, pane: PaneId, x: u16, y: u16) ?usize {
    const e = app.panes.editor(pane) orelse return null;
    const ed = e.buf.editor;
    const entry = app.hits.entryAt(x, y) orelse return null;
    const cell = switch (entry.target) {
        .editor_cell => |c| c,
        else => return null,
    };
    if (cell.pane != pane) return null;
    const line = @min(cell.line, ed.lineCount() - 1);
    const col = cell.col + (x - entry.rect.x);
    return @min(ed.byteAtCol(line, col), ed.lineEnd(line));
}

fn extendSelection(app: *App, sel: anytype, x: u16, y: u16) void {
    const e = app.panes.editor(sel.pane) orelse return;
    const ed = e.buf.editor;
    // Off the text (the strip, the gutter row above / below): clamp to
    // the nearest line's edge so a drag past the pane still selects.
    const to = byteUnder(app, sel.pane, x, y) orelse blk: {
        const r = app.panes_area;
        if (y < r.y + 1) break :blk @as(usize, 0);
        if (y >= r.bottom()) break :blk ed.len();
        break :blk ed.cursor;
    };
    switch (sel.unit) {
        .char => {
            ed.anchor = sel.anchor;
            ed.setCursor(to);
        },
        .word => {
            const a = select.wordBoundsAt(ed, sel.anchor);
            const b = select.wordBoundsAt(ed, to);
            if (to >= sel.anchor) ed.setSelection(a[0], @max(b[1], a[1])) else ed.setSelection(a[1], @min(b[0], a[0]));
        },
        .line => {
            const la = ed.lineOfByte(sel.anchor);
            const lb = ed.lineOfByte(to);
            const lo = @min(la, lb);
            const hi = @max(la, lb);
            if (to >= sel.anchor) ed.setSelection(ed.lineStart(lo), @min(ed.lineEnd(hi) + 1, ed.len())) else ed.setSelection(@min(ed.lineEnd(hi) + 1, ed.len()), ed.lineStart(lo));
        },
    }
    if (ed.anchor != null and ed.anchor.? != ed.cursor) e.buf.input.requestVisualMode();
}

// ── wheel ──

/// The wheel scrolls the pane under the pointer, `wheel_lines` per
/// notch: vim moves the cursor (the view follows), standard moves the
/// viewport and pins it there until the cursor moves. Shift scrolls
/// sideways.
fn wheelOnPane(app: *App, id: PaneId, m: Mouse, count: u16) Allocator.Error!void {
    const pane = app.panes.get(id) orelse return;
    const n: usize = @as(usize, app.cfg.ui.wheel_lines) * @max(count, 1);
    const down = m.kind == .scroll_down;
    switch (pane.*) {
        .editor => |*e| {
            const ed = e.buf.editor;
            if (m.mods.shift) {
                const cur: usize = e.view.scroll_col;
                e.view.scroll_col = @intCast(if (down) cur + n else cur -| n);
                e.view.pinAt(ed.cursor);
                return;
            }
            if (e.buf.input.mode() != .none) {
                var i: usize = 0;
                while (i < n) : (i += 1) _ = try app.applyOps(e, &.{if (down) .move_down else .move_up});
                return;
            }
            const max: i64 = @intCast(ed.lineCount() -| 1);
            const cur: i64 = e.view.scroll_line;
            const delta: i64 = @intCast(n);
            e.view.scroll_line = @intCast(std.math.clamp(if (down) cur + delta else cur - delta, 0, max));
            e.view.pinAt(ed.cursor);
        },
        .cheatsheet => |*c| {
            c.selected = if (down) c.selected + n else c.selected -| n;
        },
        .script => |*s| script_pane.wheel(app, s, down, n),
        .list => |*l| {
            l.cursor = if (down) @min(l.cursor + n, l.entries.items.len -| 1) else l.cursor -| n;
        },
        .outline => |*o| {
            o.cursor = if (down) @min(o.cursor + n, o.items.items.len -| 1) else o.cursor -| n;
        },
        .md_preview => |*mp| md_preview.scrollBy(app, mp, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .pty => |*p| p.scrollBy(if (down) @as(i32, @intCast(n)) else -@as(i32, @intCast(n))),
        .git_status => |*s| git_app.statusPaneWheel(app, s, down, n),
        .diff => |*d| git_app.stepDiff(d, if (down) @as(isize, @intCast(n)) else -@as(isize, @intCast(n))),
        .git_graph => |*g| g.cursor = if (down) @min(g.cursor + n, g.totalRows() -| 1) else g.cursor -| n,
        .ai => |*a| ai_app.scrollBy(a, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .claude_agents => |*a| agents.scrollBy(a, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .spend_report => |*s| spend.scrollBy(s, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .grep => |*g| grep.scrollBy(g, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .debug, .dap_repl => try dap.scrollBy(app, id, if (down) @as(i32, @intCast(n)) else -@as(i32, @intCast(n))),
        .request => |*rp| request_pane.scrollBy(rp, if (down) @as(i32, @intCast(n)) else -@as(i32, @intCast(n))),
        .websocket => |*w| ws_pane.scrollBy(w, if (down) @as(i32, @intCast(n)) else -@as(i32, @intCast(n))),
        .browser => |*b| browser_pane.scrollBy(b, if (down) @as(i32, @intCast(n)) else -@as(i32, @intCast(n))),
        // Reached only over a rect the view did not register (none): the
        // mount's rows carry the wheel through `.script_hit`.
        .mount => {},
        .integrations => |*ip| integrations.scrollBy(app, ip, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .marketplace => |*mk| marketplace.scrollBy(app, mk, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .ai_apply => |*ap| ai_apply.scrollBy(ap, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .tests => |*tp| tests_pane.scrollBy(tp, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .flaky => |*fp| flaky.scrollBy(fp, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .files => |*f| files_pane.scrollBy(f, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .image => {},
    }
}

// ── gestures ──

fn beginDividerDrag(app: *App, id: u32) Allocator.Error!void {
    if (id == render.tree_divider_id) {
        app.drag = .tree_divider;
        return;
    }
    if (id == render.right_divider_id) {
        app.drag = .right_divider;
        return;
    }
    const rects = try app.layouts.current().computeRects(app.panes_area, app.frame.allocator());
    if (id >= rects.dividers.len) return;
    const d = rects.dividers[id];
    app.drag = .{ .divider = .{ .split = d.split, .dir = d.dir } };
}

fn beginScrollbarDrag(app: *App, id: PaneId, track: Rect, y: u16) Allocator.Error!void {
    const e = app.panes.editor(id) orelse return;
    const total = e.buf.editor.lineCount();
    const th = scrollbar.thumb(track.h, total, app.pane_rows, e.view.scroll_line);
    const rel = y -| track.y;
    const grab: u16 = if (th) |tt| (if (rel >= tt.start and rel < tt.start + tt.len) rel - tt.start else tt.len / 2) else 0;
    app.drag = .{ .scrollbar = .{ .pane = id, .grab = grab } };
    if (app.active != id) app.showPane(id);
    dragScrollbar(app, id, grab, y);
}

/// The thumb follows the pointer; the cursor stays where it is.
fn dragScrollbar(app: *App, id: PaneId, grab: u16, y: u16) void {
    const e = app.panes.editor(id) orelse return;
    const track = scrollbarTrack(app, id) orelse return;
    const total = e.buf.editor.lineCount();
    const viewport = @max(app.pane_rows, 1);
    if (total <= viewport) return;
    const th = scrollbar.thumb(track.h, total, viewport, e.view.scroll_line) orelse return;
    const max_start = track.h - th.len;
    const start: u16 = @min((y -| track.y) -| grab, max_start);
    const max_scroll = total - viewport;
    e.view.scroll_line = @intCast(if (max_start == 0) 0 else (@as(usize, start) * max_scroll) / max_start);
    e.view.pinAt(e.buf.editor.cursor);
}

/// The wheel over the tree steps its cursor.
fn treeWheel(app: *App, m: Mouse, count: u16) void {
    switch (m.kind) {
        .scroll_up => app.tree.cursor -|= app.cfg.ui.wheel_lines * count,
        .scroll_down => app.tree.cursor = @min(app.tree.cursor + app.cfg.ui.wheel_lines * count, app.tree.rows.items.len -| 1),
        else => {},
    }
}

fn scrollbarTrack(app: *App, id: PaneId) ?Rect {
    for (app.hits.items.items) |h| switch (h.target) {
        .scrollbar => |sb| switch (sb.owner) {
            .pane => |p| if (p == id and sb.axis == .v) return h.rect,
            .panel, .tree => {},
        },
        else => {},
    };
    return null;
}

/// A drag or a release while a gesture is in flight.
fn continueDrag(app: *App, m: Mouse) Allocator.Error!void {
    const d = &(app.drag orelse return);
    switch (d.*) {
        .divider => |dv| if (m.kind == .drag) {
            const rects = try app.layouts.current().computeRects(app.panes_area, app.frame.allocator());
            for (rects.dividers) |dr| if (dr.split == dv.split) {
                const ratio = switch (dv.dir) {
                    .horizontal => layout_mod.ratioAt(dr.area.w, m.x -| dr.area.x),
                    .vertical => layout_mod.ratioAt(dr.area.h, m.y -| dr.area.y),
                };
                app.layouts.current().setRatio(dv.split, ratio);
            };
        },
        .tree_divider => if (m.kind == .drag) {
            const upper_w = app.screen.width;
            app.tree.width = std.math.clamp(m.x, 8, upper_w -| 22);
        },
        .right_divider => if (m.kind == .drag) {
            app.right_panel_width = std.math.clamp(app.screen.width -| (m.x + 1), 8, app.screen.width -| 22);
        },
        .graph_divider => |id| if (m.kind == .drag) git_app.dragGraphDivider(app, id, m.x),
        .select => |sel| {
            extendSelection(app, sel, m.x, m.y);
            // A press-and-release on one cell is a click: no selection.
            if (m.kind == .release) if (app.panes.editor(sel.pane)) |e| {
                if (e.buf.editor.anchor != null and e.buf.editor.anchor.? == e.buf.editor.cursor) e.buf.editor.anchor = null;
            };
        },
        .scrollbar => |sb| dragScrollbar(app, sb.pane, sb.grab, m.y),
        .dock => |*dd| return dock.continueDrag(app, dd, m),
        .tab => |*tb| {
            if (m.kind == .drag) {
                if (tb.x != m.x or tb.y != m.y) tb.moved = true;
                return;
            }
            const pane = tb.pane;
            const moved = tb.moved;
            app.drag = null;
            if (moved) try dropTab(app, pane, m.x, m.y);
            return;
        },
        .tree => |*tr| {
            if (m.kind == .drag) {
                if (app.hits.at(m.x, m.y)) |h| switch (h) {
                    .tree_node => |i| if (i != tr.idx) {
                        tr.moved = true;
                    },
                    else => tr.moved = true,
                };
                return;
            }
            const idx = tr.idx;
            const moved = tr.moved;
            const copy = tr.copy or m.mods.alt;
            app.drag = null;
            if (!moved) return app.tree.activate(app, idx);
            return dropTreeFile(app, idx, m.x, m.y, copy);
        },
    }
    if (m.kind == .release) app.drag = null;
}

/// A tab released: on a strip → reorder into that leaf at the pointer;
/// on a pane body → split it (edge) or move in (centre). Anywhere else
/// is a no-op — the pane stays where it was.
fn dropTab(app: *App, pane: PaneId, x: u16, y: u16) Allocator.Error!void {
    const layout = app.layouts.current();
    const arena = app.frame.allocator();
    const rects = try layout.computeRects(app.panes_area, arena);
    for (rects.panes, 0..) |pr, li| {
        if (!pr.rect.contains(x, y)) continue;
        if (pr.rect.h >= 2 and y == pr.rect.y) {
            // The strip: the slot before the first tab whose centre is right of x.
            const src_leaf = layout.leafOf(pane) orelse return;
            const strip = pr.rect.row(0);
            const ui = app.frameUi();
            const tabs = try render.tabsOf(app, ui, layout, pr.leaf);
            var slot_buf: [64]bufferline.Slot = undefined;
            const slots = bufferline.slotsFrom(ui, strip, tabs, layout.leaf(pr.leaf).?.strip_first, &slot_buf);
            // Rust `tab_strip_insert_idx`: the slot before the first chip
            // whose three-quarter point is right of x, applied after the
            // dragged tab is taken out (`reorderTab`) — so a drop past a
            // neighbour's middle lands after it, and one on its own chip
            // stays put.
            var insert: usize = tabs.len;
            for (slots) |sl| if (x < sl.x + sl.w * 3 / 4) {
                insert = sl.idx;
                break;
            };
            if (src_leaf == pr.leaf) {
                layout.reorderTab(pane, insert);
            } else {
                if (layout.leaf(pr.leaf).?.tabs.items.len == 0) return;
                _ = layout.removePane(pane);
                const leaf = layout.leaf(pr.leaf) orelse return app.showPane(pane);
                const at = @min(insert, leaf.tabs.items.len);
                try leaf.tabs.insert(app.gpa, at, pane);
                leaf.active = pane;
            }
            app.setActive(pane);
            _ = li;
            return;
        }
        const body = if (pr.rect.h >= 2) pr.rect.splitTop(1).rest else pr.rect;
        const zone = layout_mod.zoneFor(body, x, y);
        return dropIntoLeaf(app, pane, pr.leaf, zone);
    }
}

/// `pane` lands beside leaf `target` (an edge zone splits it) or in
/// it (the centre: a tab). Dropping a leaf's only tab onto that leaf
/// is a no-op — the pane stays where it is.
fn dropIntoLeaf(app: *App, pane: PaneId, target: layout_mod.NodeId, zone: layout_mod.DropZone) Allocator.Error!void {
    const layout = app.layouts.current();
    const src_leaf = layout.leafOf(pane);
    const same = src_leaf != null and src_leaf.? == target;
    if (zone == .center) {
        if (same) return;
        _ = layout.removePane(pane);
        const leaf = layout.leaf(target) orelse return app.showPane(pane);
        try leaf.tabs.append(app.gpa, pane);
        leaf.active = pane;
        app.setActive(pane);
        return;
    }
    // The dragged pane leaves its leaf; the target splits; the new leaf
    // takes the pane, swapped to the near side for left / top.
    if (same and layout.leaf(target).?.tabs.items.len == 1) return;
    _ = layout.removePane(pane);
    const leaf = layout.leaf(target) orelse return app.showPane(pane);
    const dir: layout_mod.SplitDir = switch (zone) {
        .left, .right => .horizontal,
        .top, .bottom => .vertical,
        .center => unreachable,
    };
    const new_leaf = (try layout.split(leaf.active, dir, pane)) orelse return app.showPane(pane);
    app.afterSplitChange();
    if (zone == .left or zone == .top) {
        // The split put the new leaf second; swap the halves.
        const parent = layout.parentOf(new_leaf) orelse return app.setActive(pane);
        const sp = &layout.node(parent).split;
        std.mem.swap(layout_mod.NodeId, &sp.first, &sp.second);
    }
    app.setActive(pane);
}

/// A tree file released: on a folder row → confirm a move; on a pane →
/// open it there (a zone splits); elsewhere → open it.
/// A tree row released: on a directory row → the move (an Alt-drag:
/// copy) confirm; on a pane → the file opens there.
fn dropTreeFile(app: *App, idx: usize, x: u16, y: u16, copy: bool) Allocator.Error!void {
    if (idx >= app.tree.rows.items.len) return;
    if (app.hits.at(x, y)) |h| switch (h) {
        .tree_node => |into| {
            if (into < app.tree.rows.items.len and app.tree.rows.items[into].is_dir) return tree_mod.confirmMove(app, idx, into, copy);
            return;
        },
        else => {},
    };
    const row = app.tree.rows.items[idx];
    const rel = try app.frame.allocator().dupe(u8, row.rel);
    const abs = try app.absPath(rel);
    const layout = app.layouts.current();
    const rects = try layout.computeRects(app.panes_area, app.frame.allocator());
    for (rects.panes) |pr| {
        if (!pr.rect.contains(x, y)) continue;
        const body = if (pr.rect.h >= 2) pr.rect.splitTop(1).rest else pr.rect;
        const zone = layout_mod.zoneFor(body, x, y);
        app.setActive(pr.pane);
        const id = app.openPath(abs) catch |err| {
            app.toast("open {s}: {s}", .{ rel, @errorName(err) });
            return;
        };
        if (zone != .center and id != pr.pane) try dropIntoLeaf(app, id, pr.leaf, zone);
        return;
    }
    _ = app.openPath(abs) catch |err| app.toast("open {s}: {s}", .{ rel, @errorName(err) });
}

fn hitRect(app: *App, x: u16, y: u16) ?Rect {
    return if (app.hits.entryAt(x, y)) |e| e.rect else null;
}

/// Enter on a list pane row: the cmdline history re-runs the line, the
/// quickfix and location lists open the file at the row.
pub fn listPaneEnter(app: *App, pane: PaneId, l: *app_mod.ListPane) Allocator.Error!void {
    if (l.cursor >= l.entries.items.len) return;
    const e = l.entries.items[l.cursor];
    switch (l.kind) {
        .cmdline_history => {
            const line = try app.frame.allocator().dupe(u8, e.text);
            try app.forceClosePane(pane);
            try runExLine(app, line);
        },
        .quickfix, .location => {
            // changed: the location list shares the quickfix row action; the
            // owning editor's index follows the row so `:lnext` continues from it.
            if (l.kind == .location) @import("loclist.zig").noteEnter(app, l.cursor);
            const rel = try app.frame.allocator().dupe(u8, e.path orelse return);
            const abs = try app.absPath(rel);
            const line = e.line;
            const col = e.col;
            const id = app.openPath(abs) catch |err| {
                app.toast("open {s}: {s}", .{ rel, @errorName(err) });
                return;
            };
            if (app.panes.editor(id)) |ed| ed.buf.editor.placeCursor(line -| 1, col -| 1);
        },
    }
}

// ─── AppCommand ─────────────────────────────────────────────────────────

pub fn handleAppCommand(app: *App, pane_id: PaneId, e: *EditorPane, cmd: input.AppCommand) Allocator.Error!void {
    switch (cmd) {
        .save => cmd_file.saveCurrent(app) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .ex_command, .cmdline_enter => |line| try runExLine(app, line),
        .run_command => |id| command.run(app, .{ .static = id }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        // Uppercase marks reach here; the buffer answered lowercase ones.
        .set_mark => |c| if (marks_store.isGlobal(c)) try marks_store.set(app, e, c),
        .jump_to_mark_line => |c| if (marks_store.isGlobal(c)) try marks_store.jump(app, c, false),
        .jump_to_mark_exact => |c| if (marks_store.isGlobal(c)) try marks_store.jump(app, c, true),
        // Buffer-local; the buffer answered them before we got here.
        .dot_repeat, .macro_record_into, .macro_replay_from, .operator_to_mark => {},
        .block_insert_start => |b| try beginBlockInsert(app, pane_id, e, b.append, false),
        .block_change_start => try beginBlockInsert(app, pane_id, e, false, true),
        .block_replace_with => |r| try blockReplace(app, e, r.ch),
        .filter_lines_from_cursor => |f| {
            const row = e.buf.editor.currentLine();
            const last = @min(row + @max(f.count, 1) - 1, e.buf.editor.lineCount() - 1);
            try openFilterPrompt(app, row, last);
        },
        .filter_paragraph_from_cursor => |p| {
            const range = paragraphRows(e.buf.editor, p.around);
            try openFilterPrompt(app, range[0], range[1]);
        },
        .repeat_insert_start => |r| try beginRepeatInsert(app, pane_id, e, r.count, r.above),
        .operator_linewise_to => |o| try linewiseOp(app, e, o.op, o.target),
        .cmdline_tab_complete => try cmdlineTabComplete(app, e),
        .cmdline_popup_move => |d| try cmdlineCycle(app, e, d),
        .cmdline_insert_cursor_word => |big| try cmdlineInsertWord(app, e, big),
        .cmdline_paste_from_clipboard => try cmdlineInsert(app, e, app.clipboard.text()),
        .flash_start => |f| try flash.start(app, pane_id, e, f.a, f.b),
        .tab_page => |tp| cmd_tab.gotoPage(app, tp.count, tp.back),
        .split_resize => |r| cmd_view.resizeByCells(app, r.width, r.cells) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .fold_after => |list| {
            _ = try app.applyOps(e, list);
            command.run(app, .{ .static = .@"editor.fold_selection" }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        },
    }
}

/// Run an ex line; a failure toasts the reason (or the error name).
pub fn runExLine(app: *App, line: []const u8) Allocator.Error!void {
    try app.noteCmdLine(line);
    app.diag.clear();
    ex.run(app, line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => {},
        else => {
            if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast(":{s} — {s}", .{ line, @errorName(err) });
        },
    };
}

// ── visual block ──

fn blockRect(e: *const EditorPane) ?struct { r0: usize, r1: usize, c0: usize, c1: usize } {
    const ed = e.buf.editor;
    const anchor = ed.block_anchor orelse e.block_anchor orelse return null;
    const a = ed.rowColAt(anchor);
    const b = ed.rowCol();
    return .{ .r0 = @min(a.row, b.row), .r1 = @max(a.row, b.row), .c0 = @min(a.col, b.col), .c1 = @max(a.col, b.col) };
}

/// `I` / `A` / `c` on a visual block: (for `c`) cut the rectangle, put
/// the cursor on the first row at the insert column, enter Insert, and
/// remember the rectangle so the typed run is replayed on Esc.
fn beginBlockInsert(app: *App, pane_id: PaneId, e: *EditorPane, append: bool, change: bool) Allocator.Error!void {
    const ed = e.buf.editor;
    const eol = ed.block_eol;
    ed.block_eol = false;
    const rect = blockRect(e) orelse {
        ed.block_anchor = null;
        e.buf.input.requestInsertMode();
        return;
    };
    e.block_anchor = null;
    ed.block_anchor = null;
    var col = if (append) rect.c1 + 1 else rect.c0;
    if (change) {
        // Delete the rectangle bottom-up so earlier offsets stay valid.
        var row = rect.r1 + 1;
        try ed.checkpoint();
        while (row > rect.r0) {
            row -= 1;
            const s = ed.byteAtCol(row, rect.c0);
            const en = if (eol) ed.lineEnd(row) else @min(ed.byteAtCol(row, rect.c1 + 1), ed.lineEnd(row));
            if (en > s) try ed.splice(s, en, "");
        }
        col = rect.c0;
        e.syntax.dirty = true;
    }
    // `$A`: append at every row's own end.
    const ragged = eol and append and !change;
    const start = if (ragged) ed.lineEnd(rect.r0) else @min(ed.byteAtCol(rect.r0, col), ed.lineEnd(rect.r0));
    ed.setCursor(start);
    ed.anchor = null;
    e.buf.input.requestInsertMode();
    app.block_insert = .{ .pane = pane_id, .first_row = rect.r0, .last_row = rect.r1, .col = col, .start_byte = start, .len_before = ed.len(), .eol = ragged };
}

/// `r<ch>` on a visual block: every cell in the rectangle becomes `ch`.
fn blockReplace(app: *App, e: *EditorPane, ch: u21) Allocator.Error!void {
    const ed = e.buf.editor;
    const eol = ed.block_eol;
    ed.block_eol = false;
    const rect = blockRect(e) orelse return;
    e.block_anchor = null;
    ed.block_anchor = null;
    ed.anchor = null;
    var glyph: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(ch, &glyph) catch return;
    try ed.checkpoint();
    var row = rect.r1 + 1;
    while (row > rect.r0) {
        row -= 1;
        // A ragged block replaces to each row's last char.
        var c = if (eol) ed.colAtByte(ed.lineEnd(row)) else rect.c1 + 1;
        if (eol and c <= rect.c0) continue;
        while (c > rect.c0) {
            c -= 1;
            const s = ed.byteAtCol(row, c);
            if (s >= ed.lineEnd(row)) continue;
            const cp_len = std.unicode.utf8ByteSequenceLength(ed.bytes()[s]) catch 1;
            try ed.splice(s, s + cp_len, glyph[0..n]);
        }
    }
    ed.setCursor(ed.byteAtCol(rect.r0, rect.c0));
    e.buf.doc.dirty = !std.mem.eql(u8, ed.bytes(), e.buf.doc.saved_text);
    e.syntax.dirty = true;
    _ = app;
}

/// `<count>o` / `<count>O`: open one line now, replicate on Esc.
fn beginRepeatInsert(app: *App, pane_id: PaneId, e: *EditorPane, count: u32, above: bool) Allocator.Error!void {
    e.buf.input.requestInsertMode();
    _ = try app.applyOps(e, &.{if (above) .insert_newline_above else .insert_newline_below});
    const ed = e.buf.editor;
    app.repeat_insert = .{ .pane = pane_id, .count = count, .above = above, .start_byte = ed.cursor, .len_before = ed.len() };
}

/// Once Insert mode ends, replay the typed run for the block insert /
/// counted `o` that started it. Called after every key and from `tick`.
pub fn finishDeferredInserts(app: *App) Allocator.Error!void {
    if (app.block_insert) |b| {
        const e = app.panes.editor(b.pane) orelse {
            app.block_insert = null;
            return;
        };
        if (e.buf.input.mode() == .insert) return;
        app.block_insert = null;
        const ed = e.buf.editor;
        if (ed.len() < b.len_before) return;
        const typed_len = ed.len() - b.len_before;
        if (typed_len == 0 or b.start_byte + typed_len > ed.len()) return;
        const typed = try app.frame.allocator().dupe(u8, ed.bytes()[b.start_byte .. b.start_byte + typed_len]);
        if (std.mem.indexOfScalar(u8, typed, '\n') != null) return;
        var row = b.last_row + 1;
        while (row > b.first_row + 1) {
            row -= 1;
            if (row >= ed.lineCount()) continue;
            const at = if (b.eol) ed.lineEnd(row) else @min(ed.byteAtCol(row, b.col), ed.lineEnd(row));
            try ed.splice(at, at, typed);
        }
        ed.setCursor(b.start_byte);
        e.buf.doc.dirty = !std.mem.eql(u8, ed.bytes(), e.buf.doc.saved_text);
        e.syntax.dirty = true;
        app.needs_render = true;
    }
    if (app.repeat_insert) |r| {
        const e = app.panes.editor(r.pane) orelse {
            app.repeat_insert = null;
            return;
        };
        if (e.buf.input.mode() == .insert) return;
        app.repeat_insert = null;
        const ed = e.buf.editor;
        if (ed.len() < r.len_before) return;
        const typed_len = ed.len() - r.len_before;
        if (r.start_byte + typed_len > ed.len()) return;
        const typed = try app.frame.allocator().dupe(u8, ed.bytes()[r.start_byte .. r.start_byte + typed_len]);
        const line = ed.lineOfByte(r.start_byte);
        var i: u32 = 1;
        while (i < r.count) : (i += 1) {
            if (r.above) {
                const at = ed.lineStart(line);
                const with_nl = try std.mem.concat(app.frame.allocator(), u8, &.{ typed, "\n" });
                try ed.splice(at, at, with_nl);
            } else {
                const at = ed.lineEnd(line + i - 1);
                const with_nl = try std.mem.concat(app.frame.allocator(), u8, &.{ "\n", typed });
                try ed.splice(at, at, with_nl);
            }
        }
        e.buf.doc.dirty = !std.mem.eql(u8, ed.bytes(), e.buf.doc.saved_text);
        e.syntax.dirty = true;
        app.needs_render = true;
    }
}

// ── linewise operators to a line target ──

/// `dG` / `dgg` / `<n>dG` / `yG`…: `target` null = last line, 0 = first,
/// n = 1-based line. Whole lines, inclusive, into the unnamed register.
fn linewiseOp(app: *App, e: *EditorPane, op: u8, target: ?u32) Allocator.Error!void {
    const ed = e.buf.editor;
    const total = ed.lineCount();
    const cur = ed.currentLine();
    const tgt: usize = if (target) |t| @min(@as(usize, t) -| 1, total - 1) else total - 1;
    const r0 = @min(cur, tgt);
    const r1 = @max(cur, tgt);
    const start = ed.lineStart(r0);
    const end = ed.lineEnd(r1);
    const text = ed.bytes()[start..end];
    var copy = try app.frame.allocator().alloc(u8, text.len + 1);
    @memcpy(copy[0..text.len], text);
    copy[text.len] = '\n';
    switch (op) {
        'y' => {
            try app.clipboard.setYank(copy, true);
            ed.setCursor(ed.firstNonWs(r0));
        },
        'd' => {
            try app.clipboard.pushDelete(copy, true);
            // Take the trailing newline, or the leading one on the last line.
            const del_start = if (end < ed.len()) start else if (start > 0) start - 1 else start;
            const del_end = if (end < ed.len()) end + 1 else end;
            try ed.checkpoint();
            try ed.splice(del_start, del_end, "");
            const row = @min(r0, ed.lineCount() - 1);
            ed.setCursor(ed.firstNonWs(row));
            e.buf.doc.dirty = !std.mem.eql(u8, ed.bytes(), e.buf.doc.saved_text);
            e.syntax.dirty = true;
        },
        else => {},
    }
    app.needs_render = true;
}

// ── filter through a shell command ──

fn paragraphRows(ed: anytype, around: bool) [2]usize {
    const total = ed.lineCount();
    var r0 = ed.currentLine();
    var r1 = r0;
    while (r0 > 0 and !ed.lineIsBlank(r0 - 1)) r0 -= 1;
    while (r1 + 1 < total and !ed.lineIsBlank(r1 + 1)) r1 += 1;
    if (around) while (r1 + 1 < total and ed.lineIsBlank(r1 + 1)) {
        r1 += 1;
    };
    return .{ r0, r1 };
}

fn openFilterPrompt(app: *App, first: usize, last: usize) Allocator.Error!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = Prompt.init(app.gpa, "! filter lines through"), .purpose = .filter_shell } };
    app.filter_rows = .{ first, last };
    app.focus = .overlay;
}

fn filterThroughShell(app: *App, cmd: []const u8) Allocator.Error!void {
    const rows = app.filter_rows orelse return;
    app.filter_rows = null;
    const e = app.activeEditor() orelse return;
    const ed = e.buf.editor;
    const start = ed.lineStart(@min(rows[0], ed.lineCount() - 1));
    const end = ed.lineEnd(@min(rows[1], ed.lineCount() - 1));
    const gpa = app.gpa;
    const shell = "/bin/sh";
    var child = std.process.spawn(app.io, .{ .argv = &.{ shell, "-c", cmd }, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe }) catch |err| {
        app.toast("!{s}: {s}", .{ cmd, @errorName(err) });
        return;
    };
    if (child.stdin) |stdin| {
        var wbuf: [4096]u8 = undefined;
        var w: std.Io.File.Writer = .init(stdin, app.io, &wbuf);
        w.interface.writeAll(ed.bytes()[start..end]) catch {};
        w.interface.writeByte('\n') catch {};
        w.interface.flush() catch {};
        stdin.close(app.io);
        child.stdin = null;
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    if (child.stdout) |stdout| {
        var rbuf: [4096]u8 = undefined;
        var r: std.Io.File.Reader = .init(stdout, app.io, &rbuf);
        while (true) {
            var chunk: [4096]u8 = undefined;
            const n = r.interface.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            try out.appendSlice(gpa, chunk[0..n]);
        }
    }
    _ = child.wait(app.io) catch {};
    const trimmed = std.mem.trimEnd(u8, out.items, "\n");
    const copy = try app.frame.allocator().dupe(u8, trimmed);
    try app.splice(e, start, end, copy);
    app.toast("!{s} — {d} line(s)", .{ cmd, std.mem.count(u8, copy, "\n") + 1 });
}

// ── the `:` line ──

const ex_names = [_][]const u8{ "write", "wq", "quit", "edit", "bdelete", "bnext", "bprev", "sort", "retab", "substitute", "set", "registers", "marks", "abbreviate", "unabbreviate", "noh", "tabclose", "tabnew", "tabnext", "tabprev", "tabfirst", "tablast", "global", "vglobal", "normal", "command", "delcommand", "read" };
const path_commands = [_][]const u8{ "e", "edit", "w", "write", "sp", "split", "vs", "vsplit", "tabe", "tabedit", "r", "read", "cd", "saveas" };

/// Tab on the `:` line. First press builds the candidates for the text
/// so far (registry ids score: prefix 300 / contains 200, ex names 150,
/// ties alphabetical); later presses cycle.
fn cmdlineTabComplete(app: *App, e: *EditorPane) Allocator.Error!void {
    const line = e.buf.input.cmdlineGet() orelse return;
    if (app.cmd_complete) |*c| {
        if (std.mem.eql(u8, c.prefix, line) or (c.candidates.len > 0 and std.mem.eql(u8, c.candidates[c.idx], line))) {
            return cmdlineCycle(app, e, 1);
        }
        c.deinit(app.gpa);
        app.cmd_complete = null;
    }
    const gpa = app.gpa;
    var cands: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (cands.items) |c| gpa.free(c);
        cands.deinit(gpa);
    }
    if (std.mem.indexOfScalar(u8, line, ' ')) |sp| {
        // `<cmd> <partial path>` → workspace entries.
        const head = line[0..sp];
        const partial = line[sp + 1 ..];
        if (std.mem.eql(u8, head, "set") or std.mem.eql(u8, head, "se")) {
            // `:set <option>` — every discrete config field (ex.zig).
            const names = try ex.completeSet(gpa, partial);
            defer {
                for (names) |n| gpa.free(n);
                gpa.free(names);
            }
            for (names) |n| try cands.append(gpa, try std.mem.concat(gpa, u8, &.{ head, " ", n }));
            if (cands.items.len == 0) return;
            const prefix = try gpa.dupe(u8, line);
            errdefer gpa.free(prefix);
            app.cmd_complete = .{ .prefix = prefix, .candidates = try cands.toOwnedSlice(gpa), .idx = 0 };
            try e.buf.input.cmdlineSet(app.cmd_complete.?.candidates[0]);
            return;
        }
        var is_path_cmd = false;
        for (path_commands) |p| if (std.mem.eql(u8, p, head)) {
            is_path_cmd = true;
        };
        if (!is_path_cmd) return;
        var paths: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (paths.items) |c| gpa.free(c);
            paths.deinit(gpa);
        }
        try pathCandidates(app, gpa, partial, false, &paths);
        for (paths.items) |rel| try cands.append(gpa, try std.mem.concat(gpa, u8, &.{ head, " ", rel }));
    } else {
        const Scored = struct { name: []const u8, score: u32 };
        var scored: std.ArrayListUnmanaged(Scored) = .empty;
        defer scored.deinit(gpa);
        var i: usize = 0;
        while (i < command.count) : (i += 1) {
            const id = command.name(@enumFromInt(i));
            if (std.mem.startsWith(u8, id, line)) {
                try scored.append(gpa, .{ .name = id, .score = 300 });
            } else if (std.mem.indexOf(u8, id, line) != null) {
                try scored.append(gpa, .{ .name = id, .score = 200 });
            }
        }
        for (ex_names) |n| if (std.mem.startsWith(u8, n, line)) try scored.append(gpa, .{ .name = n, .score = 150 });
        // User `:command`s outrank the registry: they are the user's own words.
        for (try ex_verbs.sortedNames(app, app.frame.allocator(), line)) |n| try scored.append(gpa, .{ .name = n, .score = 400 });
        std.mem.sort(Scored, scored.items, {}, struct {
            fn lt(_: void, a: Scored, b: Scored) bool {
                if (a.score != b.score) return a.score > b.score;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
        for (scored.items) |s| try cands.append(gpa, try gpa.dupe(u8, s.name));
    }
    if (cands.items.len == 0) return;
    const prefix = try gpa.dupe(u8, line);
    errdefer gpa.free(prefix);
    app.cmd_complete = .{ .prefix = prefix, .candidates = try cands.toOwnedSlice(gpa), .idx = 0 };
    try e.buf.input.cmdlineSet(app.cmd_complete.?.candidates[0]);
}

/// Every entry whose name starts with the last segment of `partial`,
/// spelled the way the user typed the rest (`~/pro` → `~/projects/`,
/// `src/ma` → `src/main.zig`), sorted; a directory ends in `/`. A
/// relative path is under the workspace. Dot entries stay hidden
/// unless the segment asks for them. `dirs_only` drops files.
fn pathCandidates(app: *App, gpa: Allocator, partial: []const u8, dirs_only: bool, out: *std.ArrayListUnmanaged([]u8)) Allocator.Error!void {
    const arena = app.frame.allocator();
    const cut = if (std.mem.lastIndexOfScalar(u8, partial, '/')) |i| i + 1 else 0;
    const typed_dir = partial[0..cut];
    const stem = partial[cut..];
    const dir_abs: []const u8 = if (typed_dir.len == 0)
        app.workspace
    else if (typed_dir[0] == '~')
        try std.fs.path.join(arena, &.{ app.homeDir() orelse return, std.mem.trimStart(u8, typed_dir[1..], "/") })
    else
        try app.absPath(typed_dir);
    var dir = std.Io.Dir.cwd().openDir(app.io, dir_abs, .{ .iterate = true }) catch return;
    defer dir.close(app.io);
    var it = dir.iterate();
    while (it.next(app.io) catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, stem)) continue;
        if (entry.name[0] == '.' and (stem.len == 0 or stem[0] != '.')) continue;
        const is_dir = entry.kind == .directory;
        if (dirs_only and !is_dir) continue;
        const full = try std.mem.concat(gpa, u8, &.{ typed_dir, entry.name, if (is_dir) "/" else "" });
        errdefer gpa.free(full);
        try out.append(gpa, full);
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
}

fn dropComplete(app: *App) void {
    if (app.cmd_complete) |*c| c.deinit(app.gpa);
    app.cmd_complete = null;
}

/// Tab in a path prompt: the first directory the text could be, then
/// each next one on repeated Tabs (`app.cmd_complete` keeps the ring,
/// as the `:` line's completion does). With `first_word` only the text
/// up to the first space completes; what follows it rides along.
pub fn promptPathComplete(app: *App, st: *Prompt.State, first_word: bool) Allocator.Error!void {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    // `setText` rewrites the buffer these slice: copies first.
    const line = try arena.dupe(u8, st.buf.items);
    const cut = if (first_word) (std.mem.indexOfScalar(u8, line, ' ') orelse line.len) else line.len;
    const head = line[0..cut];
    const tail = line[cut..];
    if (app.cmd_complete) |*c| {
        if (c.candidates.len > 0 and (std.mem.eql(u8, c.prefix, head) or std.mem.eql(u8, c.candidates[c.idx], head))) {
            c.idx = (c.idx + 1) % c.candidates.len;
            try st.setText(gpa, try std.mem.concat(arena, u8, &.{ c.candidates[c.idx], tail }));
            app.needs_render = true;
            return;
        }
        dropComplete(app);
    }
    var cands: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (cands.items) |c| gpa.free(c);
        cands.deinit(gpa);
    }
    try pathCandidates(app, gpa, head, true, &cands);
    if (cands.items.len == 0) return;
    const prefix = try gpa.dupe(u8, head);
    errdefer gpa.free(prefix);
    app.cmd_complete = .{ .prefix = prefix, .candidates = try cands.toOwnedSlice(gpa), .idx = 0 };
    try st.setText(gpa, try std.mem.concat(arena, u8, &.{ app.cmd_complete.?.candidates[0], tail }));
    app.needs_render = true;
}

fn cmdlineCycle(app: *App, e: *EditorPane, delta: i8) Allocator.Error!void {
    const c = &(app.cmd_complete orelse return);
    if (c.candidates.len == 0) return;
    const n: i64 = @intCast(c.candidates.len);
    c.idx = @intCast(@mod(@as(i64, @intCast(c.idx)) + delta, n));
    try e.buf.input.cmdlineSet(c.candidates[c.idx]);
}

fn cmdlineInsertWord(app: *App, e: *EditorPane, big: bool) Allocator.Error!void {
    const text = e.buf.editor.bytes();
    const cur = e.buf.editor.cursor;
    const range = if (big) bigWordAt(text, cur) else find_mod.wordAt(text, cur);
    const r = range orelse return;
    try cmdlineInsert(app, e, text[r.start..r.end]);
}

fn bigWordAt(text: []const u8, byte: usize) ?find_mod.Range {
    if (text.len == 0) return null;
    var s = @min(byte, text.len);
    var en = s;
    while (s > 0 and !std.ascii.isWhitespace(text[s - 1])) s -= 1;
    while (en < text.len and !std.ascii.isWhitespace(text[en])) en += 1;
    if (s == en) return null;
    return .{ .start = s, .end = en };
}

pub fn cmdlineInsert(app: *App, e: *EditorPane, text: []const u8) Allocator.Error!void {
    const line = e.buf.input.cmdlineGet() orelse return;
    const caret = e.buf.input.cmdlineCaret() orelse line.len;
    var clean: std.ArrayListUnmanaged(u8) = .empty;
    defer clean.deinit(app.gpa);
    for (text) |c| if (c != '\n' and c != '\r') try clean.append(app.gpa, c);
    const joined = try std.mem.concat(app.frame.allocator(), u8, &.{ line[0..caret], clean.items, line[caret..] });
    try e.buf.input.cmdlineSet(joined);
    e.buf.input.setCmdlineCaret(caret + clean.items.len);
}

test "chord chain: ctrl+k alone is pending with a which-key fallback; expiring opens it" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 40, .rows = 10 });
    defer app.deinit();
    try key(&app, Key.ctrl('k'));
    try std.testing.expect(app.chord.len == 1 and app.chord.fallback != null);
    try expireChords(&app);
    try std.testing.expect(app.overlay == .which_key);
    try std.testing.expect(app.chord.len == 0);
    // `s` descends into +split; esc closes.
    try key(&app, Key.char('s'));
    try std.testing.expectEqualStrings("s", app.overlay.which_key.slice());
    try key(&app, Key.named(.esc));
    try std.testing.expect(app.overlay == .none);
}

test "leader chain: the second key of `space e` is the chord's, not the editor's; esc cancels a pending leader silently" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    const e = app.activeEditor().?;
    try e.buf.editor.setText("const std = @import(\"std\");\n");
    e.buf.editor.setCursor(0);
    const was = app.tree.visible;
    try key(&app, Key.char(' '));
    try std.testing.expect(app.chord.len == 1);
    try key(&app, Key.char('e'));
    try std.testing.expect(app.tree.visible != was);
    try std.testing.expect(app.chord.len == 0);
    try std.testing.expect(app.overlay == .none);
    // `e` did not run as a motion.
    try std.testing.expectEqual(@as(usize, 0), e.buf.editor.cursor);
    // `space f f` reaches the file picker with nothing in between.
    try key(&app, Key.char(' '));
    try key(&app, Key.char('f'));
    try std.testing.expect(app.chord.len == 2);
    try key(&app, Key.char('f'));
    try std.testing.expect(app.overlay == .picker);
    try key(&app, Key.named(.esc));
    try std.testing.expect(app.overlay == .none);
    // Esc on a pending leader drops it without the which-key fallback.
    try key(&app, Key.char(' '));
    try key(&app, Key.named(.esc));
    try std.testing.expect(app.chord.len == 0);
    try std.testing.expect(app.chord.fallback == null);
    try std.testing.expect(app.overlay == .none);
    try expireChords(&app);
    try std.testing.expect(app.overlay == .none);
}

fn press(app: *App, x: u16, y: u16, button: key_mod.MouseButton) !void {
    try app.handle(.{ .mouse = .{ .x = x, .y = y, .kind = .press, .button = button } });
}

fn release(app: *App, x: u16, y: u16) !void {
    try app.handle(.{ .mouse = .{ .x = x, .y = y, .kind = .release, .button = .left } });
}

fn dragTo(app: *App, x: u16, y: u16) !void {
    try app.handle(.{ .mouse = .{ .x = x, .y = y, .kind = .drag, .button = .left } });
}

test "stale rects: a click after a layout change routes against a fresh frame, not the last one" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    app.tree.visible = false;
    const a = try app.openScratch();
    try app.activeEditor().?.buf.editor.setText("alpha\nbeta\ngamma\ndelta");
    try app.render();
    // Row 5 is the fourth text line while there is one leaf.
    try std.testing.expectEqual(@as(u32, 3), app.hits.at(6, 5).?.editor_cell.line);
    // Split down WITHOUT rendering: the old hit map still says line 3.
    try command.run(&app, .{ .static = .@"view.split_down" });
    const b = app.active.?;
    app.setActive(a);
    try std.testing.expectEqual(@as(u32, 3), app.hits.at(6, 5).?.editor_cell.line);
    // The click is routed against the new frame: row 5 is still the top
    // pane's fourth line (the split is below), and a press on the lower
    // pane's body focuses it — a stale map would have called it `a`.
    try press(&app, 6, 5, .left);
    try release(&app, 6, 5);
    try std.testing.expectEqual(a, app.active.?);
    try std.testing.expectEqual(@as(usize, 3), app.activeEditor().?.buf.editor.currentLine());
    try press(&app, 6, 30, .left);
    try release(&app, 6, 30);
    try std.testing.expectEqual(b, app.active.?);
}

test "wheel: a burst folds into one batch per tick; standard pins the view, vim moves the cursor" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (0..100) |i| try text.print(std.testing.allocator, "L{d}\n", .{i});
    try app.activeEditor().?.buf.editor.setText(text.items);
    try app.render();
    // Thirty wheel events at one cell: nothing moves until the tick.
    for (0..30) |_| try app.handle(.{ .mouse = .{ .x = 10, .y = 5, .kind = .scroll_down } });
    try std.testing.expectEqual(@as(u32, 0), app.activeEditor().?.view.scroll_line);
    try std.testing.expectEqual(@as(u16, 30), app.wheel.pending.?.count);
    try app.tick(app.now_ms);
    // 30 × 3 lines, clamped to the last line; the cursor stayed at 0 and the
    // view is pinned there through a render.
    try std.testing.expectEqual(@as(u32, 90), app.activeEditor().?.view.scroll_line);
    try std.testing.expectEqual(@as(usize, 0), app.activeEditor().?.buf.editor.currentLine());
    try app.render();
    try std.testing.expect(app.activeEditor().?.view.scroll_line >= 80);
    // A cursor motion releases the pin: the view comes back to the cursor.
    try app.handle(.{ .key = Key.named(.down) });
    try app.render();
    try std.testing.expectEqual(@as(u32, 1), app.activeEditor().?.view.scroll_line);
    // A click between wheel events flushes the batch first, in order.
    try app.handle(.{ .mouse = .{ .x = 10, .y = 5, .kind = .scroll_down } });
    try press(&app, 10, 3, .left);
    try std.testing.expect(app.wheel.pending == null);
    try std.testing.expectEqual(@as(u32, 4), app.activeEditor().?.view.scroll_line);
    // vim: the cursor follows.
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try app.render();
    try app.handle(.{ .mouse = .{ .x = 10, .y = 5, .kind = .scroll_down } });
    try app.tick(app.now_ms);
    try std.testing.expectEqual(@as(usize, 8), app.activeEditor().?.buf.editor.currentLine());
}

test "editor clicks: one places the cursor, two select the word, three the line; shift extends; drag selects" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.editor.setText("alpha beta gamma\nsecond line here");
    try app.render();
    // 80 wide: palette bar, strip, then the text from row 2. The gutter
    // is 5 cells, so column 12 is `beta`'s `e` (byte 7).
    try press(&app, 12, 2, .left);
    try release(&app, 12, 2);
    try std.testing.expectEqual(@as(usize, 7), e.buf.editor.cursor);
    try std.testing.expect(e.buf.editor.anchor == null);
    try press(&app, 12, 2, .left);
    try release(&app, 12, 2);
    try std.testing.expectEqualStrings("beta", e.buf.editor.selectedText());
    try press(&app, 12, 2, .left);
    try release(&app, 12, 2);
    try std.testing.expectEqualStrings("alpha beta gamma\n", e.buf.editor.selectedText());
    // Shift+click from a fresh cursor extends to the click.
    try press(&app, 5, 2, .left);
    try release(&app, 5, 2);
    app.last_click = null;
    try app.handle(.{ .mouse = .{ .x = 10, .y = 2, .kind = .press, .button = .left, .mods = .{ .shift = true } } });
    try release(&app, 10, 2);
    try std.testing.expectEqualStrings("alpha", e.buf.editor.selectedText());
    // Drag from `beta` down to the second line.
    app.last_click = null;
    try press(&app, 11, 2, .left);
    try dragTo(&app, 11, 3);
    try release(&app, 11, 3);
    try std.testing.expectEqualStrings("beta gamma\nsecond", e.buf.editor.selectedText());
    try std.testing.expect(app.drag == null);
}

test "an Alt-press on a tree row dragged onto a folder asks to copy; Tab on the move-to prompt completes folders" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    try tmp.dir.createDirPath(std.testing.io, "lib");
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "zz.txt", .data = "z" });
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = buf[0..n], .cols = 120, .rows = 40 });
    defer app.deinit();
    try app.tree.refresh(&app);
    try app.render();
    const zz = app.tree.rowOf("zz.txt").?;
    const lib = app.tree.rowOf("lib").?;
    // Where the rows paint.
    var zz_y: ?u16 = null;
    var lib_y: ?u16 = null;
    var y: u16 = 0;
    while (y < 40) : (y += 1) {
        const h = app.hits.at(5, y) orelse continue;
        if (h == .tree_node and h.tree_node == zz) zz_y = y;
        if (h == .tree_node and h.tree_node == lib) lib_y = y;
    }
    try app.handle(.{ .mouse = .{ .x = 5, .y = zz_y.?, .kind = .press, .button = .left, .mods = .{ .alt = true } } });
    try std.testing.expect(app.drag.?.tree.copy);
    try dragTo(&app, 5, lib_y.?);
    try release(&app, 5, lib_y.?);
    try std.testing.expect(app.overlay == .confirm);
    try std.testing.expectEqualStrings("Copy to folder", app.overlay.confirm.state.title);
    try app.handle(.{ .key = Key.named(.esc) });
    // Without Alt the same gesture asks to move.
    try app.render();
    try press(&app, 5, zz_y.?, .left);
    try dragTo(&app, 5, lib_y.?);
    try release(&app, 5, lib_y.?);
    try std.testing.expectEqualStrings("Move to folder", app.overlay.confirm.state.title);
    try app.handle(.{ .key = Key.named(.esc) });
    // move_to: Tab completes the folders of the workspace, in order.
    app.focus = .tree;
    app.tree.cursor = zz;
    try command.run(&app, .{ .static = .@"file.move_to" });
    try std.testing.expect(app.overlay == .prompt);
    try app.handle(.{ .key = Key.named(.tab) });
    try std.testing.expectEqualStrings("lib/", app.overlay.prompt.state.text());
    try app.handle(.{ .key = Key.named(.tab) });
    try std.testing.expectEqualStrings("src/", app.overlay.prompt.state.text());
    try app.handle(.{ .key = Key.named(.enter) });
    try tmp.dir.access(std.testing.io, "src/zz.txt", .{});
}

test "gestures: a divider drag resizes with the minimum kept, a tab drag reorders, the + opens a scratch" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    app.tree.visible = false;
    const a = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.split_right" });
    try app.render();
    try std.testing.expect(app.hits.at(60, 10).? == .divider);
    try press(&app, 60, 10, .left);
    try std.testing.expect(app.drag.? == .divider);
    try dragTo(&app, 30, 10);
    try release(&app, 30, 10);
    try std.testing.expect(app.drag == null);
    try app.render();
    try std.testing.expect(app.hits.at(30, 10).? == .divider);
    try press(&app, 30, 10, .left);
    try dragTo(&app, 2, 10);
    try release(&app, 2, 10);
    try app.render();
    try std.testing.expect(app.hits.at(layout_mod.min_pane_w, 10).? == .divider);
    // Two tabs in the left leaf: drag the first past the second. The
    // leaves are equalized first — at `min_pane_w` a strip holds only
    // its split cluster.
    try command.run(&app, .{ .static = .@"view.equalize_splits" });
    app.setActive(a);
    const b = try app.openScratch();
    try app.activeEditor().?.buf.setPath("/tmp/bb.txt");
    app.showPane(a);
    try app.activeEditor().?.buf.setPath("/tmp/aa.txt");
    try app.render();
    try std.testing.expectEqual(@as(u16, 0), app.hits.at(3, 1).?.tab.idx);
    try press(&app, 3, 1, .left);
    try dragTo(&app, 4, 1);
    try dragTo(&app, 20, 1);
    try release(&app, 20, 1);
    const leaf = app.layouts.current().leaf(app.layouts.current().leafOf(a).?).?;
    try std.testing.expectEqualSlices(PaneId, &.{ b, a }, leaf.tabs.items);
    // The `+` after the tabs opens a scratch in that leaf.
    try app.render();
    var plus: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .button and h.target.button == render.Button.newTab(0)) {
        plus = h.rect;
    };
    try press(&app, plus.?.x + 1, plus.?.y, .left);
    try std.testing.expectEqual(@as(usize, 3), leaf.tabs.items.len);
}
