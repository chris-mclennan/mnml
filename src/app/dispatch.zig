//! Keys and mouse into the App: overlays first, then the find bar, then
//! the chord chain and the focused editor, with the `AppCommand`s the
//! editor cannot express handled at the bottom of this file.
//!
//! The chord chain is vim's `timeoutlen` machine (Rust `tui/chord.rs`):
//! a bound prefix waits for its next key; a prefix that is also bound on
//! its own fires when the wait runs out (`expireChords`).

const std = @import("std");
const highlight = @import("highlight");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const command = @import("../core/command.zig");
const line_blame = @import("line_blame.zig");
const keymap = @import("../core/keymap.zig");
const key_mod = @import("../core/key.zig");
const Key = key_mod.Key;
const Chord = key_mod.Chord;
const cmdline_mod = @import("cmdline.zig");
const cmdline_popup = @import("cmdline_popup.zig");
const cmdline_bar_mod = @import("../ui/cmdline_bar.zig");
const Mouse = key_mod.Mouse;
const input = @import("../input/mod.zig");
const edit_op = @import("../editor/edit_op.zig");
const EditOp = edit_op.EditOp;
const whichkey = @import("whichkey.zig");
const find_history = @import("find_history.zig");
const auto_refresh = @import("auto_refresh.zig");
const clock_mod = @import("clock.zig");
const coverage = @import("coverage.zig");
const ghost_chip = @import("ghost_chip.zig");
const jobs_app = @import("jobs.zig");
const now_playing = @import("now_playing.zig");
const menu_bar = @import("menu_bar.zig");
const sidebar_auto = @import("sidebar_auto.zig");
const focus_follow = @import("focus_follow.zig");
const Config = @import("../config/Config.zig");
const activity_bar = @import("activity_bar.zig");
const browser_open = @import("browser_open.zig");
const ex = @import("ex.zig");
const find_mod = @import("find.zig");
const cmd_find = @import("cmd_find.zig");
const cmd_file = @import("cmd_file.zig");
const cmd_tab = @import("cmd_tab.zig");
const macros_store = @import("macros_store.zig");
const macro_replay = @import("macro_replay.zig");
const marks_store = @import("marks_store.zig");
const cmd_picker = @import("cmd_picker.zig");
const icon_picker = @import("icon_picker.zig");
const script_diag = @import("../scripting/diag.zig");
const scripts_panel = @import("scripts_panel.zig");
const script_list = @import("script_list.zig");
const script_section = @import("script_section.zig");
const settings_app = @import("settings.zig");
const SettingsUi = @import("../ui/settings.zig");
const first_launch = @import("first_launch.zig");
const Prompt = app_mod.Prompt;
const Confirm = app_mod.Confirm;
const Picker = app_mod.Picker;
const FindBar = app_mod.FindBar;
const fuzzy = @import("../ui/fuzzy.zig");
const todos = @import("../todos.zig");
const search_section = @import("search_section.zig");
const notes = @import("../notes.zig");
const findings = @import("../findings.zig");
const debug_panel = @import("debug_panel.zig");
const debug_toolbar = @import("../ui/debug_toolbar.zig");
const CellHit = @FieldType(@import("../ui/hit.zig").HitTarget, "editor_cell");
const sessions = @import("../sessions.zig");
const welcome_app = @import("welcome.zig");
const dock = @import("dock.zig");
const launcher_dock = @import("launcher_dock.zig");
const snippets = @import("snippets.zig");
const outline = @import("outline.zig");
const md_preview = @import("md_preview.zig");
const zen = @import("zen.zig");
const named_layouts = @import("named_layouts.zig");
const zon_pane = @import("zon_pane.zig");
const cmd_view = @import("cmd_view.zig");
const context_menus = @import("context_menus.zig");
const cheatsheet = @import("cheatsheet.zig");
const script_pane = @import("script_pane.zig");
const render = @import("render.zig");
const statusline_app = @import("statusline.zig");
const layout_mod = @import("layout.zig");
const select = @import("../editor/select.zig");
const block = @import("../editor/block.zig");
const Editor = @import("../editor/editor.zig").Editor;
const scrollbar = @import("../ui/scrollbar.zig");
const scroll_mod = @import("scroll.zig");
const hit_mod = @import("../ui/hit.zig");
const statusline = @import("../ui/statusline.zig");
const bufferline = @import("../ui/bufferline.zig");
const cmd_term = @import("cmd_term.zig");
const ai_apply = @import("ai_apply.zig");
const launch_profiles = @import("launch_profiles.zig");
const tests_pane = @import("tests_pane.zig");
const flaky = @import("flaky.zig");
const requests_pane = @import("requests.zig");
const toast_mod = @import("../ui/toast.zig");
const discovery = @import("discovery.zig");
const help_app = @import("help.zig");
const HelpUi = app_mod.HelpUi;
const image_pane = @import("image_pane.zig");
const tree_mod = @import("tree.zig");
const info_view_app = @import("info_view.zig");
const Rect = @import("../ui/rect.zig");
const pty_pane = @import("pty_pane.zig");
const pty_search = @import("pty_search.zig");
const request_pane = @import("request_pane.zig");
const http_app = @import("http.zig");
const decor = @import("lsp_decor.zig");
const conflicts = @import("conflicts.zig");
const rename_app = @import("lsp_rename.zig");
const http_panel = @import("http_panel.zig");
const ws_pane = @import("ws_pane.zig");
const browser_pane = @import("browser_pane.zig");
const mount_pane = @import("mount_pane.zig");
const integrations = @import("integrations.zig");
const launchers = @import("launchers.zig");
const integrations_view = @import("../ui/integrations_view.zig");
const ipc = @import("../ipc/root.zig");
const cmd_browser = @import("cmd_browser.zig");
const cmd_http = @import("cmd_http.zig");
const runners = @import("runners.zig");
const font_scan = @import("font_scan.zig");
const git_app = @import("git.zig");
const git_palette = @import("git_palette.zig");
const side = @import("side.zig");
const bottom = @import("bottom.zig");
const ai_app = @import("ai.zig");
const sessions_table = @import("sessions_table.zig");
const cloud_agents = @import("cloud_agents.zig");
const spend = @import("spend.zig");
const usage_pane = @import("usage_pane.zig");
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
    // A recording takes every typed key, wherever it goes: the buffer
    // records the ones it is fed; one the find bar, the `:` line or an
    // overlay took is added here. The `q` that stops a recording and
    // the `q<reg>` that starts one are nobody's.
    app.key_failed = false;
    const rec: ?PaneId = if (app.active) |id| (if (app.panes.editor(id)) |e| (if (e.buf.isRecording()) id else null) else null) else null;
    const fed_before: u64 = if (rec) |id| app.panes.editor(id).?.buf.keys_fed else 0;
    try keyUnrecorded(app, k);
    if (rec) |id| if (app.panes.editor(id)) |e| {
        if (e.buf.isRecording() and e.buf.keys_fed == fed_before) try e.buf.recordKey(k);
    };
}

/// One key, as typed, minus the macro recording — what a replay feeds.
pub fn keyUnrecorded(app: *App, k: Key) Allocator.Error!void {
    app.key_depth += 1;
    defer app.key_depth -= 1;
    const before = try jumplist.snapshot(app);
    try keyInner(app, k);
    try jumplist.afterKey(app, before);
}

fn keyInner(app: *App, k: Key) Allocator.Error!void {
    app.needs_render = true;
    // Esc Esc leaves full screen: any other key in between disarms.
    if (k.code != .esc) app.zen_esc_ms = null;
    // Esc puts every transient toast away, whatever else it is about
    // to do — an overlay closes, visual mode ends, the pane gets it —
    // as Rust's key handler does before anything else sees the key
    // (walkthrough 1.11: the picker's `no recent files` boxes stacked
    // three deep because nothing ever cleared them).
    if (k.code == .esc) app.dismissTransientToasts();
    switch (app.overlay) {
        .none => {},
        else => return overlayKey(app, k),
    }
    // // changed (bottom-row): the app's own `:` line owns the keyboard
    // while it is open — it is opened from any focus, so no focused
    // handler gets a say — and the chord that opens it is read here,
    // ABOVE the chord chain. A half-typed leader sequence in a pane
    // would otherwise swallow `Ctrl+;` into `app.chord` and the line
    // would never appear (the bug Rust's own `Ctrl+;` was moved up to
    // fix: it worked in tree focus and failed in pane focus).
    if (app.cmdline != null) {
        // The completion popup's keys first (`app/cmdline_popup.zig`):
        // the arrows and Esc while it shows, Tab / Shift+Tab always.
        if (try cmdline_popup.appLineKey(app, k)) return;
        if (try cmdline_mod.key(app, k)) {
            // The line may have changed: the popup follows it.
            try cmdline_popup.refresh(app);
            return;
        }
    }
    if (opensCommandLine(app, k)) {
        app.chord.clear(app.gpa);
        cmdline_mod.open(app);
        return;
    }
    if (app.find_bar != null) return findBarKey(app, k);
    // Armed flash labels take the next key ahead of everything the
    // editor could do with it: a label jumps, Esc disarms, anything
    // else disarms and carries on below.
    if (app.flash != null and flash.interceptKey(app, k)) return;
    // F10 / Alt+<letter> summon a menu-bar menu (`app/menu_bar.zig`).
    if (try menu_bar.interceptKey(app, k)) return;
    // // changed (launcher-dock): the launcher strip takes its own keys
    // while `view.focus_dock` has put the keyboard in it — the same
    // shape the menu bar's open menu uses, so no `Focus` variant is
    // needed for a surface that holds the keys for one pick.
    if (try launcher_dock.interceptKey(app, k)) return;
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
    // Full screen's way out, ahead of every pane and panel: a lone Esc
    // that nothing above wanted arms (and goes on to whatever Esc does
    // in the pane — a terminal gets it too); the second within the
    // chord timeout leaves (`zen.escKey`).
    if (zen.escKey(app, k)) return;
    // A pending chord owns the next key outright, whatever has the
    // keyboard — the `z` of `Ctrl+K Z` is the chain's, never a request
    // pane's URL field's or a panel's (the editor path and `ptyKey`
    // apply the same rule).
    if (app.chord.len > 0) {
        _ = try chordChain(app, k);
        return;
    }
    if (app.focus == .tree and app.tree.visible) {
        if (try app.tree.handleKey(app, k)) return;
        _ = try chordChain(app, k);
        return;
    }
    if (app.focus == .panel and side.isShown(app, side.sectionOfPanel(app.focus.panel))) {
        // A column is a window to vim's `Ctrl-W` family (the tree keeps
        // its own flag in `Tree.handleKey`); the chord owns its second
        // key whatever it is.
        if (app.side.ctrl_w_pending) {
            app.side.ctrl_w_pending = false;
            // // changed (bottom-dock): `J` / `K` move the section into
            // the dock and back up before the command table is read.
            const sec = side.sectionOfPanel(app.focus.panel);
            if (side.ctrlWSectionSide(app, k, sec)) |dest| {
                side.move(app, sec, dest) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                };
                return;
            }
            if (side.ctrlWCommand(k)) |id| try runCmd(app, id);
            return;
        }
        if (side.isCtrlW(app, k)) {
            app.side.ctrl_w_pending = true;
            return;
        }
        const took = switch (app.focus.panel) {
            .todos => try todos.handleKey(app, k),
            .notes => try notes.handleKey(app, k),
            .findings => try findings.handleKey(app, k),
            .debug => try debug_panel.handleKey(app, k),
            .git => try git_palette.handleKey(app, k),
            .diagnostics => try lsp.panelKey(app, k),
            .http => try http_panel.handleKey(app, k),
            .sessions => try sessions.handleKey(app, k),
            .integrations => try integrations.handleKey(app, k),
            .scripts => try scripts_panel.handleKey(app, k),
            .script => try script_section.handleKey(app, k),
            .search => try search_section.handleKey(app, k),
            .outline => if (app.outline_panel) |id| try outline.handleKey(app, id, k) else false,
            // The JOBS list lives in an overlay, which has the keys.
            .jobs => false,
        };
        if (took) return;
        try unclaimedKey(app, k);
        return;
    }

    // // changed (welcome): the start surface walks its lists while the
    // layout is empty; what it does not take goes on to the chords.
    if (welcome_app.takesKeys(app)) {
        if (app.focus != .welcome) welcome_app.focus(app);
        if (try welcome_app.handleKey(app, k)) return;
        _ = try chordChain(app, k);
        return;
    }
    // A stale start-surface focus (a pane opened from under it) goes
    // to the pane.
    if (app.focus == .welcome) app.focus = if (app.active) |a| .{ .pane = a } else .tree;

    const pane_id = app.active;
    // A non-editor pane is a window to vim's `Ctrl-W` family: the key
    // after an unclaimed `Ctrl-W` (`unclaimedKey`) names the verb, ahead
    // of the pane's own use of it (`h` is not the pane's here).
    if (app.pane_ctrl_w_pending) {
        app.pane_ctrl_w_pending = false;
        if (paneCtrlWCommand(k)) |id| try runCmd(app, id);
        return;
    }
    // The non-editor panes take their own keys first.
    if (pane_id) |id| if (app.panes.get(id)) |p| switch (p.*) {
        .pty => |*term| return ptyKey(app, id, term, k),
        .outline => {
            if (try outline.handleKey(app, id, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .md_preview => {
            if (try md_preview.handleKey(app, id, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .zon => {
            if (try zon_pane.handleKey(app, id, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .cheatsheet => |*c| {
            if (try cheatsheet.handleKey(app, c, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .script => |*s| {
            if (try script_pane.handleKey(app, s, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .list => |*l| {
            if (try listPaneKey(app, id, l, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .git_status => |*s| {
            if (try git_app.statusPaneKey(app, id, s, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .diff => |*d| {
            if (try git_app.diffKey(app, id, d, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .git_graph => |*g| {
            if (try git_app.graphKey(app, id, g, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .ai => |*a| {
            if (try ai_app.paneKey(app, id, a, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .sessions_table => |*tp| {
            if (try sessions_table.handleKey(app, id, tp, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .spend_report => |*s| {
            if (try spend.handleKey(app, id, s, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .ai_usage => |*u| {
            if (try usage_pane.handleKey(app, id, u, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .grep => |*g| {
            if (try grep.handleKey(app, id, g, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .debug => |*d| {
            if (try dap.debugKey(app, id, d, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .request => |*rp| {
            if (try request_pane.handleKey(app, id, rp, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .websocket => |*w| {
            if (try ws_pane.handleKey(app, id, w, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .browser => |*b| {
            if (try browser_pane.handleKey(app, id, b, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .mount => |*mp| {
            if (try mount_pane.handleKey(app, id, mp, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .integrations => |*ip| {
            if (try integrations.paneKey(app, id, ip, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .ai_apply => |*ap| {
            if (try ai_apply.handleKey(app, id, ap, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .tests => |*tp| {
            if (try tests_pane.handleKey(app, id, tp, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .flaky => |*fp| {
            if (try flaky.handleKey(app, id, fp, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .requests => |*rp| {
            if (try requests_pane.handleKey(app, id, rp, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .files => |*f| {
            if (try files_pane.handleKey(app, id, f, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .image => |*im| {
            if (try image_pane.handleKey(app, id, im, k)) return;
            try unclaimedKey(app, k);
            return;
        },
        .editor => {},
    };
    // A ghost suggestion owns Tab / ctrl+→ / ctrl+↓ ahead of the chord
    // chain; any other key dismisses it and goes on as usual.
    if (pane_id) |id| if (app.panes.editor(id)) |e| if (e.buf.editor.ghost_suggestion != null) {
        if (try ai_app.interceptKey(app, e, k)) return;
    };
    // A conflict block under the cursor takes `co` / `ct` / `cb` (vim)
    // or `alt+1..3` (standard) ahead of the handler; a `c` that was not
    // a pick is fed as the operator first (`app/conflicts.zig`).
    if (pane_id) |id| if (app.panes.editor(id)) |e| switch (try conflicts.interceptKey(app, id, e, k)) {
        .consumed => return,
        .replay_c => _ = try feedEditor(app, id, e, Key.char('c')),
        .pass => {},
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
    // A key the handler reserves (vim Insert's completion pair) goes
    // to it even though the keymap binds it for Normal.
    const reserved = if (ed) |e| e.buf.input.reservesKey(k) else false;
    const editor_first = app.chord.len == 0 and ed != null and (cmdline_open or reserved or (bare_space and (!modal or op_pending)) or (typing_mode and plain) or (op_pending and plain) or (modal and plain and !bare_space));
    if (!editor_first and app.chord.len == 0 and ed == null) {
        // No pane: only chords do anything.
        _ = try chordChain(app, k);
        return;
    }
    if (!editor_first) {
        if (try chordChain(app, k)) return;
    }
    const e = ed orelse return;
    // The vim `:` line's completion popup owns the arrows and Esc while
    // it shows (`app/cmdline_popup.zig`); Tab reaches it through the
    // handler's own seams.
    // Esc is the exception: it abandons the vim line whatever the popup
    // shows (`:help c_<Esc>`; Neovim's wildmenu / pum never holds the
    // line open), so the next keys are Normal mode's, not the line's.
    if (cmdline_open and k.code == .esc) {
        cmdline_popup.dismiss(app);
    } else if (cmdline_open and try cmdline_popup.interceptKey(app, k)) return;
    if (try snippets.interceptKey(app, pane_id.?, e, k)) return;
    const consumed = try feedEditor(app, pane_id.?, e, k);
    if (!consumed and editor_first) _ = try chordChain(app, k);
    // The line the key went to may have changed — or closed: the popup
    // follows it. `e` is stale after an app command; ask afresh.
    const now_open = if (app.activeEditor()) |still| still.buf.input.isCmdlineOpen() else false;
    if (cmdline_open or now_open) try cmdline_popup.refresh(app);
}

/// A key the focused pane or panel did not take. To a vim user every
/// window is a window: a plain `:` nobody claimed opens the app's
/// command line (`:help :`) — terminal-normal, the git status pane, the
/// graph, the cheatsheet, a sidebar section — so the letters typed after
/// it are the command's and never the pane's single-key verbs (`c` of
/// `:e` opening the commit box). A pane that types text (a filter, a
/// prompt field) has already taken its `:`. Anything else is a chord.
fn unclaimedKey(app: *App, k: Key) Allocator.Error!void {
    const bare = !k.mods.ctrl and !k.mods.alt and !k.mods.super;
    if (app.input_style == .vim and bare and k.typed() == ':') {
        app.chord.clear(app.gpa);
        cmdline_mod.open(app);
        return;
    }
    // `Ctrl-W` nobody took arms the window chord; the next key is its.
    if (side.isCtrlW(app, k) and app.focus == .pane) {
        app.pane_ctrl_w_pending = true;
        return;
    }
    _ = try chordChain(app, k);
}

/// The second key of `Ctrl-W` from a non-editor pane: the window verbs
/// the editor's `Ctrl-W` has (`:help CTRL-W`).
fn paneCtrlWCommand(k: Key) ?command.CommandId {
    const c: u21 = switch (k.code) {
        .char => |ch| if (k.mods.ctrl and ch < 0x80) std.ascii.toLower(@intCast(ch)) else ch,
        .left => 'h',
        .right => 'l',
        .down => 'j',
        .up => 'k',
        else => return null,
    };
    return switch (c) {
        'w' => .@"view.focus_next_split",
        'W' => .@"view.focus_prev_split",
        'p' => .@"view.focus_previous",
        't' => .@"view.focus_top",
        'b' => .@"view.focus_bottom",
        'h' => .@"view.focus_left",
        'j' => .@"view.focus_down",
        'k' => .@"view.focus_up",
        'l' => .@"view.focus_right",
        'D' => .@"view.focus_dock",
        'q', 'c' => .@"view.close_split",
        'o' => .@"view.only",
        's' => .@"view.split_down",
        'v' => .@"view.split_right",
        'H' => .@"view.move_split_left",
        'J' => .@"view.move_split_down",
        'K' => .@"view.move_split_up",
        'L' => .@"view.move_split_right",
        '=' => .@"view.equalize_splits",
        'r' => .@"view.rotate_splits",
        else => null,
    };
}

/// The list panes: j/k move, enter acts, esc closes the pane.
fn listPaneKey(app: *App, id: PaneId, l: *app_mod.ListPane, k: Key) Allocator.Error!bool {
    const arena = app.frame.allocator();
    // // changed (git-more2): the `/` filter takes the keys while it is
    // typed — esc clears it, enter keeps it; the cursor stays inside
    // the shown rows.
    if (l.filter_mode) {
        switch (k.code) {
            .esc => {
                l.filter.clearRetainingCapacity();
                l.filter_mode = false;
            },
            .enter => l.filter_mode = false,
            .backspace => {
                if (l.filter.items.len > 0) {
                    var n: usize = 1;
                    while (n < l.filter.items.len and (l.filter.items[l.filter.items.len - n] & 0xC0) == 0x80) n += 1;
                    l.filter.items.len -= n;
                }
            },
            .char => |c| {
                if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &buf) catch return false;
                try l.filter.appendSlice(l.gpa, buf[0..len]);
            },
            else => return false,
        }
        l.cursor = 0;
        l.scroll = 0;
        app.needs_render = true;
        return true;
    }
    const n = try l.shownCount(arena);
    switch (k.code) {
        .down => l.cursor = @min(l.cursor + 1, n -| 1),
        .up => l.cursor -|= 1,
        .home => l.cursor = 0,
        .end => l.cursor = n -| 1,
        .enter => try listPaneEnter(app, id, l),
        .esc => {
            // A set filter goes first; the pane after.
            if (l.filter.items.len > 0) {
                l.filter.clearRetainingCapacity();
                l.cursor = 0;
            } else try app.forceClosePane(id);
        },
        .char => |c| switch (c) {
            'j' => l.cursor = @min(l.cursor + 1, n -| 1),
            'k' => l.cursor -|= 1,
            'g' => l.cursor = 0,
            'G' => l.cursor = n -| 1,
            'q' => try app.forceClosePane(id),
            '/' => if (app_mod.ListPane.filters(l.kind)) {
                l.filter_mode = true;
            } else return false,
            // The row's text (a command line, a path) to the clipboard.
            'y' => if (try l.entryAt(arena, l.cursor)) |e| {
                const text: []const u8 = if (l.kind == .git_log) (git_app.logCommand(app, e.*) orelse e.text) else if (e.path) |p| p else e.text;
                try app.clipboard.setYank(text, false);
                app.toast("copied {s}", .{text});
            },
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
/// pane closes on Enter or Esc; its scrollback keys still scroll it, and
/// every other key is the app's (the vim leader included).
fn ptyKey(app: *App, id: PaneId, p: *pty_pane.PtyPane, k: Key) Allocator.Error!void {
    if (app.chord.len > 0) {
        _ = try chordChain(app, k);
        return;
    }
    const modified = k.mods.ctrl or k.mods.alt or k.mods.super;
    if (p.exit != null) {
        // Reading back what the command printed is why the pane is still
        // there: Shift+PageUp / Home … scroll, as they did while it ran
        // (ghostty's keybindings, too, come before "any key closes").
        if (pty_pane.scrollKey(app, p, k)) return;
        if (modified and try chordChain(app, k)) return;
        // A pane restored from a saved session never ran: a key offers
        // it back rather than closing the tab the restore just brought.
        if (p.dormant) {
            pty_pane.restart(app, id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
            return;
        }
        const plain = !modified and !k.mods.shift;
        if (plain and (k.code == .enter or k.code == .esc)) return app.forceClosePane(id);
        _ = try chordChain(app, k);
        return;
    }
    // vim: `<C-\><C-n>` (NvChad's `<C-x>` too) leaves the child for
    // terminal-normal mode, where every key is the app's — the leader,
    // the `Ctrl-W` family, `i` / `a` back in — and none is the child's.
    if (p.term_normal) {
        // `/`, `n`, `N`: the scrollback search (`pty_search.zig`).
        if (try pty_search.termNormalKey(app, id, p, k)) return;
        if (try pty_pane.termNormalKey(app, p, k)) return;
        try unclaimedKey(app, k);
        return;
    }
    if (pty_pane.escapeKey(app, p, k)) return;
    if (modified and !pty_pane.childOwned(k)) {
        if (try pty_search.findChord(app, id, p, k)) return;
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
    const wrap_width = try beforeBufferInput(app, e);

    const ev = try e.buf.feedKey(k, &app.clipboard, app.pane_rows, wrap_width, arena);
    if (e.buf.jumped) jumplist.noteJumpMotion(app);
    // A motion that could not move, a text object that found nothing:
    // a replaying macro stops here (`:help q`).
    if (e.buf.key_failed) app.key_failed = true;
    switch (ev) {
        .unhandled => {
            try afterBufferEvent(app, pane_id, e, ev, was_recording);
            return false;
        },
        .edited => {
            try afterBufferEvent(app, pane_id, e, ev, was_recording);
            if (trigger) try expandAbbreviation(app, e);
            try lsp.onTyped(app, pane_id, e, k, before_mode);
        },
        else => try afterBufferEvent(app, pane_id, e, ev, was_recording),
    }
    // An app command may have opened or closed panes (`:e b.txt` grows
    // the store and moves every pane): `e` is stale from here. Look the
    // pane up again, and stop if it is gone.
    const still = app.panes.editor(pane_id) orelse return true;
    // A motion that left the completion popup's word closes it.
    lsp.afterKey(app, pane_id, still);
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

/// What the buffer needs from the app before a key or a runner's app
/// command reaches it: the `gn` matches, the text-object seam, and the
/// wrap width for page motions.
fn beforeBufferInput(app: *App, e: *EditorPane) Allocator.Error!?usize {
    try cmd_find.seedCtxMatches(e);
    app.attachSeams(e);
    return if (e.wrap orelse app.cfg.ui.wrap) app.pane_cols else null;
}

/// What a buffer event means to the app, whether a key or a runner
/// caused it: an edit dirties the syntax and wakes the seams, an app
/// command runs, a recording that just stopped is persisted. A key's
/// own extras (abbreviations, the LSP's typed hook) stay with
/// `feedEditor`. `e` is stale after an app command; look the pane up
/// again before touching it.
fn afterBufferEvent(app: *App, pane_id: PaneId, e: *EditorPane, ev: input.BufferEvent, was_recording: bool) Allocator.Error!void {
    if (e.buf.last_unsupported) |name| {
        app.toast("{s}: not supported yet", .{name});
        e.buf.last_unsupported = null;
    }
    switch (ev) {
        .unhandled, .noop, .redraw => {},
        .edited => {
            e.syntax.dirty = true;
            flash.cancel(app);
            snippets.afterEdit(app, pane_id, e);
            ai_app.noteEdit(app);
        },
        .app => |cmd| try handleAppCommand(app, pane_id, e, cmd),
    }
    const still = app.panes.editor(pane_id) orelse return;
    // A recording that just stopped is on the clipboard: persist it.
    if (was_recording and !still.buf.isRecording()) macros_store.afterRecording(app);
}

/// A runner's app command for the buffer (`vim.dot_repeat`, the macro
/// chip): the same road a key's `.app` result takes, without a key.
pub fn runBufferApp(app: *App, pane_id: PaneId, e: *EditorPane, cmd: input.AppCommand) Allocator.Error!void {
    const was_recording = e.buf.isRecording();
    const wrap_width = try beforeBufferInput(app, e);
    const ev = try e.buf.runApp(cmd, &app.clipboard, app.pane_rows, wrap_width, app.frame.allocator());
    try afterBufferEvent(app, pane_id, e, ev, was_recording);
    if (app.panes.editor(pane_id)) |still| still.buf.input.setMacroRecording(still.buf.isRecording());
    try finishDeferredInserts(app);
    app.needs_render = true;
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
    if (app.chord.menu) return chordMenuKey(app, k);
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
            const menu = if (!was_first and k.code != .esc) leaderLookup(app.chord.seq[0..app.chord.len], app.input_style == .vim) else null;
            // An ARMED LEADER owns its whole chord, however fast it was
            // typed: `<leader>cx` names no row, so the `x` is dropped
            // with a word — never handed on as vim's delete-a-character.
            // That used to fall out of the popup being open by the time
            // the tail arrived, which only held when a pending chain was
            // expired without reading its deadline; the popup is the
            // timeout's fallback now, so the rule lives here.
            //
            // A CHARACTER tail only. A tail that is not one — an arrow,
            // Enter, a modified chord — keeps what it always did: the
            // leader's own fallback fires and the popup opens on it,
            // which is the reading the popup itself gives such a key.
            const plain_tail = k.code == .char and !k.mods.ctrl and !k.mods.alt and !k.mods.super;
            const dead_leader = !was_first and plain_tail and menu == null and leaderArmed(app);
            const tail: []const u8 = if (dead_leader) leaderTail(app, app.chord.seq[1..app.chord.len]) else "";
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
            if (dead_leader) {
                if (fallback) |fb| freeTarget(app, fb);
                const vim = app.input_style == .vim;
                app.toast("no leader mapping: {s}{s}{s}", .{ whichkey.leaderLabel(vim), whichkey.leaderGap(vim), tail });
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

/// A key while the standard `Ctrl+K` popup is up (`ChordChain.menu`):
/// the keymap decides, exactly as for a key typed before the timeout —
/// a bound chord runs, a prefix goes one level down (the popup follows
/// it), Esc cancels, and a key no chord carries is dropped with a word
/// rather than typed into the buffer.
fn chordMenuKey(app: *App, k: Key) Allocator.Error!bool {
    app.needs_render = true;
    switch (app.keymap.resolveSeq(app.chord.seq[0..app.chord.len])) {
        .run, .pending_with_fallback => |t| {
            app.chord.clear(app.gpa);
            try runTarget(app, t);
        },
        .pending => {},
        .none => {
            const tail = leaderTail(app, app.chord.seq[1..app.chord.len]);
            app.chord.clear(app.gpa);
            if (k.code != .esc) app.toast("no Ctrl+K chord: Ctrl+K {s}", .{tail});
        },
    }
    return true;
}

/// Whether the chord chain was opened by the leader itself — the key
/// `whichkey.leader` is bound to in the active profile, whatever the
/// config spells it as. It is the one binding that is a command AND a
/// prefix, so `resolveSeq` answers `pending_with_fallback` for it.
fn leaderArmed(app: *const App) bool {
    if (app.chord.len == 0) return false;
    return switch (app.keymap.resolveSeq(app.chord.seq[0..1])) {
        .pending_with_fallback => |t| t == .static and t.static == .@"whichkey.leader",
        else => false,
    };
}

/// The keys typed after the leader, as the dead-end toast spells them:
/// a plain character as itself, anything else (a modified chord, an
/// arrow) as `…`, since the toast is a sentence and not a key spec.
fn leaderTail(app: *App, seq: []const Chord) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (seq) |c| {
        const ch: ?u21 = switch (c.code) {
            .char => |v| v,
            else => null,
        };
        if (ch != null and ch.? < 128 and !c.mods.ctrl and !c.mods.alt and !c.mods.super) {
            out.append(app.frame.allocator(), @intCast(ch.?)) catch return out.items;
        } else {
            out.appendSlice(app.frame.allocator(), "\u{2026}") catch return out.items;
        }
    }
    return out.items;
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
    // The standard profile: a pause after `Ctrl+K` (or `Ctrl+K g`) is
    // the pause before the chord's next key, as in VS Code. The chain
    // stays pending with no deadline and the popup lists the profile's
    // own `Ctrl+K` chords; the next key completes one through the keymap.
    // It used to fire `whichkey.leader`, whose popup is the vim leader
    // tree — `Ctrl+K ⏸ W` saved instead of `view.close_others`.
    if (app.input_style != .vim and leaderArmed(app)) {
        if (app.chord.fallback) |fb| freeTarget(app, fb);
        app.chord.fallback = null;
        app.chord.deadline_ms = null;
        app.chord.menu = true;
        app.needs_render = true;
        return;
    }
    const fallback = app.chord.fallback;
    app.chord.fallback = null;
    const menu = if (fallback == null) leaderLookup(app.chord.seq[0..app.chord.len], app.input_style == .vim) else null;
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
fn leaderLookup(seq: []const Chord, vim: bool) ?LeaderHit {
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
    hit.node = whichkey.lookupIn(hit.path[0..hit.len], vim) orelse return null;
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
        .dyn => |d| command.runNamed(app, d.id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .group, .dyn_group => {
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
    const back: ?app_mod.FocusId = switch (app.overlay) {
        .menu => |m| m.return_focus,
        .prompt => |p| p.return_focus,
        .confirm => |c| c.return_focus,
        .picker => |p| p.return_focus,
        else => null,
    };
    app.overlay.deinit(app.gpa);
    if (back) |f| {
        app.focus = f;
        if (f == .panel and !side.isShown(app, side.sectionOfPanel(f.panel))) restoreFocus(app);
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

/// A click on the dock's tab strip: the tab it names takes the keys,
/// middle closes it, right opens the tab menu. The dock's panes are
/// out of the split tree, so there is no leaf to route through.
/// // changed (bottom-dock).
fn bottomTabClick(app: *App, idx: usize, m: Mouse) Allocator.Error!void {
    const list = app.bottom.panes.items;
    if (idx >= list.len or m.kind != .press) return;
    const pane = list[idx];
    if (app.overlay != .none) closeOverlay(app);
    switch (m.button) {
        .middle => try app.closePane(pane, false),
        .right => try context_menus.openTabMenu(app, pane, m.x, m.y),
        else => {
            app.bottom.active = idx;
            app.setActive(pane);
        },
    }
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

/// The pointer moving over an open menu (Rust `tui/mouse/mod.rs`'s
/// Moved arm): a row under it becomes the cursor row and the highlight
/// comes on; a parent row opens its child and closes the one before,
/// a leaf closes an open child (a curation child stays while the
/// pointer is on its own row); a child's row moves the child's cursor.
/// The keyboard and the pointer both move the same cursor, so the
/// last input wins.
fn menuHover(app: *App, m: Mouse) Allocator.Error!void {
    const target = app.hits.at(m.x, m.y) orelse return;
    const menu = &app.overlay.menu;
    switch (target) {
        .menu_item => |mi| switch (mi.menu) {
            // A top-level row, or the kebab on one.
            0, 2 => {
                if (mi.idx >= menu.items.len) return;
                menu.cursor = mi.idx;
                menu.highlight = true;
                if (menu.items[mi.idx].submenu.len > 0) {
                    if (menu.sub == null or menu.sub.?.parent != mi.idx) try context_menus.openSubmenu(app, mi.idx);
                } else if (menu.sub) |sub| {
                    if (sub.parent != mi.idx) menu.closeSub(app.gpa);
                }
            },
            // A child's row, or the kebab on one.
            1, 3 => if (menu.sub) |*sub| {
                if (mi.idx < sub.items.len) {
                    sub.cursor = mi.idx;
                    sub.highlight = true;
                }
            },
            else => {},
        },
        // Another word of the menu bar, or its » : that menu instead.
        .button => |id| _ = try menu_bar.hoverSwitch(app, id, hitRect(app, m.x, m.y) orelse Rect.init(m.x, m.y, 1, 1)),
        else => {},
    }
}

/// An arrow / j / k / Home / End on a menu: the cursor moves by
/// `delta` (saturating), and the highlight comes on — a mouse-opened
/// dropdown shows none until then, and its first arrow only lights
/// the cursor row, as Rust's does from "nothing highlighted".
fn menuMove(m: *app_mod.MenuState, delta: i32) void {
    const last: i64 = @as(i64, @intCast(m.items.len)) - 1;
    if (last < 0) return;
    m.follow = .cursor;
    if (!m.highlight) {
        m.highlight = true;
        return;
    }
    const want = @as(i64, @intCast(m.cursor)) + delta;
    m.cursor = @intCast(@max(0, @min(want, last)));
}

/// `menuMove` for the open child, except that its first arrow moves as
/// well as lights: Rust's child `ContextMenu` (and the menu bar's
/// submenu) starts un-interacted on row 0 and `move_down` steps to
/// row 1 at once. Eating the first arrow put every later key one row
/// above where the screen said it was — `→` curated the row above,
/// Enter pinned instead of creating (walkthrough 2.2).
fn subMove(sub: *app_mod.MenuState.SubMenu, delta: i32) void {
    const last: i64 = @as(i64, @intCast(sub.items.len)) - 1;
    if (last < 0) return;
    sub.follow = .cursor;
    sub.highlight = true;
    const want = @as(i64, @intCast(sub.cursor)) + delta;
    sub.cursor = @intCast(@max(0, @min(want, last)));
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
    // right-click: a string-carrying row's bytes belong to the menu's
    // own arena, which the close frees — copy them out first.
    const text: ?[]const u8 = switch (action) {
        .copy_text, .open_url, .open_path, .set_theme, .lua_bind, .lsp_install, .requests_for => |s| try app.frame.allocator().dupe(u8, s),
        .claude_account => |c| try app.frame.allocator().dupe(u8, c.name),
        else => null,
    };
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
        .move_section => |ms| side.move(app, ms.section, ms.side) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        // // changed (railmove): the membership rows.
        .rail_hide => |s| activity_bar.setHidden(app, s, true) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .rail_show => |s| activity_bar.setHidden(app, s, false) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .rail_to_dock => |s| activity_bar.showOnDock(app, s) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .rail_from_dock => |s| activity_bar.moveBackFromDock(app, s) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .set_panel_sort => |s| switch (s.panel) {
            .todos => try todos.setSort(app, s.sort),
            .notes => try notes.setSort(app, s.sort),
            .findings => try findings.setSort(app, s.sort),
            .integrations => try integrations.setSort(app, s.sort),
            .sessions, .git, .diagnostics, .http, .outline, .debug, .scripts, .search, .script, .jobs => {},
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
        .set_claude_mark => |m| try @import("claude_mark.zig").set(app, m),
        .set_terminal_mark => |m| @import("terminal_glyph.zig").setMark(app, m) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .set_dock_labels => |l| launcher_dock.setLabels(app, l) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .set_dock_placement => |pl| launcher_dock.setPlacement(app, pl) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .set_dock_align => |a| launcher_dock.setAlign(app, a) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .set_dock_plus => |on| launcher_dock.setPlus(app, on) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .set_dock_plus_at => |at| launcher_dock.setPlusAt(app, at) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .set_dock_running_mark => |m| launcher_dock.setRunningMark(app, m) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .menu_bar => |i| try menu_bar.openIndex(app, i),
        .git_palette => |a| try git_palette.menuAction(app, a),
        // colors: the `Color: …` rows — a session's, a repo's.
        .session_color => |a| try sessions.setColorAction(app, a),
        .repo_color => |a| try git_palette.setRepoColor(app, a.idx, a.name),
        // right-click: the string-carrying rows, on the copy taken above.
        .copy_text => {
            try app.clipboard.set(text.?, false);
            app.toast("copied {s}", .{text.?});
        },
        .open_url => git_app.openExternal(app, text.?),
        // The chip's own service, so the view opens on the requests
        // that chip's number was paid for.
        .requests_for => requests_pane.showFiltered(app, text.?) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .open_path => try openPathRow(app, text.?),
        .set_theme => cmd_view.acceptTheme(app, text.?) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => if (app.diag.msg) |msg| app.toast("{s}", .{msg}),
        },
        // // changed (lua-track): the DIAGNOSTICS / SCRIPTS row menus,
        // the severity chip's menu, Bind in init.lua….
        .diag_row_open => |i| try lsp.openRowIndex(app, i),
        .set_severity_filter => |f| lsp.setFilter(app, f),
        .script_row_open => |i| try scripts_panel.openRowIndex(app, i),
        .script_sort => |v| scripts_panel.setSort(app, @enumFromInt(v)),
        .lua_bind => try scripts_panel.promptBind(app, text.?),
        // // changed (lsp-defaults): the LSP chip menu's Install row.
        .lsp_install => try toastOnFail(app, runners.installBin(app, text.?)),
        // A Claude account's row on the usage pane's menus or a chooser.
        .claude_account => |c| try toastOnFail(app, usage_pane.accountAction(app, c.act, text.?)),
        // // changed (lua-plumbing): a script list's row menu.
        .script_list_fold => |f| if (script_list.find(app, f.list)) |l| {
            const rows = try script_list.visible(app, l, app.frame.allocator());
            if (f.row < rows.len) try script_list.toggleFold(app, l, rows[f.row].label);
        },
        .script_list_menu => |m| if (script_list.find(app, m.list)) |l| {
            _ = l;
            app.script().runMenuItem(m.item);
        },
        .script_list_refresh => |id| if (script_list.find(app, id)) |l| try script_list.refresh(app, l),
        .script_section_show => |i| script_section.show(app, i, true),
        .none => {},
    }
}

/// right-click: a menu row's path — a directory opens in a Files pane,
/// anything else in a buffer.
fn openPathRow(app: *App, path: []const u8) Allocator.Error!void {
    const is_dir = if (std.Io.Dir.cwd().statFile(app.io, path, .{})) |st| st.kind == .directory else |_| false;
    if (is_dir) {
        _ = try files_pane.open(app, path);
        return;
    }
    _ = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => app.toast("cannot open {s}", .{path}),
    };
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
        // // changed (bottom-row): a SECOND `Ctrl+Q` on the quit box
        // quits anyway. The chord that raised it is the one the hand is
        // already on, and pressing it again plainly means "yes, quit" —
        // the reference editor answers it the same way, through its own
        // box's `q` hotkey.
        .confirm => |*c| if ((c.purpose == .quit or c.purpose == .quit_clean) and k.mods.ctrl and k.code == .char and k.code.char == 'q') {
            closeOverlay(app);
            app.quit = true;
            return;
        } else switch (Confirm.handleKey(&c.state, k)) {
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
            // Backspace walks back up the tree, as the reference plugin
            // does; at the root there is nowhere to go, so it closes.
            if (k.code == .backspace) {
                if (w.len == 0) return closeOverlay(app);
                w.len -= 1;
                app.needs_render = true;
                return;
            }
            // Anything that is not a character — an arrow, Enter, a
            // function key — leaves the popup where it is rather than
            // dismissing it on a stray press.
            const c = k.typed() orelse return;
            if (c >= 128 or w.len >= whichkey.max_depth) return closeOverlay(app);
            w.path[w.len] = @intCast(c);
            w.len += 1;
            // The installed integrations' chords are rows here too, so
            // `<leader>ib` is reachable by looking as well as by typing.
            const node = (try whichkey.lookupWith(app.frame.allocator(), &app.dyn_commands, w.slice(), app.input_style == .vim)) orelse {
                // A dead end says so rather than vanishing — in the
                // active profile's spelling, so the standard profile is
                // not told about a `<leader>` it has no key for.
                const vim = app.input_style == .vim;
                const path = app.frame.allocator().dupe(u8, w.slice()) catch "";
                closeOverlay(app);
                app.toast("no leader mapping: {s}{s}{s}", .{ whichkey.leaderLabel(vim), whichkey.leaderGap(vim), path });
                return;
            };
            switch (node) {
                .group, .dyn_group => app.needs_render = true,
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
                .dyn => |d| {
                    const id = app.frame.allocator().dupe(u8, d.id) catch "";
                    closeOverlay(app);
                    command.runNamed(app, id) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {},
                    };
                },
            }
        },
        .picker => |*p| {
            // // changed (quickopen-prefixes): `>` `@` `:` `?` as the
            // FIRST character of quick open's query are VS Code's four
            // modes, not a filename.
            if (k.typed()) |c| if (c < 0x80 and try cmd_picker.quickOpenPrefix(app, &[_]u8{@intCast(c)})) return;
            switch (try Picker.handleKey(&p.state, gpa, k, p.filtered.items.len)) {
                .consumed => cmd_picker.preview(app),
                // The icon picker's Ctrl+C (the codepoint) before the keymap.
                .ignored => if (!(p.kind == .icon_glyphs and try icon_picker.chord(app, k))) try widgetFallthrough(app, k),
                .cancel => {
                    cmd_picker.cancel(app);
                    closeOverlay(app);
                },
                .changed => {
                    try refilterPicker(app);
                    @import("../scripting/api.zig").noteQueryChanged(app, app.now_ms);
                    @import("grep_picker.zig").noteQueryChanged(app, app.now_ms);
                    cmd_picker.preview(app);
                },
                .accept => |i| try cmd_picker.accept(app, i),
                .toggle => |i| cmd_picker.toggleMark(app, i),
            }
        },
        .settings => try settings_app.key(app, k),
        .wizard => try first_launch.key(app, k),
        .info => closeOverlay(app),
        // The discovery panel: F1 and Esc close it, as Rust's does.
        .discovery => if (k.code == .esc or (k.code == .f and k.code.f == 1)) closeOverlay(app),
        .help => try help_app.key(app, k),
        .jobs => |*st| try jobs_app.handleKey(app, st, k),
        .menu => |*m| {
            // A menu-bar menu: ← / → step to the neighbouring menu.
            if (try menu_bar.menuKey(app, k)) return;
            // The child owns the keys while it is open: ← / h step back
            // out of it, Enter / → / l run its row.
            if (m.sub) |*sub| {
                switch (k.code) {
                    .esc => closeOverlay(app),
                    .left => m.closeSub(gpa),
                    .enter => if (sub.items.len > 0) try runMenuAction(app, sub.items[sub.cursor].action),
                    .right => try subOpenRight(app),
                    .up => subMove(sub, -1),
                    .down => subMove(sub, 1),
                    .home => subMove(sub, std.math.minInt(i32)),
                    .end => subMove(sub, std.math.maxInt(i32)),
                    .char => |c| switch (c) {
                        'h' => m.closeSub(gpa),
                        'l' => try subOpenRight(app),
                        'k' => subMove(sub, -1),
                        'j' => subMove(sub, 1),
                        'q' => closeOverlay(app),
                        else => {},
                    },
                    else => {},
                }
                return;
            }
            switch (k.code) {
                .esc => closeOverlay(app),
                // Enter on a parent row opens it rather than firing —
                // the row has no action of its own.
                .enter => try menuEnter(app, m.cursor),
                .right => try menuOpenRight(app, m.cursor),
                .up => menuMove(m, -1),
                .down => menuMove(m, 1),
                .home => menuMove(m, std.math.minInt(i32)),
                .end => menuMove(m, std.math.maxInt(i32)),
                .char => |c| switch (c) {
                    'k' => menuMove(m, -1),
                    'j' => menuMove(m, 1),
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
    // The live-grep picker's query IS the pattern: the rows came back
    // already matching it, so a second, fuzzy pass over them would only
    // throw hits away. Keep the worker's order.
    if (p.kind == .grep) {
        try p.filtered.ensureTotalCapacity(app.gpa, p.labels.len);
        for (0..p.labels.len) |i| p.filtered.appendAssumeCapacity(@intCast(i));
        if (p.state.cursor >= p.filtered.items.len) p.state.cursor = 0;
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const items = try arena.alloc(Picker.Item, p.labels.len);
    // The icon picker matches the detail too (Rust's `refilter` for its
    // glyph rows): `cod-repo_pull` and `repo pull` land on the same row.
    for (p.labels, 0..) |label, i| items[i] = .{ .label = if (p.kind == .icon_glyphs and i < p.details.len) try std.mem.concat(arena, u8, &.{ label, "  ", p.details[i] }) else label };
    const ids: []const []const u8 = switch (p.kind) {
        .commands => try cmd_picker.commandIds(app, arena),
        // A typed codepoint pins its row (Rust's hex query).
        .icon_glyphs => try icon_picker.hexIds(app, arena),
        else => &.{},
    };
    const order = try Picker.rank(arena, p.state.query.items, items, .{ .priority = p.priority, .score_bonus = p.score_bonus, .ids = ids, .order = p.order, .terms = p.kind == .files or p.kind == .recent });
    try p.filtered.ensureTotalCapacity(app.gpa, order.len);
    for (order) |i| p.filtered.appendAssumeCapacity(@intCast(i));
    if (p.state.cursor >= p.filtered.items.len) p.state.cursor = 0;
}

fn acceptPrompt(app: *App, purpose: app_mod.PromptPurpose, text: []const u8) Allocator.Error!void {
    switch (purpose) {
        .ex_line => {
            const line = std.mem.trim(u8, text, " \t");
            if (line.len > 0) try runExLine(app, std.mem.trimStart(u8, line, ":"));
        },
        .goto_line => {
            // VS Code's forms: `12`, `12:5` or `12,5` (line, column), and
            // a negative line counting from the end (`-1` is the last).
            const t = std.mem.trimStart(u8, std.mem.trim(u8, text, " \t"), ":");
            if (t.len == 0) return;
            const sep = std.mem.indexOfAny(u8, t, ":,");
            const line_s = if (sep) |i| t[0..i] else t;
            const want = std.fmt.parseInt(i64, std.mem.trim(u8, line_s, " "), 10) catch {
                app.toast("not a number: \"{s}\"", .{t});
                return;
            };
            const col: usize = if (sep) |i| (std.fmt.parseInt(usize, std.mem.trim(u8, t[i + 1 ..], " "), 10) catch 1) -| 1 else 0;
            const e = app.activeEditor() orelse return;
            const lines: i64 = @intCast(e.buf.editor.lineCount());
            const n: usize = @intCast(std.math.clamp(if (want < 0) lines + want + 1 else want, 1, lines));
            e.buf.editor.placeCursor(n - 1, col);
            app.focus = .{ .pane = app.active.? };
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
        .session_worktree_name => |w| try toastOnFail(app, @import("session_worktree.zig").acceptNameCmd(app, w.product, w.profile, text)),
        .cloud_run_ticket => try cloud_agents.acceptRun(app, text, null),
        .cloud_run_wizard_ticket => try cloud_agents.acceptWizardTicket(app, text),
        .cloud_run_model => |ticket| try cloud_agents.acceptRun(app, ticket, text),
        .dock_new_text => |c| try dock.acceptNewText(app, c, text),
        .dock_new_log => |c| try dock.acceptNewLog(app, c, text),
        .dock_edit => |id| try dock.acceptEdit(app, id, text),
        .dock_rename => |id| try dock.acceptRename(app, id, text),
        .new_folder => |dir| try tree_mod.acceptNewFolder(app, dir, text),
        .rename => |from| try tree_mod.acceptRename(app, from, text),
        .move_paths => |ps| try files_pane.acceptMoveTo(app, @ptrCast(ps), text),
        .npm_run_script => try toastOnFail(app, runners.npmRunScriptAccept(app, text)),
        .launcher_add_local => try toastOnFail(app, launchers.addLocalAccept(app, text)),
        .go_run_path => try toastOnFail(app, runners.goRunPathAccept(app, text)),
        .ai_ask => try toastOnFail(app, ai_app.askAccept(app, text)),
        .ai_chat => try toastOnFail(app, ai_app.chatAccept(app, text)),
        .ai_search => try toastOnFail(app, ai_app.sessionSearchAccept(app, text)),
        .mount_open => try toastOnFail(app, mount_pane.acceptPrompt(app, text)),
        .term_rename => |id| try toastOnFail(app, cmd_term.renameAccept(app, id, text)),
        .grep_query => try grep.acceptQuery(app, text),
        .grep_replace => try grep.acceptReplace(app, text),
        .add_workspace => try tree_mod.acceptAddWorkspace(app, text),
        .terminal_glyph_svg => try toastOnFail(app, @import("terminal_glyph.zig").customAccept(app, text)),
        .claude_mark_svg => try toastOnFail(app, @import("claude_mark.zig").customAccept(app, text)),
        .ai_branch_name => try toastOnFail(app, ai_app.branchNameAccept(app, text)),
        .claude_account_add => try toastOnFail(app, usage_pane.addAccept(app, text)),
        .claude_account_token => |a| try toastOnFail(app, usage_pane.tokenAccept(app, a.name, text)),
        .claude_account_rename => |a| try toastOnFail(app, usage_pane.renameAccount(app, a.name, text)),
        .dap_add_watch => try dap.acceptWatch(app, text),
        .dap_bp_condition => |b| try dap.acceptCondition(app, b.path, b.line, text),
        .dap_hit_count => |b| try dap.acceptHitCount(app, b.path, b.line, text),
        .dap_set_variable => |sv| try dap.acceptSetVariable(app, sv.parent_ref, sv.name, text),
        .dap_edit_watch => |old| try dap.acceptEditWatch(app, old, text),
        .dap_bp_log => |b| try dap.acceptLogMessage(app, b.path, b.line, text),
        .lsp_rename => try lsp.acceptRename(app, text),
        .lua_bind => |b| try scripts_panel.acceptBind(app, b.id, text),
        .script_install => try @import("scripts.zig").acceptInstall(app, text),
        .lsp_workspace_symbol => try lsp.acceptWorkspaceSymbol(app, text),
        .ws_url, .ws_message => try ws_pane.acceptPrompt(app, purpose, text),
        .browser_url, .browser_navigate, .browser_eval, .browser_dialog, .browser_add_cookie, .browser_add_storage => try cmd_browser.acceptPrompt(app, purpose, text),
        .http_env_add_key, .http_env_edit_value, .http_auth_value, .http_option, .auth_preset_name, .http_save_as, .http_save_response, .http_new_env, .http_new_chain, .http_new_collection, .http_new_request, .http_lookup_var, .http_path_param => try cmd_http.acceptPrompt(app, purpose, text),
        .http_rename => |t| try @import("http_ops.zig").acceptRename(app, t, text),
        .http_description => try http_app.applyDescriptionPrompt(app, text),
        .http_tags => try http_app.applyTagsPrompt(app, text),
        .layout_save => try named_layouts.acceptSave(app, text),
        .layout_load => try named_layouts.acceptLoad(app, text),
        .layout_delete => try named_layouts.acceptDelete(app, text),
    }
}

/// A command-shaped call from an overlay: its reason is toasted the way
/// `command.run` would have.
fn toastOnFail(app: *App, result: command.CommandError!void) Allocator.Error!void {
    result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => {},
        else => if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("{s}", .{command.reason(err)}),
    };
}

fn acceptConfirm(app: *App, purpose: app_mod.ConfirmPurpose, choice: usize) Allocator.Error!void {
    switch (purpose) {
        .trust_workspace => try @import("trust.zig").answer(app, choice),
        .script_install => |i| try @import("scripts.zig").answerInstall(app, i, choice),
        .remove_script => |n| try @import("scripts.zig").answerRemove(app, n, choice),
        .layout_load => |n| try named_layouts.answerLoad(app, n, choice),
        .replace_confirm => try ex_verbs.answerConfirm(app, choice),
        .review_trust => try @import("workspace_trust.zig").answerReview(app, choice),
        .close_pane => |id| switch (choice) {
            0 => {
                // A ZON tree saves its working text.
                if (app.panes.get(id)) |p| if (p.* == .zon) {
                    zon_pane.save(app, id) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            if (app.diag.msg) |msg| app.toast("{s}", .{msg});
                            return;
                        },
                    };
                    try app.forceClosePane(id);
                    return;
                };
                const e = app.panes.editor(id) orelse return;
                if (e.buf.doc.path == null) {
                    app.toast("can't save a scratch buffer — pick Discard or Cancel", .{});
                    return;
                }
                // The one save path: the hooks, and a resolved conflict staged.
                cmd_file.savePane(app, id, e, .{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        if (app.diag.msg) |msg| app.toast("{s}", .{msg});
                        return;
                    },
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
        // // changed (quit-confirm): the clean box is two choices —
        // Quit, then Cancel — so 0 is the quit and anything else stays.
        .quit_clean => if (choice == 0) {
            app.quit = true;
        },
        .restart => switch (choice) {
            0 => {
                cmd_file.saveAll(app) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return, // toasted; the restart is off
                };
                app.restart = true;
                app.quit = true;
            },
            1 => {
                app.restart = true;
                app.quit = true;
            },
            else => {},
        },
        .delete_paths => |d| {
            try trash.acceptDelete(app, @ptrCast(d.paths), d.permanent_only, choice);
            // Only what is really gone: a path the trash could not take
            // is still there (the box asks again about it).
            if (choice == 0) for (d.paths) |p| {
                if (std.Io.Dir.cwd().access(app.io, p, .{})) continue else |_| {}
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
        .session_worktree_merge => |path| if (choice == 0) try toastOnFail(app, @import("session_worktree.zig").acceptMerge(app, path)),
        .session_worktree_remove => |r| try toastOnFail(app, @import("session_worktree.zig").acceptRemoveChoice(app, r, choice)),
        .http_delete_request => |t| if (choice == 0) try @import("http_ops.zig").acceptDelete(app, t),
        .install_tool => |idx| try toastOnFail(app, runners.installAccept(app, idx, choice)),
        .font_update => |idx| try toastOnFail(app, font_scan.updateAccept(app, idx, choice)),
        .git => try toastOnFail(app, git_app.acceptConfirm(app, choice)),
        .ai_tool => |job| ai_app.answerConfirm(app, job, choice == 0),
        .kill_pids => |pids| if (choice == 0) try sessions.killAccept(app, pids),
        .cloud_cancel => |arn| if (choice == 0) try cloud_agents.cancelAccept(app, arn),
        .remove_integration => |id| if (choice == 0) try integrations.removeAccept(app, id),
        .remove_claude_account => |name| if (choice == 0) try toastOnFail(app, usage_pane.removeAccount(app, name)),
        .choose_data_layout => try toastOnFail(app, @import("setup.zig").acceptDataLayout(app, choice)),
        .reset_to_defaults => try toastOnFail(app, @import("setup.zig").acceptReset(app, choice)),
    }
}

// ─── the find bar ───────────────────────────────────────────────────────

fn findBarKey(app: *App, k: Key) Allocator.Error!void {
    const fb = &app.find_bar.?;
    switch (try FindBar.handleKey(&fb.state, app.gpa, k)) {
        .consumed, .focus_toggle => {},
        .ignored => try widgetFallthrough(app, k),
        .toggle_regex, .toggle_case, .toggle_word => try cmd_find.liveUpdate(app),
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
            // // changed (quickopen-prefixes): a paste that STARTS with
            // one of quick open's four prefixes switches mode and
            // carries the rest in as the query.
            if (try cmd_picker.quickOpenPrefix(app, text)) return;
            try Picker.paste(&p.state, app.gpa, text);
            return refilterPicker(app);
        },
        // // changed (settings-search): the settings box's filter pill
        // takes a paste like any other text field.
        .settings => |*s| if (s.ui.filter.focused) return settings_app.paste(app, text),
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
    if (app.active) |id| if (app.panes.get(id)) |p| if (p.asZon()) |z| {
        if (app.focus == .pane) return zon_pane.paste(app, z, text);
    };
    // The graph's commit box: a pasted message keeps its lines.
    if (try git_app.pasteIntoCommitBox(app, text)) return;
    const e = app.activeEditor() orelse return;
    // A paste lands literally, as one change: no auto-indent, no pairs,
    // no abbreviations — `insert_str` is none of those. Its line breaks
    // are the buffer's (`\n`; the file's own ending goes back on at
    // save): a CRLF pair or a lone CR, what most terminals send, is one.
    const copy = try normalizePasteBreaks(app.frame.allocator(), text);
    _ = try app.applyOps(e, &.{.{ .insert_str = copy }});
}

/// `\r\n` and a lone `\r` become `\n`; everything else is kept.
pub fn normalizePasteBreaks(arena: Allocator, text: []const u8) Allocator.Error![]u8 {
    const out = try arena.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\r') {
            if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
            out[n] = '\n';
        } else out[n] = text[i];
        n += 1;
    }
    return out[0..n];
}

// ─── mouse ──────────────────────────────────────────────────────────────
// One `switch` on the hit under the pointer (D6). A press may start a
// gesture (`app.drag`) that the following drag events feed and the
// release completes; the hit under the release decides where a tab or
// a tree file lands. `count` is the wheel batch (`scroll.zig`).

/// `debug.toggle_click_inspector`: `click @12,3 → statusline_seg:2`,
/// or `nothing` where no target was painted.
fn inspectClick(app: *App, m: Mouse) Allocator.Error!void {
    var label: std.Io.Writer.Allocating = .init(app.frame.allocator());
    if (app.hits.at(m.x, m.y)) |target| {
        target.writeLabel(&label.writer) catch return error.OutOfMemory;
    } else label.writer.writeAll("nothing") catch return error.OutOfMemory;
    app.toast("{s} @{d},{d} → {s}", .{ if (m.button == .right) "right-click" else "click", m.x, m.y, label.written() });
}

pub fn mouse(app: *App, m: Mouse, count: u16) Allocator.Error!void {
    app.needs_render = true;
    app.hover = .{ .x = m.x, .y = m.y };
    app.hover_live = m.kind == .motion or m.kind == .drag;
    focus_follow.track(app, m);
    if (m.kind == .drag or m.kind == .release) {
        if (app.drag != null) return continueDrag(app, m);
    }
    if (m.kind == .motion) {
        if (app.overlay == .menu) try menuHover(app, m);
        // `ui.focus_follows_mouse`: the hover branch — off, an overlay
        // up or a button held, it does nothing (`focus_follow.zig`).
        focus_follow.onMotion(app, m);
        return;
    }
    // A press anywhere puts flash's labels away.
    if (m.kind == .press) flash.cancel(app);
    // The click inspector: what the press landed on, by the hit map's
    // label, before anything acts on it.
    if (m.kind == .press and app.debug_click_inspector and (m.button == .left or m.button == .right)) try inspectClick(app, m);
    // The click-discovery panel: a press on one of its rows flashes the
    // family it names; a press anywhere else closes it (Rust).
    if (m.kind == .press and app.overlay == .discovery) {
        if (app.hits.at(m.x, m.y)) |under| if (under == .overlay_item) return discovery.flashRow(app, under.overlay_item);
        closeOverlay(app);
        return;
    }
    // // changed (cmdline-fix): a press off the bar takes the focus
    // away from an EMPTY `:` line before the click goes on to whatever
    // it landed on — see `cmdline.clickAway` for why an empty line goes
    // and a half-typed one stays. The bar's own hit is exempt: a press
    // there is the line's own row.
    if (m.kind == .press and (m.button == .left or m.button == .right) and app.cmdline != null) {
        const on_bar = if (app.hits.at(m.x, m.y)) |u| u == .button and u.button == @intFromEnum(render.Button.cmdline_bar) else false;
        if (!on_bar) _ = cmdline_mod.clickAway(app);
    }
    // An armed button's release replays its press on the button itself,
    // whatever the frame since has painted under the pointer.
    const target = if (app.firing_button) |pb| pb.target() else app.hits.at(m.x, m.y) orelse {
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
            // // changed (settings-reset-confirm): while the ask is up a
            // press off it answers "no" rather than saving and closing
            // the whole box.
            .settings => |*st| if (target != .overlay_item and target != .scrollbar) {
                if (st.ui.confirm != null) {
                    st.ui.confirm = null;
                    app.needs_render = true;
                } else settings_app.close(app);
            },
            .picker => if (target != .overlay_item and target != .scrollbar) {
                cmd_picker.cancel(app);
                closeOverlay(app);
            },
            // The JOBS list: a press off its rows and bar closes it and
            // goes on to what it landed on (the chip that opened it
            // opens it again).
            .jobs => if (!(target == .row and target.row.panel == .jobs) and !(target == .scrollbar and target.scrollbar.owner == .panel and target.scrollbar.owner.panel == .jobs)) closeOverlay(app),
            else => {},
        }
    }
    // A button arms on the press and fires on the release inside it
    // (`Drag.button`, `continueDrag`): a press the pointer slides off —
    // a tab drag begun a cell too far right, on the close badge — is
    // taken back, as a GUI button's is. One rule here, so every chip,
    // badge and tool button the hit map knows as one behaves the same.
    if (m.kind == .press and m.button == .left and app.firing_button == null) if (firesOnRelease(target)) |pb| {
        app.drag = .{ .button = .{ .target = pb, .rect = hitRect(app, m.x, m.y) orelse Rect.init(m.x, m.y, 1, 1), .x = m.x, .y = m.y } };
        return;
    };
    const wheel = m.kind == .scroll_up or m.kind == .scroll_down;
    const down = m.kind == .scroll_down;
    // A notch on a pane's tab-strip row (a gap between tabs falls through
    // to the pane) scrolls the strip, not the buffer.
    if (wheel and target == .pane) {
        if (!app.zen) if (hitRect(app, m.x, m.y)) |r| if (r.h >= 2 and m.y == r.y) {
            if (wheelLines(app, count) == 0) return;
            if (app.layouts.current().leafOf(target.pane)) |lid| return tabStripStepLid(app, lid, if (down) 1 else -1);
        };
    }
    // The wheel over a surface that scrolls as one list — a panel's
    // rows, kebabs and bar, the tree's bar, the git rail's parts, an
    // open menu's rows — is routed here, so every way into a surface
    // moves it the same and the batch is budgeted once.
    if (wheel) {
        switch (target) {
            .row => |pr| return panelWheel(app, pr.panel, down, count),
            .kebab => |pr| return panelWheel(app, pr.panel, down, count),
            .git_palette => return panelWheel(app, .git, down, count),
            .welcome => |row| return welcomeWheel(app, row.list(), down, count),
            .scrollbar => |sb| switch (sb.owner) {
                .panel => |p| return panelWheel(app, p, down, count),
                .tree => return treeWheel(app, m, count),
                .welcome => |l| return welcomeWheel(app, l, down, count),
                .pane => |id| {
                    // The help box's and the picker's bars take the wheel
                    // as their rows do; any other pane's bar scrolls the pane.
                    if (id == HelpUi.scrollbar_owner and app.overlay == .help) return help_app.wheel(app, signed(down, count));
                    if (id == Picker.scrollbar_owner and app.overlay == .picker) {
                        const p = &app.overlay.picker;
                        Picker.wheel(&p.state, signed(down, app.cfg.ui.wheel_lines * count), p.filtered.items.len);
                        return cmd_picker.preview(app);
                    }
                    if (id == SettingsUi.scrollbar_owner and app.overlay == .settings) return settings_app.wheel(app, signed(down, count));
                    return wheelOnPane(app, id, m, count);
                },
            },
            // An open menu takes the wheel before anything under it (Rust
            // 1ef21198): a row per event; the paint clamps and pulls the
            // cursor along.
            .menu_item => |mi| if (app.overlay == .menu) return menuWheel(app, mi.menu, down, count),
            else => {},
        }
    }
    switch (target) {
        // The list panels (D6): one prong per hit kind, routed by panel.
        .row => |pr| switch (pr.panel) {
            .todos => try todos.rowMouse(app, pr.idx, m),
            .notes => try notes.rowMouse(app, pr.idx, m),
            .findings => try findings.rowMouse(app, pr.idx, m),
            .debug => try debug_panel.rowMouse(app, pr.idx, m),
            .sessions => try sessions.rowMouse(app, pr.idx, m),
            .git => try git_palette.rowMouse(app, pr.idx, m),
            .diagnostics => try lsp.rowMouse(app, pr.idx, m),
            .http => try http_panel.rowMouse(app, pr.idx, m),
            .integrations => try integrations.rowMouse(app, pr.idx, m),
            .scripts => try scripts_panel.rowMouse(app, pr.idx, m),
            .script => try script_section.rowMouse(app, pr.idx, m),
            .search => try search_section.rowMouse(app, pr.idx, m),
            .jobs => try jobs_app.rowMouse(app, pr.idx, m),
            .outline => {},
        },
        .kebab => |pr| switch (pr.panel) {
            .todos => try todos.kebabMouse(app, pr.idx, m),
            .notes => try notes.kebabMouse(app, pr.idx, m),
            .findings => try findings.kebabMouse(app, pr.idx, m),
            .debug => try debug_panel.kebabMouse(app, pr.idx, m),
            .sessions => try sessions.kebabMouse(app, pr.idx, m),
            .git => {},
            .http => try http_panel.kebabMouse(app, pr.idx, m),
            .integrations => try integrations.kebabMouse(app, pr.idx, m),
            .scripts => try scripts_panel.kebabMouse(app, pr.idx, m),
            .script => try script_section.kebabMouse(app, pr.idx, m),
            .search => try search_section.kebabMouse(app, pr.idx, m),
            .diagnostics, .outline, .jobs => {},
        },
        .chip => |c| switch (c.panel) {
            .todos => try todos.chipMouse(app, c.kind, m),
            .notes => try notes.chipMouse(app, c.kind, m),
            .findings => try findings.chipMouse(app, c.kind, m),
            .debug => try debug_panel.chipMouse(app, c.kind, m),
            .sessions => try sessions.chipMouse(app, c.kind, m),
            .git => try git_palette.chipMouse(app, c.kind, m),
            .diagnostics => try lsp.chipMouse(app, m),
            .http => try http_panel.chipMouse(app, c.kind, m),
            .integrations => try integrations.chipMouse(app, c.kind, m),
            .scripts => try scripts_panel.chipMouse(app, c.kind, m),
            .script => try script_section.chip(app, c.kind, m),
            .search => try search_section.chipMouse(app, c.kind, m),
            .outline, .jobs => {},
        },
        .filter_input => |p| switch (p) {
            .todos => todos.filterMouse(app, m),
            .notes => notes.filterMouse(app, m),
            .findings => findings.filterMouse(app, m),
            .debug => debug_panel.filterMouse(app, m),
            .sessions => sessions.filterMouse(app, m),
            .git => git_palette.filterMouse(app, m),
            .diagnostics => lsp.filterMouse(app, m),
            .http => http_panel.filterMouse(app, m),
            .integrations => integrations.filterMouse(app, m),
            .scripts => scripts_panel.filterMouse(app, m),
            .script => script_section.filterFocus(app),
            .search => search_section.filterMouse(app, m),
            .outline, .jobs => {},
        },
        .scrollbar => |sb| {
            // A press on a bar lands the view at the pointer's row and
            // starts a drag that keeps steering it off the bar until
            // the release (`Drag.bar`); the editor's thumb keeps the
            // row it was grabbed by instead.
            const track = hitRect(app, m.x, m.y) orelse return;
            const grab = m.kind == .press and m.button == .left;
            switch (sb.owner) {
                .panel => |p| panelScrollbar(app, p, track, m),
                .tree => app.tree.scrollbarMouse(app, track, m),
                .welcome => |l| welcome_app.scrollbarMouse(app, l, track, m),
                .pane => |id| {
                    if (!grab) return;
                    if (app.panes.editor(id) != null) return beginScrollbarDrag(app, id, track, m.y);
                    try paneBarJump(app, id, track, m.y);
                },
            }
            if (grab) app.drag = .{ .bar = sb.owner };
        },
        // A section header folds on a press; Alt folds or opens every
        // directory inside the primary with it (Rust `tree_toggle`).
        .tree_root => |root| {
            if (wheel) return treeWheel(app, m, count);
            if (m.kind != .press) return;
            // right-click: the root's workspace menu (Rust `tree_toggle`
            // / `extra_workspace_toggles`).
            if (m.button == .right) {
                if (app.overlay != .none) closeOverlay(app);
                return context_menus.openWorkspaceHeaderMenu(app, root, m.x, m.y);
            }
            if (m.button != .left) return;
            if (app.overlay != .none) closeOverlay(app);
            try app.tree.toggleRoot(app, root, m.mods.alt);
        },
        // right-click: the empty rows under the last section — a press
        // focuses the tree, a right press opens that root's workspace
        // menu (Rust: the empty Explorer space).
        .tree_empty => |root| {
            if (wheel) return treeWheel(app, m, count);
            if (m.kind != .press) return;
            if (app.overlay != .none) closeOverlay(app);
            if (m.button == .right) return context_menus.openWorkspaceHeaderMenu(app, root, m.x, m.y);
            if (m.button != .left) return;
            if (app.activeBuffer()) |b| b.input.onBlur();
            app.focus = .tree;
        },
        .tree_chip => |c| {
            if (wheel) return treeWheel(app, m, count);
            if (m.kind != .press or m.button != .left) return;
            if (app.overlay != .none) closeOverlay(app);
            try tree_mod.chipClick(app, c);
        },
        .info_view => |part| {
            if (m.kind == .press and app.overlay != .none and part != .kebab) closeOverlay(app);
            try info_view_app.mouse(app, part, m, count);
        },
        // // changed (search-section): a SEARCH header flag — one verb.
        .search_chip => |flag| {
            if (wheel) return panelWheel(app, .search, down, count);
            if (m.kind != .press or m.button != .left) return;
            if (app.overlay != .none) closeOverlay(app);
            try search_section.flagMouse(app, flag);
        },
        .menu_item => |mi| if (m.kind == .press) {
            if (app.overlay != .menu) return;
            const menu = &app.overlay.menu;
            // A right press on a row of a curatable menu: its pin /
            // hide / copy-id list, as the kebab and → open.
            if (m.button == .right) {
                if (!menu.curatable) return;
                switch (mi.menu) {
                    0, 2 => if (mi.idx < menu.items.len and menu.items[mi.idx].action == .command) {
                        menu.cursor = mi.idx;
                        try context_menus.openCuration(app, mi.idx, menu.items[mi.idx]);
                    },
                    1, 3 => if (menu.sub) |*sub| if (mi.idx < sub.items.len and sub.items[mi.idx].action == .command and !isCuration(sub.items[mi.idx])) {
                        sub.cursor = mi.idx;
                        try context_menus.openCuration(app, sub.parent, sub.items[mi.idx]);
                    },
                    else => {},
                }
                return;
            }
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
        .editor_cell => |cell| return editorCellMouse(app, cell, m, count, wheel),
        // The hover box: the wheel scrolls its lines two an event (Rust),
        // the box clamping at draw; a press puts it away, as a press
        // anywhere does.
        .hover_popup => {
            if (app.lsp.hover) |*h| {
                if (wheel) {
                    const step: usize = 2 * @as(usize, count);
                    h.scroll = if (m.kind == .scroll_down) h.scroll + step else h.scroll -| step;
                    return;
                }
                if (m.kind == .press) lsp.closeHover(app);
            }
        },
        // The gutter, the whole margin — the sign cell and the line
        // number alike. A right press opens the breakpoint menu on that
        // line. A left press on a debuggable file (`dap.gutterToggles`)
        // flips the line's breakpoint — VS Code's glyph margin, which
        // the testers expected of the numbers too; on any other file it
        // is the line-numbers convention: the line selected, the cursor
        // at its column 1 (Rust's gutter press fires `SelectLineToEnd`),
        // Shift extending the selection to that line. Anything else is
        // the editor cell at the line's start (the wheel, a drag).
        .gutter => |g| return gutterMouse(app, g, m, count, wheel),
        // The fold chevron owns its one cell of the gutter: a left press
        // toggles that line's fold. Everything else — the right press's
        // menu, a drag, the wheel — is the gutter's, so the chevron
        // never costs the row a behaviour.
        .fold_arrow => |f| {
            if (m.kind == .press and m.button == .left) return foldArrowPress(app, f);
            return gutterMouse(app, f, m, count, wheel);
        },
        .tab => |tb| {
            // // changed (bottom-dock): the dock's strip is not a leaf.
            if (tb.leaf == bottom.strip_leaf) return bottomTabClick(app, tb.idx, m);
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
                    // A double-click on the tab keeps a preview, as in
                    // VS Code — the same gesture as on the tree row.
                    if (clickCount(app, m) >= 2) if (app.panes.get(pane)) |p| p.setPreview(false);
                    app.showPane(pane);
                    app.drag = .{ .tab = .{ .pane = pane, .x = m.x, .y = m.y } };
                },
            }
        },
        .tab_close => |tb| {
            if (wheel or m.kind != .press or (m.button != .left and m.button != .right)) return;
            if (tb.leaf == bottom.strip_leaf) {
                const list = app.bottom.panes.items;
                if (tb.idx >= list.len) return;
                return app.closePane(list[tb.idx], false);
            }
            const layout = app.layouts.current();
            const lid = (try layout.leafAt(app.frame.allocator(), tb.leaf)) orelse return;
            const leaf = layout.leaf(lid) orelse return;
            if (tb.idx >= leaf.tabs.items.len) return;
            if (app.overlay != .none) closeOverlay(app);
            // right-click: the tab's menu — Rust's tab rect covered the
            // badge, so a right press there was the tab's.
            if (m.button == .right) return context_menus.openTabMenu(app, leaf.tabs.items[tb.idx], m.x, m.y);
            try app.closePane(leaf.tabs.items[tb.idx], false);
        },
        .breadcrumb => |bc| {
            // A segment opens a Files pane at the directory it names.
            if (wheel or m.kind != .press or (m.button != .left and m.button != .right)) return;
            const e = app.panes.editor(bc.pane) orelse return;
            const path = e.buf.doc.path orelse return;
            const dir = (try render.breadcrumbDir(app, app.frame.allocator(), path, bc.idx)) orelse return;
            if (app.overlay != .none) closeOverlay(app);
            // right-click: the directory's own rows (Zig-only).
            if (m.button == .right) return context_menus.openBreadcrumbMenu(app, dir, m.x, m.y);
            _ = try files_pane.open(app, dir);
        },
        .overlay_item => |i| {
            // The wheel over the Settings box scrolls its list; over the
            // picker it walks the cursor, as Rust's does.
            // A row per wheel event for the Settings and help boxes,
            // `wheel_lines` rows per event for the picker (Rust's three)
            // — none budgeted: a detent on ghostty is three events, and
            // that is the motion Rust's users have.
            if (wheel and app.overlay == .settings) return settings_app.wheel(app, signed(down, count));
            if (wheel and app.overlay == .picker) {
                Picker.wheel(&app.overlay.picker.state, signed(down, app.cfg.ui.wheel_lines * count), app.overlay.picker.filtered.items.len);
                cmd_picker.preview(app);
                return;
            }
            if (wheel and app.overlay == .help) return help_app.wheel(app, signed(down, count));
            if (m.kind != .press) return;
            // // changed (lua-track): right-click on a palette row — Run,
            // Bind in init.lua…, Copy id.
            if (m.button == .right and app.overlay == .picker) switch (app.overlay.picker.kind) {
                .commands => return cmd_picker.openRowMenu(app, i, m.x, m.y),
                .icon_glyphs => return icon_picker.openRowMenu(app, i, m.x, m.y),
                else => {},
            };
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
                    const kids = try whichkey.kidsWith(app.frame.allocator(), &app.dyn_commands, w.slice(), app.input_style == .vim);
                    if (i >= kids.len) return;
                    try overlayKey(app, Key.char(kids[i].key));
                },
                .settings => try settings_app.click(app, i),
                .wizard => try first_launch.click(app, i),
                // The find bar's chips, the rename preview and the completion
                // popup register their rows here with no overlay up.
                else => if (cmdline_popup.showing(app)) try cmdline_popup.click(app, i) else if (app.find_bar != null) try cmd_find.chipClick(app, i) else if (app.lsp.rename.preview != null) rename_app.click(app, i) else if (app.lsp.completion != null) try lsp.clickCompletion(app, i) else if (app.http.completion != null) try http_app.clickVarCompletion(app, i),
            }
        },
        .pane => |id| {
            if (app.panes.pty(id)) |p| {
                // The child tracks the mouse: every report goes to it,
                // pane-relative (the tab strip is the rect's first row).
                // Otherwise the wheel scrolls the scrollback.
                if (m.kind == .press) {
                    if (app.overlay != .none) closeOverlay(app);
                    focusOnPress(app, id);
                }
                // Shift overrides a child's mouse tracking for selecting,
                // as in ghostty and xterm.
                if (p.encoding().mouse == .none or (m.mods.shift and !wheel)) {
                    if (wheel) return wheelOnPane(app, id, m, count);
                    // right-click: Rust's dock menu, when the child is
                    // not tracking the mouse (a tracking child owns its
                    // right button).
                    if (m.kind == .press and m.button == .right) return context_menus.openPtyPaneMenu(app, id, m.x, m.y);
                    // Ctrl / Cmd + click opens an OSC 8 link the child
                    // printed, as ghostty's does.
                    if (m.kind == .press and m.button == .left and (m.mods.ctrl or m.mods.super)) {
                        if (pty_pane.linkAt(p, m.x, m.y)) |url| return git_app.openExternal(app, url);
                    }
                    // A left press anchors a text selection; the drag and
                    // the release come back through `continueDrag`.
                    if (m.kind == .press and m.button == .left) {
                        try pty_pane.selectPress(app, p, m.x, m.y, clickCount(app, m));
                        app.drag = .{ .pty_select = id };
                    }
                    return;
                }
                const r = hitRect(app, m.x, m.y) orelse return;
                const strip: u16 = if (r.h >= 2) 1 else 0;
                // A wheel batch reaches the child as the reports it was
                // — one per event, never budgeted: the child owns its
                // scrolling and asked for every report.
                var reps: u16 = if (wheel) @max(count, 1) else 1;
                while (reps > 0) : (reps -= 1) pty_pane.mouse(app, p, m, .{ .x = r.x, .y = r.y + strip });
                return;
            }
            if (wheel) return wheelOnPane(app, id, m, count);
            if (m.kind != .press) return;
            if (app.overlay != .none) closeOverlay(app);
            focus_follow.pointerFocus(app, id);
            // right-click: the editor's text menu; an AI pane's own
            // rows (Rust `open_ai_pane_context_menu`); any other pane
            // body gets its tab's menu (Zig-only — Rust fell through).
            if (m.button == .right) {
                if (app.panes.editor(id) != null) return context_menus.openEditorMenu(app, m.x, m.y);
                if (app.panes.get(id)) |pane| if (pane.* == .ai) return context_menus.openAiPaneMenu(app, m.x, m.y);
                try context_menus.openTabMenu(app, id, m.x, m.y);
            }
        },
        .script_hit => |sh| {
            // A mount forwards the wheel and the pointer; the rest of
            // the panes only hear presses.
            if (app.panes.get(sh.pane)) |mp_pane| if (mp_pane.asMount()) |mp| {
                if (wheel) {
                    const lines = wheelLines(app, count);
                    if (lines == 0) return;
                    return mount_pane.wheel(mp, sh.id, m, hitRect(app, m.x, m.y), lines);
                }
                if (m.kind == .motion or m.kind == .drag) return mount_pane.hover(mp, sh.id, m, hitRect(app, m.x, m.y));
            };
            if (wheel) return wheelOnPane(app, sh.pane, m, count);
            if (m.kind != .press) return;
            if (m.button != .left and m.button != .right) return;
            if (app.overlay != .none) closeOverlay(app);
            focusOnPress(app, sh.pane);
            const pane = app.panes.get(sh.pane) orelse return;
            switch (pane.*) {
                .cheatsheet => |*c| if (m.button == .left) try cheatsheet.click(app, c, sh.id),
                .script => |*s| try script_pane.click(app, sh.pane, s, sh.id, m),
                .list => |*l| {
                    if (sh.id >= try l.shownCount(app.frame.allocator())) return;
                    // // changed (git-more2): a right press opens the row's menu on the git kinds.
                    if (m.button == .right) {
                        l.cursor = sh.id;
                        if (app_mod.ListPane.filters(l.kind)) try git_app.openListRowMenu(app, l, m.x, m.y);
                        return;
                    }
                    if (l.cursor == sh.id) try listPaneEnter(app, sh.pane, l) else l.cursor = sh.id;
                },
                .git_status => |*s| try git_app.statusPaneClick(app, s, sh.id, m),
                .diff => |*d| try git_app.diffClick(app, sh.pane, d, sh.id, m),
                .git_graph => |*g| try git_app.graphClick(app, sh.pane, g, sh.id, m),
                .sessions_table => |*tp| try sessions_table.click(app, sh.pane, tp, sh.id, m),
                .spend_report => |*s| try spend.click(app, sh.pane, s, sh.id, m),
                .ai_usage => |*u| try usage_pane.click(app, u, sh.id, m),
                .grep => |*g| try grep.click(app, sh.pane, g, sh.id, m),
                .debug => if (m.button == .left) try dap.click(app, sh.pane, sh.id),
                .request => |*rp| try request_pane.click(app, sh.pane, rp, sh.id, m, hitRect(app, m.x, m.y)),
                .websocket => {},
                .browser => |*b| if (m.button == .left) try browser_pane.click(app, b, sh.id),
                .mount => |*mp| try mount_pane.click(app, sh.pane, mp, sh.id, m, hitRect(app, m.x, m.y)),
                .integrations => |*ip| try integrations.click(app, sh.pane, ip, sh.id, m),
                // A code lens segment sits above `lens_hit_base`; the
                // `{{VAR}}` spans below it.
                // The debug toolbar strip's buttons sit above both.
                .editor => |*e| if (debug_toolbar.actionOf(sh.id) != null) {
                    if (m.button == .left) try dap.click(app, sh.pane, sh.id);
                } else if (sh.id == line_blame.hit_id) {
                    if (m.button == .left) git_app.runToast(app, line_blame.click(app, sh.pane));
                } else if (conflicts.actionOf(sh.id) != null) {
                    if (m.button == .left) try conflicts.click(app, sh.pane, sh.id);
                } else if (sh.id >= decor.lens_hit_base) {
                    if (m.button == .left) try decor.scriptHit(app, sh.pane, sh.id);
                } else try http_app.editorVarClick(app, sh.pane, e, sh.id, m),
                .ai_apply => |*ap| ai_apply.click(app, ap, sh.id, m),
                .tests => |*tp| try tests_pane.click(app, tp, sh.id, m),
                .flaky => |*fp| flaky.click(app, fp, sh.id, m),
                .requests => |*rp| requests_pane.click(app, rp, sh.id, m),
                .files => |*f| try files_pane.click(app, sh.pane, f, sh.id, m),
                .zon => |*z| try zon_pane.click(app, sh.pane, z, sh.id, m),
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
                            // The press's place in a run of clicks decides how
                            // it opens: one is a glance (VS Code's preview tab),
                            // two keeps the tab.
                            app.drag = .{ .tree = .{ .idx = idx, .copy = m.mods.alt, .clicks = clickCount(app, m) } };
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
        // // changed (statusline-hover): a row of a figure's hover
        // list — one of the things the figure counts. A press runs
        // what the row names.
        .tip_row => |r| {
            if (m.kind != .press or m.button != .left) return;
            try runTipRow(app, r.seg, r.idx);
        },
        .statusline_seg => |seg| {
            if (m.kind != .press) return;
            if (app.overlay != .none) closeOverlay(app);
            const right = m.button == .right;
            switch (seg) {
                statusline.seg_mode => if (right) try context_menus.openModeMenu(app, m.x, m.y) else try runCmd(app, .@"editor.toggle_keymap"),
                // right-click: every chip Rust gives a menu has one here
                // (`context_menus.zig`, "the statusline chips").
                statusline.seg_position => if (right) try context_menus.openPositionMenu(app, m.x, m.y) else try runCmd(app, .@"editor.goto_line"),
                // The file chip is words on hover and a menu on the right
                // button; a left click does nothing, as in Rust.
                statusline.seg_file => if (right) try context_menus.openFileChipMenu(app, m.x, m.y),
                statusline.seg_language => if (right) try context_menus.openLanguageMenu(app, m.x, m.y) else {
                    // The detector's rule — file name, extension or
                    // shebang — so a `bin/run-all` painted as shell says
                    // why it is.
                    const lang: []const u8 = if (app.activeEditor()) |e| (e.buf.doc.language orelse "—") else "—";
                    const via: []const u8 = if (app.activeEditor()) |e| (highlight.detect.Detected{ .key = lang, .how = e.buf.doc.language_how }).viaLabel() else "file extension";
                    app.toast("language: {s} (via {s})", .{ lang, via });
                },
                statusline.seg_restricted => try runCmd(app, .@"workspace.review_trust"),
                else => if (statusline_app.SegId.of(seg)) |id| switch (id) {
                    .branch => if (right) try context_menus.openBranchMenu(app, m.x, m.y) else try runCmd(app, .@"git.status_pane"),
                    .pr => if (right) try context_menus.openPrMenu(app, m.x, m.y) else if (statusline_app.currentPr(app)) |pr| git_app.openExternal(app, pr.url),
                    .diagnostics => if (right) try context_menus.openDiagnosticsMenu(app, m.x, m.y) else try runCmd(app, .@"lsp.diagnostics"),
                    .symbol => if (right) try context_menus.openSymbolMenu(app, m.x, m.y) else try runCmd(app, .@"outline.show"),
                    .macro => try runCmd(app, .@"vim.macro_toggle"),
                    .find => if (right) try context_menus.openFindMenu(app, m.x, m.y) else try runCmd(app, .@"find.find"),
                    .test_run => if (right) try context_menus.openTestMenu(app, m.x, m.y) else if (tests_pane.find(app)) |id_pane| {
                        app.setActive(id_pane);
                        app.focus = .{ .pane = id_pane };
                    },
                    .ai_claude, .ai_codex => if (right) try context_menus.openAiChipMenu(app, id == .ai_codex, m.x, m.y) else try runCmd(app, if (id == .ai_codex) .@"ai.codex_usage" else .@"ai.claude_usage"),
                    // Ghost text: the picker on a click — the chip is
                    // there because something is wrong, and the backend
                    // is the first thing to check.
                    .ghost => if (right) try ghost_chip.openMenu(app, m.x, m.y) else try runCmd(app, .@"ai.setup_suggestions"),
                    .coverage => if (right) try coverage.openModeMenu(app, m.x, m.y) else try runCmd(app, .@"coverage.toast"),
                    // Background jobs: either button opens the list —
                    // the chip is a count, the list is what it counts.
                    .jobs => try runCmd(app, .@"jobs.show"),
                    // The now-playing cluster: the right button is the player
                    // menu on every chip; the left drives the player.
                    .np_brand, .np_track => if (right) try now_playing.openMenu(app, m.x, m.y) else try now_playing.click(app, .label),
                    .np_play => if (right) try now_playing.openMenu(app, m.x, m.y) else try now_playing.click(app, .play),
                    .np_next => if (right) try now_playing.openMenu(app, m.x, m.y) else try now_playing.click(app, .next),
                    .transfer => if (right) try context_menus.openTransferMenu(app, m.x, m.y),
                    // The LSP chip, as Rust: the servers on the left button
                    // (`:LspStatus`), the LSP menu on the right.
                    .lsp => if (right) try statusline_app.openLspChipMenu(app, m.x, m.y) else try runCmd(app, .@"lsp.status"),
                    .wrap => if (right) try context_menus.openWrapMenu(app, m.x, m.y) else try runCmd(app, .@"view.toggle_wrap"),
                    .autosave => app.toast("autosave: {d}s (`[editor] autosave_secs` to change)", .{app.cfg.editor.autosave_secs}),
                    // The one-click override for the file at hand.
                    .highlight => try runCmd(app, .@"editor.highlight_toggle_file"),
                    .filesize => if (right) try context_menus.openSizeMenu(app, m.x, m.y) else if (app.activeEditor()) |e| {
                        const n = e.buf.editor.bytes().len;
                        app.toast("{s}: {d} byte{s} · {d} line{s}", .{ if (e.buf.doc.path) |pth| std.fs.path.basename(pth) else "[scratch]", n, if (n == 1) "" else "s", e.buf.editor.lineCount(), if (e.buf.editor.lineCount() == 1) "" else "s" });
                    },
                    .sel => if (right) try context_menus.openSelMenu(app, m.x, m.y),
                    .stress => if (right) try context_menus.openStressMenu(app, m.x, m.y) else try runCmd(app, .@"perf.toast_stress"),
                    .bell => if (right) try context_menus.openBellMenu(app, m.x, m.y) else try runCmd(app, .@"messages.show"),
                    .clock => if (right) try clock_mod.openMenu(app, m.x, m.y) else try runCmd(app, if (app.clock.mode == .utc) .@"clock.local" else .@"clock.utc"),
                    .workspace => if (right) try context_menus.openWorkspaceChipMenu(app, m.x, m.y) else try runCmd(app, if (app.git.repos.items.len > 1) .@"git.switch_repo" else .@"view.switch_workspace"),
                    .zoom => try runCmd(app, .@"view.toggle_zoom"),
                    .dev_profile => app.toast("dev profile — state in {s} (the installed mnml keeps its own)", .{app.data_root}),
                    _ => {},
                } else if (seg >= statusline.seg_dyn_base) {
                    // A host's segment: its `click_command` on a left
                    // click, its own menu on a right one.
                    const slot = seg - statusline.seg_dyn_base;
                    if (right) try context_menus.openIntegrationSegmentMenu(app, slot, m.x, m.y) else try ipc.effects.clickSegment(app, slot);
                },
            }
        },
        .dock => |d| try dock.mouse(app, d.id, d.part, m),
        .launcher_dock => |part| try launcher_dock.mouse(app, part, m),
        .rail => |part| try activity_bar.mouse(app, part, m),
        .git_palette => |part| try git_palette.partMouse(app, part, m),
        .font_update => |row| try font_scan.updateChipMouse(app, row, m),
        .http => |part| try http_panel.partMouse(app, part, m),
        // The welcome pane: a row acts on a press (`app/welcome.zig`).
        .welcome => |row| if (!wheel) try welcome_app.mouse(app, row, m),
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
            // The strip's ZON chips (`render.modeChip`).
            if (id == zon_pane.button_view) return runCmd(app, .@"zon.view");
            if (id == zon_pane.button_source) return runCmd(app, .@"zon.source");
            if (id == toast_mod.undo_button) {
                // The Undo chip: left commits the undo, right drops the offer.
                if (m.button == .right) app.dropUndo() else try app.takeUndo();
                return;
            }
            // // changed (bottom-row): a toast's own controls, read
            // before the catch-all dismiss arm below it.
            if (id >= toast_mod.action_base) {
                const from_close = id >= toast_mod.close_base;
                const i = id - (if (from_close) toast_mod.close_base else toast_mod.action_base);
                if (i >= app.toasts.items.len) return;
                const at = app.toasts.items.len - 1 - i;
                if (from_close) {
                    app.dismissToastAt(at);
                    return;
                }
                // The offer, not a dismiss: losing the thing you meant
                // to act on is the worse mistake, since the box is then
                // gone. Taken by value first — running it may toast.
                const action = app.toasts.items[at].action orelse return;
                app.toasts.items[at].action = null;
                defer action.deinit(app.gpa);
                app.dismissToastAt(at);
                return app.runToastAction(action);
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
                    // A script error's toast: the click jumps to its line.
                    const is_script = if (app.toasts.items[at].id) |tid| std.mem.eql(u8, tid, script_diag.toast_id) else false;
                    // // changed (git-more2): a failed git op's toast: the
                    // click opens the command log at the child that failed.
                    const is_git_log = if (app.toasts.items[at].id) |tid| std.mem.eql(u8, tid, git_app.log_toast_id) else false;
                    app.dismissToastAt(at);
                    if (is_script) try script_diag.jump(app);
                    if (is_git_log) git_app.runToast(app, git_app.openCommandLog(app, null));
                }
                return;
            }
            // // changed (bottom-row): the row under the statusline.
            // Handled above the overlay close so a click there does not
            // also tear down a picker the user is looking at.
            switch (@as(render.Button, @enumFromInt(id))) {
                // The bar: opens the `:` line. Already open, a click is
                // a no-op — the user is typing on it.
                .cmdline_bar => {
                    if (app.cmdline == null) cmdline_mod.open(app);
                    return;
                },
                // The `⟳ … running…` indicator: stop what it reports.
                .cmdline_inflight => return runCmd(app, .@"http.abort"),
                // The echoed toast's `[name]`: the pane it names. Read
                // off the live toast rather than a rect captured last
                // frame — the toast may have aged out since.
                .cmdline_mention => {
                    const msg = app.lastToast() orelse return;
                    const name = cmdline_bar_mod.mentionName(msg) orelse return;
                    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*pane| {
                        if (std.mem.indexOf(u8, pane.title(), name) != null) {
                            app.showPane(@intCast(i));
                            return;
                        }
                    };
                    app.toast("no pane named {s}", .{name});
                    return;
                },
                else => {},
            }
            if (app.overlay != .none) closeOverlay(app);
            // The palette bar's integration chips.
            if (id >= integrations_view.chip_base and id < integrations_view.chip_base + integrations_view.max_chips) {
                return integrations.chipClick(app, id - integrations_view.chip_base, m);
            }
            // right-click: the chrome chips' menus (Rust `right_click.rs`;
            // `context_menus.openButtonMenu`). A strip chip's rows act on
            // the leaf it sits on. A chip with no menu falls through.
            if (m.button == .right) {
                switch (@as(render.Button, @enumFromInt(id))) {
                    .split_term, .split_right, .split_down, .split_max, .ai_claude, .ai_codex => focusLeafAt(app, m.x, m.y),
                    else => {},
                }
                if (try context_menus.openButtonMenu(app, id, m.x, m.y)) return;
            }
            // The INTEGRATIONS section's tabs.
            // // changed (lua-install): the SCRIPTS section's tabs — the
            // same strip, its own base.
            if (id >= integrations_view.script_tab_base and id < integrations_view.script_tab_base + integrations_view.Tab.all.len) {
                scripts_panel.tabMouse(app, @enumFromInt(id - integrations_view.script_tab_base), m);
                return;
            }
            if (id >= integrations_view.tab_base and id < integrations_view.tab_base + integrations_view.Tab.all.len) {
                return integrations.tabClick(app, id - integrations_view.tab_base, m);
            }
            if (menu_bar.buttonOf(id)) |which| {
                const r = hitRect(app, m.x, m.y) orelse Rect.init(m.x, m.y, 1, 1);
                return menu_bar.open(app, which, r.x, m.y + 1, false);
            }
            if (id == menu_bar.overflow_button) {
                const r = hitRect(app, m.x, m.y) orelse Rect.init(m.x, m.y, 1, 1);
                return menu_bar.openOverflow(app, r.x, m.y + 1);
            }
            // The strip's `+`: the `Create…` menu, hung under the chip,
            // on either button (Rust `split_tab_plus_buttons` /
            // `bufferline_empty_plus`); the leaf it sits on is made
            // current first so the rows act there.
            if (render.Button.newTabLeaf(id)) |leaf_idx| {
                // Git mode's `+` brings a closed repo back (Rust `git.reopen_repo`).
                if (m.button == .left and app.git_palette.active) return runCmd(app, .@"git.reopen_repo");
                const layout = app.layouts.current();
                if (try layout.leafAt(app.frame.allocator(), leaf_idx)) |lid| {
                    if (layout.leaf(lid)) |leaf| app.setActive(leaf.active);
                }
                const r = hitRect(app, m.x, m.y) orelse Rect.init(m.x, m.y, 1, 1);
                return context_menus.openNewTabMenu(app, r.x, r.y + 1);
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
                .right_close => try runCmd(app, .@"view.right_panel_close_tab"),
                .right_tab => try runCmd(app, .@"view.focus_right_panel"),
                .right_new => try context_menus.openAddPanelMenu(app, m.x, m.y),
                // // changed (bottom-dock): the dock's `×`.
                .bottom_close => try runCmd(app, .@"view.toggle_bottom_panel"),
                // // changed (sidebar-autohide): the revealed column's
                // own cells. The pin chip docks it; the ground swallows
                // the press so it cannot fall through onto the editor
                // the panel is floating over, and a right press on it
                // offers the three modes.
                .sidebar_pin => try runCmd(app, .@"view.sidebar_pin"),
                // // changed (menu-bar-pin): the chip past the words.
                // Its right press is the bar's own menu
                // (`openButtonMenu`), which ran before this switch.
                .menu_bar_pin => try runCmd(app, .@"view.menu_bar_pin"),
                // // changed (edge-grip): the `⋯` / `⋮` handle at the
                // middle of a hidden slide-in's edge. A left click
                // reveals AND pins — the grip brings the surface out
                // and keeps it, the chip at its other end lets it go —
                // through the pin command each surface already has, so
                // there is no new command id. The right press is that
                // surface's own menu (`openButtonMenu`, which ran
                // before this switch).
                .edge_grip_menu_bar => try runCmd(app, .@"view.menu_bar_pin"),
                .edge_grip_sidebar_left, .edge_grip_sidebar_right => {
                    const grip_side: Config.ColumnSide = if (@as(render.Button, @enumFromInt(id)) == .edge_grip_sidebar_left) .left else .right;
                    sidebar_auto.gripPin(app, grip_side) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {},
                    };
                },
                .edge_grip_dock => try runCmd(app, .@"view.dock_pin"),
                .sidebar_overlay => if (m.button == .right) try context_menus.openSidebarModeMenu(app, m.x, m.y),
                .back => try runCmd(app, .@"buffer.prev"),
                .forward => try runCmd(app, .@"buffer.next"),
                .dropdown => try runCmd(app, .@"picker.recent"),
                // The top-right `+`: a tab page on the left button (what its
                // place promises), the `Create…` menu on the right (Rust
                // `right_click.rs`, 2026-09-03).
                .new_tab_page => if (m.button == .right) {
                    const r = hitRect(app, m.x, m.y) orelse Rect.init(m.x, m.y, 1, 1);
                    try context_menus.openNewTabMenu(app, r.x, r.y + 1);
                } else try runCmd(app, .@"tab.new"),
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
                // What the button does on a left click is
                // `ui.maximize_click`'s to say; while something is
                // already maximized it is the way back whatever the
                // mode (`app/zen.zig`).
                .split_max => {
                    focusLeafAt(app, m.x, m.y);
                    try runCmd(app, zen.clickCommand(app));
                },
                // Full screen's corner mark: the click leaves.
                .fullscreen_exit => try runCmd(app, .@"view.fullscreen"),
                .hidden_tabs => try runCmd(app, .@"picker.buffers"),
                // The chips are the way to the SESSIONS panel; a click
                // starts a session only when none of that product is
                // running (`app/ai.zig`'s `chipClick`).
                .ai_claude => try chipClick(app, .claude),
                .ai_codex => try chipClick(app, .codex),
                else => {},
            }
        },
        // right-click: a link's open / copy rows (Rust copies the URL
        // of a detail pane's link row).
        .link => |l| if (m.kind == .press and m.button == .right) {
            if (app.overlay != .none) closeOverlay(app);
            try context_menus.openLinkMenu(app, l.url, m.x, m.y);
        },
        // The AI grid's open slot: a press opens the next session in it.
        .ai_placeholder => if (m.kind == .press and m.button == .left) {
            if (app.overlay != .none) closeOverlay(app);
            try runCmd(app, .@"ai.claude_code_new");
        },
    }
}

/// A press in pane `id` gives it the keys: shown, active, focused. The
/// pane-body presses focused only a pane that was not already the
/// active one — and the active pane with the keys in the tree (`Esc`
/// from the status pane, `Space e`, a tree click) is exactly the case
/// a click on it is for: the click moved the cursor there and the next
/// key still went to the tree.
fn focusOnPress(app: *App, id: PaneId) void {
    if (app.active != id or app.focus != .pane) app.showPane(id);
}

/// A press in an editor's gutter — the sign cell and the line number
/// alike. Shared by `.gutter` and the fold chevron's `.fold_arrow`,
/// which falls back to it for everything but its own left press.
fn gutterMouse(app: *App, g: hit_mod.GutterRef, m: Mouse, count: u16, wheel: bool) Allocator.Error!void {
    if (m.kind == .press and (m.button == .right or m.button == .left)) {
        if (app.panes.editor(g.pane)) |e| {
            if (app.overlay != .none) closeOverlay(app);
            focusOnPress(app, g.pane);
            const ed = e.buf.editor;
            const line = @min(g.line, ed.lineCount() -| 1);
            if (m.button == .right or try dap.gutterToggles(app, e)) {
                ed.anchor = null;
                ed.placeCursor(line, 0);
                if (m.button == .right) return context_menus.openGutterMenu(app, m.x, m.y);
                return dap.gutterToggle(app, g.pane, line);
            }
            const start = ed.lineStart(line);
            const stop = @min(ed.lineEnd(line) + 1, ed.len());
            if (m.mods.shift and ed.anchor != null) {
                // Extend the selection to cover that line too:
                // down from its low end, or up from its high end.
                const lo = @min(ed.anchor.?, ed.cursor);
                const hi = @max(ed.anchor.?, ed.cursor);
                if (start >= lo) {
                    ed.anchor = lo;
                    ed.setCursor(stop);
                } else {
                    ed.anchor = hi;
                    ed.setCursor(start);
                }
            } else {
                ed.anchor = stop;
                ed.setCursor(start);
            }
            e.buf.input.requestVisualMode();
            return;
        }
    }
    return editorCellMouse(app, .{ .pane = g.pane, .line = g.line, .col = 0 }, m, count, wheel);
}

/// The fold chevron's left press: the cursor onto that line, then the
/// very command `za` runs, so the fold, its undo and the dot repeat see
/// nothing a keyboard toggle would not.
fn foldArrowPress(app: *App, f: hit_mod.GutterRef) Allocator.Error!void {
    const e = app.panes.editor(f.pane) orelse return;
    if (app.overlay != .none) closeOverlay(app);
    focusOnPress(app, f.pane);
    const ed = e.buf.editor;
    ed.anchor = null;
    ed.placeCursor(@min(f.line, ed.lineCount() -| 1), 0);
    return runCmd(app, .@"editor.toggle_fold");
}

/// The pane whose rect holds `(x, y)` becomes active — a strip's
/// buttons act on their own leaf, wherever the focus was.
fn focusLeafAt(app: *App, x: u16, y: u16) void {
    for (app.hits.items.items) |h| if (h.target == .pane and h.rect.contains(x, y)) {
        app.setActive(h.target.pane);
        return;
    };
}

/// `ai_app.chipClick` with the command errors swallowed, as `runCmd`
/// does — a chip click reports through a toast, never through the
/// mouse path.
fn chipClick(app: *App, product: app_mod.Config.AiProduct) Allocator.Error!void {
    ai_app.chipClick(app, product) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

/// A press on one row of a figure's hover list. The row is re-derived
/// from the segment rather than remembered: the tip's strings live on
/// the frame that painted them, and the segment is the durable thing.
fn runTipRow(app: *App, seg: u32, idx: u16) Allocator.Error!void {
    const arena = app.frame.allocator();
    const tip = (try discovery.describe(app, arena, .{ .statusline_seg = seg })) orelse return;
    if (idx >= tip.rows.len) return;
    const row = tip.rows[idx];
    const id = row.command orelse return;
    const ref = command.resolve(app, id) orelse {
        app.toast("no such command: {s}", .{id});
        return;
    };
    // `args` are the row's deep link: a command that mounts a binary
    // takes them on its argv, so a row says WHICH pull request rather
    // than only which pane.
    if (row.args.len > 0 and try mountWithArgs(app, ref, row.args)) return;
    command.run(app, ref) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

/// // changed (focus-row): the one deep-link shape the host knows.
/// A hover row's `args` of exactly `--focus <key>` name ONE thing
/// inside a listing rather than a different listing, so the pane they
/// reach is the same pane: already open, it is handed the key down the
/// mount; not open, it is started with the flag on its argv. Any other
/// `args` are just argv, and a different argv is a different pane.
pub fn focusKeyOf(extra: []const []const u8) ?[]const u8 {
    if (extra.len != 2) return null;
    if (!std.mem.eql(u8, extra[0], "--focus")) return null;
    if (extra[1].len == 0) return null;
    return extra[1];
}

/// True when `ref` mounts a binary and the run was started with
/// `extra` appended to its argv.
fn mountWithArgs(app: *App, ref: command.CommandRef, extra: []const []const u8) Allocator.Error!bool {
    const slot = switch (ref) {
        .dyn => |sl| sl,
        .static => return false,
    };
    const c = app.dyn_commands.at(slot) orelse return false;
    if (c.runner != .mount) return false;
    const r = c.runner.mount;
    const arena = app.frame.allocator();
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    for (r.args) |a| try argv.append(arena, a);
    for (extra) |a| try argv.append(arena, a);
    const focus = focusKeyOf(extra);
    integrations.runMount(app, .{
        .id = switch (c.owner) {
            .integration => |i| i,
            else => "",
        },
        .binary = r.binary,
        .args = argv.items,
        .pty = r.pty,
        .label = r.label,
        .deep_link = if (focus != null) extra.len else 0,
        .focus = focus orelse "",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    return true;
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
        .menu, .info, .discovery, .help, .jobs => closeOverlay(app),
        .settings => settings_app.close(app),
        .picker => {
            cmd_picker.cancel(app);
            closeOverlay(app);
        },
        else => {},
    }
}

// ── the editor: click, drag-select, double / triple ──

/// The press's place in a run of clicks: 1 for a first press, 2 for a
/// second on the same cell within the double-click window, 3 for a
/// third (and any after). One bookkeeping for every surface that acts
/// on a double-click — the editor's word / line select, the branches
/// panel's rows — so they cannot drift on the window or the cell rule.
pub fn clickCount(app: *App, m: Mouse) u8 {
    const now = app.now_ms;
    var count: u8 = 1;
    if (app.last_click) |lc| {
        if (lc.x == m.x and lc.y == m.y and now - lc.at_ms <= app_mod.double_click_ms) count = @min(lc.count + 1, 3);
    }
    app.last_click = .{ .at_ms = now, .x = m.x, .y = m.y, .count = count };
    return count;
}

/// A left press in the text: shift extends the selection; a second
/// press within the double-click window selects the word, a third the
/// line; and the press anchors a drag-select at its granularity.
fn editorPress(app: *App, pane: PaneId, e: *EditorPane, byte: usize, m: Mouse) Allocator.Error!void {
    const ed = e.buf.editor;
    const count = clickCount(app, m);
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
    const cell = switch (app.hits.at(x, y) orelse return null) {
        .editor_cell => |c| c,
        else => return null,
    };
    if (cell.pane != pane) return null;
    const line = @min(cell.line, ed.lineCount() - 1);
    return cellByte(ed, line, cell.col);
}

/// The byte an `.editor_cell` hit names: `off` is the grapheme's byte
/// offset within `line` (the line's length for the cells past its end),
/// so the second cell of a wide glyph and every EOL cell resolve to
/// their own grapheme. The hit map speaks bytes; nothing here counts
/// chars or adds the pointer's cell delta — that pairing put the cursor
/// one char right of the glyph per multi-byte char before it (`ö`
/// clicked → the `d` after it).
fn cellByte(ed: *const Editor, line: usize, off: u32) usize {
    return @min(ed.lineStart(line) + off, ed.lineEnd(line));
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

/// The lines the batch under dispatch may move: the count through the
/// accel curve and the bucket (`scroll.Accel`), spent once per
/// dispatch — a second ask in the same dispatch reads the answer.
/// Zero is a dry bucket at `scroll_accel = off`; the arm moves nothing.
fn wheelLines(app: *App, count: u16) u16 {
    if (app.wheel_budget) |b| return b;
    const b = app.accel.apply(app.cfg.editor.scroll_accel, @max(count, 1), app.now_ms);
    app.wheel_budget = b;
    return b;
}

fn signed(down: bool, n: u16) isize {
    const v: isize = @intCast(n);
    return if (down) v else -v;
}

/// The wheel scrolls the pane under the pointer. A text body — the
/// editor, a markdown preview, a diff — moves `wheel_lines` lines per
/// budgeted event (Rust's editor gain of three); every list moves a
/// row per event. In the editor `wheel_moves_cursor` decides: the
/// cursor moves and the view follows, or the view moves and pins
/// until the cursor does. Shift scrolls sideways.
fn wheelOnPane(app: *App, id: PaneId, m: Mouse, count: u16) Allocator.Error!void {
    const pane = app.panes.get(id) orelse return;
    const lines = wheelLines(app, count);
    if (lines == 0) return;
    const n: usize = lines;
    const gain: usize = @max(app.cfg.ui.wheel_lines, 1);
    const down = m.kind == .scroll_down;
    switch (pane.*) {
        .editor => |*e| {
            const ed = e.buf.editor;
            const ln = n * gain;
            if (m.mods.shift) {
                const cur: usize = e.view.scroll_col;
                e.view.scroll_col = @intCast(if (down) cur + ln else cur -| ln);
                e.view.pinAt(ed.cursor);
                return;
            }
            if (app.cursorFollowsWheel()) {
                var i: usize = 0;
                while (i < ln) : (i += 1) _ = try app.applyOps(e, &.{if (down) .move_down else .move_up});
                return;
            }
            const max: i64 = @intCast(ed.lineCount() -| 1);
            const cur: i64 = e.view.scroll_line;
            const delta: i64 = @intCast(ln);
            e.view.scroll_line = @intCast(std.math.clamp(if (down) cur + delta else cur - delta, 0, max));
            e.view.pinAt(ed.cursor);
        },
        // Rust's cheatsheet steps one row a batch.
        .cheatsheet => |*c| {
            c.selected = if (down) c.selected + 1 else c.selected -| 1;
        },
        .script => |*s| script_pane.wheel(app, s, down, n),
        .list => |*l| {
            const total = l.shownCount(app.frame.allocator()) catch l.entries.items.len;
            l.cursor = if (down) @min(l.cursor + n, total -| 1) else l.cursor -| n;
        },
        .outline => |*o| {
            o.cursor = if (down) @min(o.cursor + n, o.items.items.len -| 1) else o.cursor -| n;
        },
        .md_preview => |*mp| md_preview.scrollBy(app, mp, signed(down, @intCast(n * gain))),
        .zon => |*z| zon_pane.wheel(app, z, down, n),
        // A row of scrollback a notch (Rust's `scroll_history`); a pager
        // on the alternate screen gets `wheel_lines` arrows, a text
        // body's gain (`pty_pane.wheel`).
        .pty => |*p| pty_pane.wheel(app, p, down, n, n * gain),
        .git_status => |*s| git_app.statusPaneWheel(app, s, down, n),
        .diff => |*d| git_app.stepDiff(d, signed(down, @intCast(n * gain))),
        .git_graph => |*g| g.cursor = if (down) @min(g.cursor + n, g.totalRows() -| 1) else g.cursor -| n,
        .ai => |*a| ai_app.scrollBy(a, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .sessions_table => |*tp| sessions_table.scrollBy(tp, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .spend_report => |*s| spend.scrollBy(s, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .ai_usage => |*u| usage_pane.scrollBy(u, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .grep => |*g| grep.scrollBy(g, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .debug => try dap.scrollBy(app, id, if (down) @as(i32, @intCast(n)) else -@as(i32, @intCast(n))),
        .request => |*rp| request_pane.scrollBy(rp, if (down) @as(i32, @intCast(n)) else -@as(i32, @intCast(n))),
        .websocket => |*w| ws_pane.scrollBy(w, if (down) @as(i32, @intCast(n)) else -@as(i32, @intCast(n))),
        .browser => |*b| browser_pane.scrollBy(b, if (down) @as(i32, @intCast(n)) else -@as(i32, @intCast(n))),
        // Reached only over a rect the view did not register (none): the
        // mount's rows carry the wheel through `.script_hit`.
        .mount => {},
        .integrations => |*ip| integrations.scrollBy(app, ip, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .ai_apply => |*ap| ai_apply.scrollBy(ap, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .tests => |*tp| tests_pane.scrollBy(tp, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .flaky => |*fp| flaky.scrollBy(fp, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .requests => |*rp| requests_pane.scrollBy(rp, if (down) @as(i64, @intCast(n)) else -@as(i64, @intCast(n))),
        .files => |*f| files_pane.scrollBy(f, signed(down, scroll_mod.listStep(lines, app.cfg.editor.scroll_accel))),
        .image => {},
    }
}

/// The wheel over a panel: the budgeted count, clamped to the list
/// cap for the setting (Rust `list_scroll_clamp_scaled`), moves the
/// panel's cursor or window that many rows.
fn panelWheel(app: *App, panel: hit_mod.PanelId, down: bool, count: u16) Allocator.Error!void {
    const lines = wheelLines(app, count);
    if (lines == 0) return;
    const rows: usize = scroll_mod.listStep(lines, app.cfg.editor.scroll_accel);
    switch (panel) {
        .todos => todos.wheel(app, down, rows),
        .notes => notes.wheel(app, down, rows),
        .findings => findings.wheel(app, down, rows),
        .sessions => sessions.wheel(app, down, rows),
        .debug => debug_panel.wheel(app, down, rows),
        .git => git_palette.wheel(app, down, rows),
        // Rust's diagnostics pane moves the selection by the budgeted
        // count, unclamped.
        .diagnostics => try lsp.wheel(app, down, lines),
        .http => http_panel.wheel(app, down, rows),
        .integrations => integrations.wheel(app, down, rows),
        .scripts => try scripts_panel.wheel(app, down, rows),
        .script => try script_section.wheel(app, down, rows),
        .search => search_section.wheel(app, down, rows),
        .jobs => jobs_app.wheel(app, down, rows),
        .outline => if (app.outline_panel) |id| try wheelOnPane(app, id, .{ .x = 0, .y = 0, .kind = if (down) .scroll_down else .scroll_up }, count),
    }
}

/// The wheel over a start-surface list (`app/welcome.zig`).
fn welcomeWheel(app: *App, l: hit_mod.WelcomeList, down: bool, count: u16) Allocator.Error!void {
    const lines = wheelLines(app, count);
    if (lines == 0) return;
    welcome_app.wheel(app, l, down, scroll_mod.listStep(lines, app.cfg.editor.scroll_accel));
}

/// A press or drag on a panel's scrollbar: the panel lands its cursor
/// at the pointer's fraction of the track.
fn panelScrollbar(app: *App, panel: hit_mod.PanelId, track: Rect, m: Mouse) void {
    switch (panel) {
        .todos => todos.scrollbarMouse(app, track, m),
        .notes => notes.scrollbarMouse(app, track, m),
        .findings => findings.scrollbarMouse(app, track, m),
        .debug => debug_panel.scrollbarMouse(app, track, m),
        .sessions => sessions.scrollbarMouse(app, track, m),
        .git => git_palette.scrollbarMouse(app, track, m),
        .diagnostics => lsp.scrollbarMouse(app, track, m),
        .http => http_panel.scrollbarMouse(app, track, m),
        .integrations => integrations.scrollbarMouse(app, track, m),
        .scripts => scripts_panel.scrollbarMouse(app, track, m),
        .script => {},
        .search => search_section.scrollbarMouse(app, track, m),
        .jobs => jobs_app.scrollbarMouse(app, track, m),
        .outline => {},
    }
}

/// A press or drag on a pane's scrollbar (not the editor's, which has
/// its thumb grab): the pointer's row on the track, as a fraction of
/// the content, becomes the view's position — the cursor for a list
/// that derives its window from it (Rust's `set_pane_scroll`), the
/// scroll for a text body.
fn paneBarJump(app: *App, id: PaneId, track: Rect, y: u16) Allocator.Error!void {
    if (track.h == 0) return;
    const off: usize = y -| track.y;
    const h: usize = track.h;
    if (id == HelpUi.scrollbar_owner and app.overlay == .help) {
        const st = &app.overlay.help;
        st.scroll = @min((off * st.line_count) / h, st.line_count -| st.body_rows);
        app.needs_render = true;
        return;
    }
    if (id == Picker.scrollbar_owner and app.overlay == .picker) {
        const p = &app.overlay.picker;
        const n = p.filtered.items.len;
        if (n > 0) p.state.cursor = @min((off * n) / h, n - 1);
        cmd_picker.preview(app);
        return;
    }
    if (id == SettingsUi.scrollbar_owner and app.overlay == .settings) return settings_app.barJump(app, off, h);
    const pane = app.panes.get(id) orelse return;
    switch (pane.*) {
        .outline => |*o| {
            const n = o.items.items.len;
            if (n > 0) o.cursor = @min((off * n) / h, n - 1);
        },
        .md_preview => |*mp| {
            const total = mp.total_rows;
            mp.scroll = @min((off * total) / h, total -| @max(app.pane_rows, 1));
        },
        .zon => |*z| {
            const total = z.rows.len;
            z.scroll = @min((off * total) / h, total -| @max(z.rows_h, 1));
        },
        .git_status => |*s| {
            const n = git_app.statusFlatLen(app);
            if (n == 0) return;
            const target: isize = @intCast(@min((off * n) / h, n - 1));
            git_app.moveStatusCursor(s, n, target - @as(isize, @intCast(s.cursor)));
        },
        .grep => |*g| {
            const n = g.rows.items.len;
            if (n == 0) return;
            const target: i64 = @intCast(@min((off * n) / h, n - 1));
            grep.scrollBy(g, target - @as(i64, @intCast(g.cursor)));
        },
        else => {},
    }
    focusOnPress(app, id);
    app.needs_render = true;
}

/// A drag that started on a bar keeps steering it: the pointer's row
/// against the bar's track (wherever the pointer is now).
fn barDrag(app: *App, owner: hit_mod.Owner, m: Mouse) Allocator.Error!void {
    if (m.kind != .drag) return;
    const track = scrollbarTrackOf(app, owner) orelse return;
    switch (owner) {
        .panel => |p| panelScrollbar(app, p, track, m),
        .tree => app.tree.scrollbarMouse(app, track, m),
        .welcome => |l| welcome_app.scrollbarMouse(app, l, track, m),
        .pane => |id| try paneBarJump(app, id, track, m.y),
    }
}

/// The wheel over an open menu's rows: `count` rows (a row per event);
/// the paint clamps the window to the list and pulls the cursor along.
fn menuWheel(app: *App, menu_id: u32, down: bool, count: u16) void {
    const menu = &app.overlay.menu;
    const n: usize = @max(count, 1);
    switch (menu_id) {
        1, 3 => if (menu.sub) |*sub| {
            sub.scroll = if (down) sub.scroll + n else sub.scroll -| n;
            sub.follow = .window;
        },
        else => {
            menu.scroll = if (down) menu.scroll + n else menu.scroll -| n;
            menu.follow = .window;
        },
    }
    app.needs_render = true;
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
    // // changed (bottom-dock): the dock's divider resizes it by rows.
    if (id == render.bottom_divider_id) {
        app.drag = .bottom_divider;
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
    focusOnPress(app, id);
    try dragScrollbar(app, id, grab, y);
}

/// The thumb follows the pointer. Under `wheel_moves_cursor` the
/// cursor goes to the row the thumb names (as the wheel would move
/// it); otherwise the view moves and pins, the cursor stays.
fn dragScrollbar(app: *App, id: PaneId, grab: u16, y: u16) Allocator.Error!void {
    const e = app.panes.editor(id) orelse return;
    const track = scrollbarTrackOf(app, .{ .pane = id }) orelse return;
    const total = e.buf.editor.lineCount();
    const viewport = @max(app.pane_rows, 1);
    if (total <= viewport) return;
    const th = scrollbar.thumb(track.h, total, viewport, e.view.scroll_line) orelse return;
    const max_start = track.h - th.len;
    const start: u16 = @min((y -| track.y) -| grab, max_start);
    const max_scroll = total - viewport;
    const line: usize = if (max_start == 0) 0 else (@as(usize, start) * max_scroll) / max_start;
    if (app.cursorFollowsWheel()) {
        e.view.pin = null;
        _ = try app.applyOps(e, &.{.{ .move_to_line = @intCast(line + 1) }});
        return;
    }
    e.view.scroll_line = @intCast(line);
    e.view.pinAt(e.buf.editor.cursor);
}

/// The wheel over the tree steps its cursor one row per NOTCH: with
/// acceleration off, a batch inside the 60 ms window of the last step
/// is the same notch (ghostty reports a detent as three events) and
/// moves nothing more; with it on, the rows come from the factor the
/// batch earned (`scroll.Accel.treeRows`).
fn treeWheel(app: *App, m: Mouse, count: u16) void {
    if (m.kind != .scroll_up and m.kind != .scroll_down) return;
    if (wheelLines(app, count) == 0) return;
    const rows: usize = app.accel.treeRows(app.cfg.editor.scroll_accel, app.now_ms);
    if (rows == 0) return;
    switch (m.kind) {
        .scroll_up => app.tree.cursor -|= rows,
        .scroll_down => app.tree.cursor = @min(app.tree.cursor + rows, app.tree.rows.items.len -| 1),
        else => {},
    }
    app.needs_render = true;
}

/// The vertical track the last frame painted for `owner`.
fn scrollbarTrackOf(app: *App, owner: hit_mod.Owner) ?Rect {
    for (app.hits.items.items) |h| switch (h.target) {
        .scrollbar => |sb| if (sb.axis == .v and std.meta.eql(sb.owner, owner)) return h.rect,
        else => {},
    };
    return null;
}

/// A drag or a release while a gesture is in flight.
/// The targets that fire on release (`App.Drag.button`): a tab's close
/// badge and the `.button` family — the strip's chips, the tool buttons,
/// a toast's controls. Not the menu bar's titles: a menu opens on the
/// press so the pointer can drag down onto an item and release there.
/// Not the `:` bar either: it is a text field, focused on the press.
pub fn firesOnRelease(t: hit_mod.HitTarget) ?app_mod.PressedButton {
    return switch (t) {
        .tab_close => |tb| .{ .tab_close = tb },
        .button => |id| if (menu_bar.buttonOf(id) != null or id == menu_bar.overflow_button or id == @intFromEnum(render.Button.cmdline_bar)) null else .{ .button = id },
        else => null,
    };
}

/// A release over an armed button: the press it stood for, when the
/// pointer is still on that button; nothing otherwise. A close badge
/// the pointer left while held becomes its tab's drag instead.
fn releaseButton(app: *App, b: @FieldType(app_mod.Drag, "button"), m: Mouse) Allocator.Error!void {
    if (m.kind == .drag) {
        if (b.target == .tab_close) {
            if (!b.rect.contains(m.x, m.y)) if (try tabPaneOf(app, b.target.tab_close)) |pane| {
                app.drag = .{ .tab = .{ .pane = pane, .x = b.x, .y = b.y } };
                return continueDrag(app, m);
            };
        }
        return;
    }
    if (m.kind != .release) return;
    app.drag = null;
    // Inside the rect it had when pressed: a surface the press revealed
    // over it (a hover zone's bar) does not take the click away.
    if (!b.rect.contains(m.x, m.y)) return;
    app.firing_button = b.target;
    defer app.firing_button = null;
    return mouse(app, .{ .x = m.x, .y = m.y, .kind = .press, .button = .left, .mods = m.mods }, 1);
}

/// The pane a tab close badge belongs to, when it is a layout tab.
fn tabPaneOf(app: *App, tb: hit_mod.TabRef) Allocator.Error!?PaneId {
    if (tb.leaf == bottom.strip_leaf) return null;
    const layout = app.layouts.current();
    const lid = (try layout.leafAt(app.frame.allocator(), tb.leaf)) orelse return null;
    const leaf = layout.leaf(lid) orelse return null;
    if (tb.idx >= leaf.tabs.items.len) return null;
    return leaf.tabs.items[tb.idx];
}

fn continueDrag(app: *App, m: Mouse) Allocator.Error!void {
    const d = &(app.drag orelse return);
    switch (d.*) {
        .button => |b| return releaseButton(app, b, m),
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
            app.side.right_width = std.math.clamp(app.screen.width -| (m.x + 1), 8, app.screen.width -| 22);
        },
        // // changed (bottom-dock): the pointer's row is the divider's,
        // so the dock keeps every row under it. `frameRects` clamps the
        // height to two thirds of the frame, so a drag past that stops.
        .bottom_divider => if (m.kind == .drag) bottom.dragTo(app, m.y),
        .graph_divider => |id| if (m.kind == .drag) git_app.dragGraphDivider(app, id, m.x),
        .diff_select => |ds| git_app.dragDiffSelect(app, ds.pane, ds.anchor, m),
        .pty_select => |id| if (app.panes.pty(id)) |p| {
            if (m.kind == .release) try pty_pane.selectRelease(app, p, m.x, m.y) else try pty_pane.selectDrag(app, p, m.x, m.y);
        },
        .select => |sel| {
            extendSelection(app, sel, m.x, m.y);
            // A press-and-release on one cell is a click: no selection.
            if (m.kind == .release) if (app.panes.editor(sel.pane)) |e| {
                if (e.buf.editor.anchor != null and e.buf.editor.anchor.? == e.buf.editor.cursor) e.buf.editor.anchor = null;
            };
        },
        .scrollbar => |sb| try dragScrollbar(app, sb.pane, sb.grab, m.y),
        .bar => |owner| try barDrag(app, owner, m),
        .dock => |*dd| return dock.continueDrag(app, dd, m),
        .tab => |*tb| {
            if (m.kind == .drag) {
                if (tb.x != m.x or tb.y != m.y) tb.moved = true;
                return;
            }
            const pane = tb.pane;
            const moved = tb.moved;
            app.drag = null;
            if (moved) {
                // Dragging a tab somewhere is commitment: the preview
                // becomes a tab of its own before it moves or splits.
                if (app.panes.get(pane)) |p| p.setPreview(false);
                try dropTab(app, pane, m.x, m.y);
            }
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
            const clicks = tr.clicks;
            app.drag = null;
            if (!moved) return if (clicks >= 2) app.tree.activate(app, idx) else app.tree.activateGlance(app, idx);
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

/// The editor text under the pointer (`.editor_cell`): the wheel, a
/// click that places the cursor (or opens the editor menu), a drag
/// that selects. The gutter routes here too once its own presses
/// (a breakpoint toggle, the breakpoint menu) are taken.
fn editorCellMouse(app: *App, cell: CellHit, m: Mouse, count: u16, wheel: bool) Allocator.Error!void {
    if (wheel) return wheelOnPane(app, cell.pane, m, count);
    if (m.kind != .press) return;
    // The outline and the preview reuse the cell hit: a row is a
    // jump, a row is a scroll target.
    if (app.panes.get(cell.pane)) |p| switch (p.*) {
        .outline => {
            if (m.button == .left) {
                if (app.overlay != .none) closeOverlay(app);
                try outline.clickRow(app, cell.pane, cell.line, cell.col);
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
    focusOnPress(app, cell.pane);
    const e = app.panes.editor(cell.pane) orelse return;
    const ed = e.buf.editor;
    const line = @min(cell.line, ed.lineCount() - 1);
    const byte = cellByte(ed, line, cell.col);
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
}

fn hitRect(app: *App, x: u16, y: u16) ?Rect {
    return if (app.hits.entryAt(x, y)) |e| e.rect else null;
}

/// Enter on a list pane row: the cmdline history re-runs the line, the
/// quickfix and location lists open the file at the row.
pub fn listPaneEnter(app: *App, pane: PaneId, l: *app_mod.ListPane) Allocator.Error!void {
    const e = ((try l.entryAt(app.frame.allocator(), l.cursor)) orelse return).*;
    switch (l.kind) {
        // // changed (git-more2): the git list kinds act through the git state.
        .stash_files => git_app.runToast(app, git_app.stashFileEnter(app, e)),
        .git_log => git_app.runToast(app, git_app.logEnter(app, e)),
        .cmdline_history => {
            const line = try app.frame.allocator().dupe(u8, e.text);
            try app.forceClosePane(pane);
            try runExLine(app, line);
        },
        .quickfix, .location => {
            // changed: the location list shares the quickfix row action; the
            // owning editor's index follows the row so `:lnext` continues from it.
            if (l.kind == .location) @import("loclist.zig").noteEnter(app, l.cursor);
            if (l.kind == .quickfix) @import("quickfix.zig").noteEnter(app, l.cursor);
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
        .dot_repeat, .macro_record_into, .operator_to_mark => {},
        .macro_replay_from => |m| try macro_replay.run(app, pane_id, m.reg, m.count, m.recorded),
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
        .repeat_insert_start => |r| try beginRepeatInsert(app, pane_id, e, r.count, r.kind),
        .operator_linewise_to => |o| try linewiseOp(app, e, o.op, o.target, o.register),
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
        // `gs{motion}`: the ops select the range the way a built-in
        // operator's motion does, the script is handed it, and the
        // selection goes — the shape `gU{motion}` has.
        .script_operator => |so| {
            _ = try app.applyOps(e, so.ops);
            const sel = e.buf.editor.selection() orelse return;
            // The handler says whether the range is whole lines: it has
            // already left Visual by the time this runs, so the editing
            // mode no longer carries the shape.
            const api_mod = @import("../scripting/api.zig");
            const mode: []const u8 = if (so.linewise) "line" else api_mod.selectionMode(e);
            const lua = app.luaState(so.state) orelse return;
            try api_mod.runOperatorMode(app, lua, so.index, e, sel[0], sel[1], mode);
            if (app.panes.editor(pane_id)) |live| _ = try app.applyOps(live, &.{.select_clear});
        },
    }
}

/// Whether `k` is the chord bound to `app.command_line` in the active
/// profile. Read through the keymap rather than hard-coded, so a
/// `[keys.*]` rebinding of the command moves the global with it.
fn opensCommandLine(app: *const App, k: Key) bool {
    return switch (app.keymap.resolveSeq(&.{Chord.of(k)})) {
        .run => |target| target == .static and target.static == .@"app.command_line",
        else => false,
    };
}

/// Run an ex line; a failure toasts the reason (or the error name).
/// The ex line for a pane that has no `:` of its own (a request pane's
/// `:` while browsing): a prompt whose Enter runs the line.
pub fn openExLine(app: *App) Allocator.Error!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = Prompt.init(app.gpa, "Ex command"), .purpose = .ex_line } };
    app.focus = .overlay;
    app.needs_render = true;
}

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

fn blockRect(e: *const EditorPane) ?block.Rect {
    const ed = e.buf.editor;
    const anchor = ed.block_anchor orelse e.block_anchor orelse return null;
    return block.rectFrom(ed, anchor);
}

/// Where a block `I` (`append` false: at display column `col`) or `A`
/// (`col` is the column after the block) types on `row`, padding the
/// row with spaces first when it has to be reached: an `A` past a short
/// row's end pads out to the column (`:help v_b_A`), and a wide glyph
/// the column cuts through gets the typed text after spaces, before it.
/// Null: an `I` on a row that ends before the column is not touched
/// (`:help v_b_I`). A ragged `$A` types at each row's end.
fn blockInsertAt(ed: *Editor, row: usize, col: usize, append: bool, ragged: bool) Allocator.Error!?usize {
    const end = ed.lineEnd(row);
    if (ragged) return end;
    const width = ed.doc.lineVcols(row);
    if (width < col) {
        if (!append) return null;
        var pad: [256]u8 = @splat(' ');
        const n = @min(col - width, pad.len);
        try ed.splice(end, end, pad[0..n]);
        return end + n;
    }
    const at = ed.byteAtVcol(row, col);
    const start = ed.vcolAtByte(at);
    if (at < end and start < col) {
        var pad: [8]u8 = @splat(' ');
        const n = @min(col - start, pad.len);
        try ed.splice(at, at, pad[0..n]);
        return at + n;
    }
    return at;
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
    try ed.checkpoint();
    if (change) {
        try block.cutRows(ed, rect, eol);
        col = rect.c0;
        e.syntax.dirty = true;
    }
    // `$A`: append at every row's own end.
    const ragged = eol and append and !change;
    const as_append = append and !change;
    const start = try blockInsertAt(ed, rect.r0, col, as_append, ragged) orelse ed.lineEnd(rect.r0);
    ed.setCursor(start);
    ed.anchor = null;
    // The cut, the padding and what is typed undo as one change.
    ed.in_insert_run = true;
    ed.doc.insert_run_owner = ed;
    e.buf.input.requestInsertMode();
    app.block_insert = .{ .pane = pane_id, .first_row = rect.r0, .last_row = rect.r1, .col = col, .start_byte = start, .len_before = ed.len(), .eol = ragged, .append = as_append, .left_col = rect.c0 };
}

/// `r<ch>` on a visual block: every character in the rectangle becomes
/// `ch`.
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
        if (row >= ed.lineCount()) continue;
        const sp = block.span(ed, row, rect.c0, rect.c1, eol);
        // Right to left, so the earlier offsets stay put.
        var chars: std.ArrayList(usize) = .empty;
        var b = sp.inner_s;
        while (b < sp.inner_e) : (b = ed.nextBoundary(b)) try chars.append(app.frame.allocator(), b);
        var i = chars.items.len;
        while (i > 0) {
            i -= 1;
            const s = chars.items[i];
            try ed.splice(s, ed.nextBoundary(s), glyph[0..n]);
        }
    }
    ed.setCursor(ed.byteAtVcol(rect.r0, rect.c0));
    e.buf.doc.recomputeDirty();
    e.syntax.dirty = true;
}

/// `<count>i` / `I` / `a` / `A` / `o` / `O`: enter Insert where the
/// command says, then replicate what was typed on Esc (`:help count`).
fn beginRepeatInsert(app: *App, pane_id: PaneId, e: *EditorPane, count: u32, kind: input.RepeatInsertKind) Allocator.Error!void {
    e.buf.input.requestInsertMode();
    const opening: ?EditOp = switch (kind) {
        .open_below => .insert_newline_below,
        .open_above => .insert_newline_above,
        .line_first_non_ws => .move_line_first_non_ws,
        .after_cursor => .move_right,
        .line_end => .move_line_end,
        .at_cursor => null,
    };
    if (opening) |op| {
        _ = try app.applyOps(e, &.{op});
        // `App.applyOps` does not record for `.`; this op is the head of
        // the change (`A` appends, it does not insert at the cursor).
        try e.buf.trackAppOps(&.{op}, app.frame.allocator());
    }
    const ed = e.buf.editor;
    app.repeat_insert = .{ .pane = pane_id, .count = count, .kind = kind, .start_byte = ed.cursor, .len_before = ed.len() };
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
            const at = try blockInsertAt(ed, row, b.col, b.append, b.eol) orelse continue;
            try ed.splice(at, at, typed);
        }
        // The cursor ends on the block's top-left, and wants that column
        // from here on (Neovim 0.12.5: `l<C-v>2jlA;<Esc>` → 1:2, and
        // `gg` / `j` after it stay in column 2).
        ed.setCursor(ed.byteAtVcol(b.first_row, b.left_col));
        ed.goal_col = null;
        e.buf.doc.recomputeDirty();
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
        if (r.kind.opensLine()) {
            var i: u32 = 1;
            while (i < r.count) : (i += 1) {
                if (r.kind == .open_above) {
                    const at = ed.lineStart(line);
                    const with_nl = try std.mem.concat(app.frame.allocator(), u8, &.{ typed, "\n" });
                    try ed.splice(at, at, with_nl);
                } else {
                    const at = ed.lineEnd(line + i - 1);
                    const with_nl = try std.mem.concat(app.frame.allocator(), u8, &.{ "\n", typed });
                    try ed.splice(at, at, with_nl);
                }
            }
        } else if (typed_len > 0) {
            // `3iab<Esc>` = the run again at the insertion point, newlines
            // and all; Esc had already stepped one left, so step back from
            // the end of the LAST copy instead.
            const at = r.start_byte + typed_len;
            var i: u32 = 1;
            while (i < r.count) : (i += 1) try ed.splice(at, at, typed);
            ed.setCursor(at + (r.count - 1) * typed_len);
            _ = try app.applyOps(e, &.{.move_left_no_cross_line});
        }
        // `.` repeats a counted insert with its count (`:help .`): the
        // deferred copies join the change the Esc just recorded.
        if (r.count > 1 and typed_len > 0) {
            const tail = if (r.kind.opensLine()) try std.mem.concat(app.frame.allocator(), u8, &.{ "\n", typed }) else typed;
            try e.buf.appendDotInsertRepeat(r.count - 1, tail);
        }
        e.buf.doc.recomputeDirty();
        e.syntax.dirty = true;
        app.needs_render = true;
    }
}

// ── linewise operators to a line target ──

/// `dG` / `dgg` / `<n>dG` / `yG`…: `target` null = last line, 0 = first,
/// n = 1-based line. Whole lines, inclusive, into the unnamed register.
fn linewiseOp(app: *App, e: *EditorPane, op: u8, target: ?u32, register: ?u21) Allocator.Error!void {
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
    // The register a `"x` named goes with the write it routes.
    if (register) |r| app.clipboard.setPendingRegister(r);
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
            e.buf.doc.recomputeDirty();
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
    // The platform's shell: `sh -c`, or `%COMSPEC% /d /c` on Windows.
    var shell_buf: [4][]const u8 = undefined;
    var child = std.process.spawn(app.io, .{ .argv = @import("pty").shellArgv(&shell_buf, &app.env, cmd), .stdin = .pipe, .stdout = .pipe, .stderr = .pipe }) catch |err| {
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

const ex_names = [_][]const u8{ "write", "wq", "quit", "edit", "bdelete", "bnext", "bprev", "sort", "retab", "substitute", "delete", "yank", "set", "registers", "marks", "abbreviate", "unabbreviate", "noh", "tabclose", "tabnew", "tabnext", "tabprev", "tabfirst", "tablast", "global", "vglobal", "normal", "command", "delcommand", "read", "dock", "sidebar" };
const path_commands = [_][]const u8{ "e", "edit", "w", "write", "sp", "split", "vs", "vsplit", "tabe", "tabedit", "r", "read", "cd", "saveas" };

/// Tab on the `:` line: the ring for the text so far (built by the
/// popup as the text was typed, or here if it was not), then the next
/// candidate written into the line — the first press writes the
/// selection itself, later presses cycle (`cmdline_popup.cycle`).
fn cmdlineTabComplete(app: *App, e: *EditorPane) Allocator.Error!void {
    const line = e.buf.input.cmdlineGet() orelse return;
    try cmdline_popup.refresh(app);
    if (app.cmd_complete) |*c| {
        // The one match was a directory and the line is it now: the next
        // Tab lists what is inside (vim's `wildmode=full` on `:e src/`),
        // rather than cycling a list of one.
        const descend = c.candidates.len == 1 and std.mem.eql(u8, c.candidates[0], line) and std.mem.endsWith(u8, line, "/");
        if (descend) {
            dropComplete(app);
            try cmdline_popup.refresh(app);
        }
    }
    try cmdline_popup.cycle(app, 1);
}

/// The candidates for `line` on the `:` line, owned by `gpa` (the slice
/// and each string; empty when nothing matches). `<cmd> <partial>`
/// completes what the command takes — `:set` its options, a path
/// command the workspace's entries — spelled as whole lines
/// (`e apple.md`); a lone token completes registry ids (prefix 300 /
/// contains 200), the ex names (150) and the user's own `:command`s
/// (400), ties alphabetical.
pub fn cmdlineCandidates(app: *App, gpa: Allocator, line: []const u8) Allocator.Error![][]u8 {
    var cands: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (cands.items) |c| gpa.free(c);
        cands.deinit(gpa);
    }
    if (std.mem.indexOfScalar(u8, line, ' ')) |sp| {
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
            return cands.toOwnedSlice(gpa);
        }
        var is_path_cmd = false;
        for (path_commands) |p| if (std.mem.eql(u8, p, head)) {
            is_path_cmd = true;
        };
        if (!is_path_cmd) return cands.toOwnedSlice(gpa);
        var paths: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (paths.items) |c| gpa.free(c);
            paths.deinit(gpa);
        }
        try pathCandidates(app, gpa, partial, false, &paths);
        for (paths.items) |rel| try cands.append(gpa, try std.mem.concat(gpa, u8, &.{ head, " ", rel }));
        return cands.toOwnedSlice(gpa);
    }
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
    for (scored.items) |sc| try cands.append(gpa, try gpa.dupe(u8, sc.name));
    return cands.toOwnedSlice(gpa);
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
    _ = e;
    try cmdline_popup.cycle(app, delta);
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

test "the one deep-link shape: `--focus <key>` names a thing inside a listing, anything else is just argv" {
    // What a hover row publishes.
    try std.testing.expectEqualStrings("api#1198", focusKeyOf(&.{ "--focus", "api#1198" }).?);
    try std.testing.expectEqualStrings("ENG-2", focusKeyOf(&.{ "--focus", "ENG-2" }).?);
    // Not a deep link: a different listing (its own pane), a flag with
    // nothing after it, an empty key, or the pair with anything else
    // around it — the host does not guess at a shape it was not given.
    try std.testing.expect(focusKeyOf(&.{ "--only", "prs-mine" }) == null);
    try std.testing.expect(focusKeyOf(&.{"--focus"}) == null);
    try std.testing.expect(focusKeyOf(&.{ "--focus", "" }) == null);
    try std.testing.expect(focusKeyOf(&.{ "--focus", "ENG-2", "--only", "work" }) == null);
    try std.testing.expect(focusKeyOf(&.{}) == null);
}

test "chord chain: ctrl+k alone is pending with a which-key fallback; in the standard profile expiring keeps the chord and lists its keys, in vim the leader fallback opens the tree" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 40, .rows = 10 });
    defer app.deinit();
    try std.testing.expect(app.input_style != .vim);
    try key(&app, Key.ctrl('k'));
    try std.testing.expect(app.chord.len == 1 and app.chord.fallback != null);
    try expireChords(&app);
    // Standard: no leader tree; the chain waits, with no deadline, for
    // the chord's next key — and the popup of its continuations is up.
    try std.testing.expect(app.overlay == .none);
    try std.testing.expect(app.chord.len == 1 and app.chord.menu and app.chord.deadline_ms == null);
    const kids = try app.keymap.continuations(app.frame.allocator(), app.chord.seq[0..1]);
    try std.testing.expect(kids.len >= 10);
    // `t` completes `ctrl+k t` (theme.toggle) as it would have at speed.
    const before = app.theme.name;
    try key(&app, Key.char('t'));
    try std.testing.expect(app.chord.len == 0 and !app.chord.menu);
    try std.testing.expect(!std.mem.eql(u8, app.theme.name, before));
    // Esc cancels a waiting chord and types nothing.
    try key(&app, Key.ctrl('k'));
    try expireChords(&app);
    try key(&app, Key.named(.esc));
    try std.testing.expect(app.chord.len == 0 and !app.chord.menu and app.overlay == .none);
}

test "leader chain: the second key of `space e` is the chord's, not the editor's; esc cancels a pending leader silently" {
    // A workspace of its own with a file in it: `space f f` only opens the
    // picker when the scan finds something, and the ambient `/tmp` this
    // once used is full on a developer's Mac and empty in a container.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "one\n" });
    var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = ws_buf[0..try tmp.dir.realPath(std.testing.io, &ws_buf)];
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = ws, .cols = 60, .rows = 12 });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    const e = app.activeEditor().?;
    try e.buf.editor.setText("const std = @import(\"std\");\n");
    e.buf.editor.setCursor(0);
    try key(&app, Key.char(' '));
    try std.testing.expect(app.chord.len == 1);
    try key(&app, Key.char('e'));
    try std.testing.expect(app.tree.visible and app.focus == .tree);
    try std.testing.expect(app.chord.len == 0);
    try std.testing.expect(app.overlay == .none);
    // `e` did not run as a motion.
    try std.testing.expectEqual(@as(usize, 0), e.buf.editor.cursor);
    app.focus = .{ .pane = app.active.? };
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

test "leader chain: an unbound chord is swallowed whole — its tail key never reaches the vim handler, typed fast or through the popup" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try command.run(&app, .{ .static = .@"tab.new" });
    try command.run(&app, .{ .static = .@"tab.prev" });
    const e = app.activeEditor().?;
    try e.buf.editor.setText("alpha\nbravo\n");
    e.buf.editor.setCursor(0);
    const Case = struct { a: u21, b: u21 };
    // `<leader>cx` is not `x` (delete a char), `<leader>fx` / `<leader>bx`
    // neither: NvChad's which-key drops an unbound chord whole. (The
    // hunt's `ca` / `fo` / `gt` are bound now — `keymap.zig`.)
    for ([_]Case{ .{ .a = 'c', .b = 'x' }, .{ .a = 'f', .b = 'x' }, .{ .a = 'b', .b = 'x' } }) |c| {
        try key(&app, Key.char(' '));
        try key(&app, Key.char(c.a));
        try key(&app, Key.char(c.b));
        try std.testing.expectEqual(input.EditingMode.normal, e.buf.input.mode());
        try std.testing.expectEqualStrings("alpha\nbravo\n", e.buf.editor.bytes());
        try std.testing.expectEqual(@as(usize, 0), e.buf.editor.cursor);
        try std.testing.expectEqual(@as(usize, 0), app.layouts.active);
        try std.testing.expect(app.chord.len == 0 and app.overlay == .none);
    }
    // Slowly: the leader expires into the popup, `c` descends, `a` is
    // nothing there — the popup closes and the key is gone.
    try key(&app, Key.char(' '));
    try expireChords(&app);
    try std.testing.expect(app.overlay == .which_key);
    try key(&app, Key.char('c'));
    try std.testing.expect(app.overlay == .which_key);
    try key(&app, Key.char('x'));
    try std.testing.expect(app.overlay == .none);
    try std.testing.expectEqualStrings("alpha\nbravo\n", e.buf.editor.bytes());
    try std.testing.expectEqual(input.EditingMode.normal, e.buf.input.mode());
    try std.testing.expectEqual(@as(usize, 0), e.buf.editor.cursor);
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

/// The screen cell whose hit names byte `off` of `line` — where that
/// grapheme was painted (its first cell), or null when it is not on screen.
fn cellOf(app: *App, line: u32, off: u32) ?struct { x: u16, y: u16 } {
    var y: u16 = 0;
    while (y < 40) : (y += 1) {
        var x: u16 = 0;
        while (x < 200) : (x += 1) {
            const t = app.hits.at(x, y) orelse continue;
            if (t == .editor_cell and t.editor_cell.line == line and t.editor_cell.col == off) return .{ .x = x, .y = y };
        }
    }
    return null;
}

test "a click lands on the glyph under the pointer: bytes not chars, both cells of a wide glyph, the EOL space" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const ed = app.activeEditor().?.buf.editor;
    // `ö` is char 8 / byte 10 (Ü and ï take two bytes); `t` after the
    // four CJK glyphs is char 5 / byte 13 (three bytes, two cells each);
    // `p` after the emoji is char 8 / byte 11 (four bytes, two cells).
    try ed.setText("/// Ünïcödé in a comment\n日本語の text here\nemoji 🎉 party 🎉 end\n");
    try app.render();
    const cases = [_]struct { line: u32, off: u32, col: usize }{
        .{ .line = 0, .off = 10, .col = 8 },
        .{ .line = 1, .off = 13, .col = 5 },
        .{ .line = 2, .off = 11, .col = 8 },
    };
    for (cases) |c| {
        const cell = cellOf(&app, c.line, c.off).?;
        try press(&app, cell.x, cell.y, .left);
        try release(&app, cell.x, cell.y);
        try std.testing.expectEqual(ed.lineStart(c.line) + c.off, ed.cursor);
        try std.testing.expectEqual(c.col, ed.rowCol().col);
    }
    // The second cell of a wide glyph is that glyph, not the next one.
    const hon = cellOf(&app, 1, 3).?; // 本
    try press(&app, hon.x + 1, hon.y, .left);
    try release(&app, hon.x + 1, hon.y);
    try std.testing.expectEqual(ed.lineStart(1) + 3, ed.cursor);
    try std.testing.expectEqual(@as(usize, 1), ed.rowCol().col);
    // Anywhere in the EOL space is the line's end.
    const eol_off: u32 = @intCast(ed.lineEnd(0) - ed.lineStart(0));
    const eol = cellOf(&app, 0, eol_off).?;
    try press(&app, eol.x + 6, eol.y, .left);
    try release(&app, eol.x + 6, eol.y);
    try std.testing.expectEqual(ed.lineEnd(0), ed.cursor);
    // A drag from the CJK line to `ö` selects by the same bytes.
    const oe = cellOf(&app, 0, 10).?;
    try press(&app, hon.x, hon.y, .left);
    try dragTo(&app, oe.x, oe.y);
    try release(&app, oe.x, oe.y);
    try std.testing.expectEqual([2]usize{ ed.lineStart(0) + 10, ed.lineStart(1) + 3 }, ed.selection().?);
}

/// The first cell of `line`'s gutter, or null when the line is off screen.
fn gutterOf(app: *App, line: u32) ?struct { x: u16, y: u16 } {
    var y: u16 = 0;
    while (y < 40) : (y += 1) {
        var x: u16 = 0;
        while (x < 200) : (x += 1) {
            const t = app.hits.at(x, y) orelse continue;
            if (t == .gutter and t.gutter.line == line) return .{ .x = x, .y = y };
        }
    }
    return null;
}

test "a gutter press selects the line with the cursor at column 1 and Shift extends; on a debuggable file the whole margin flips the breakpoint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "one\ntwo\nthree\nfour\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "prog.dbg", .data = "let x = 1\nlet p = 2\nprint x\nx = x + 1\n" });
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = root, .cols = 80, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    const notes_path = try std.fs.path.join(std.testing.allocator, &.{ root, "notes.txt" });
    defer std.testing.allocator.free(notes_path);
    _ = try app.openPath(notes_path);
    try app.render();
    const ed = app.activeEditor().?.buf.editor;
    // The number cells, not only the sign cell: line 1 (`two`) selected
    // whole, the cursor at its start, the buffer's mode visual.
    const g1 = gutterOf(&app, 1).?;
    try press(&app, g1.x + 2, g1.y, .left);
    try release(&app, g1.x + 2, g1.y);
    try std.testing.expectEqual(ed.lineStart(1), ed.cursor);
    try std.testing.expectEqual(@as(usize, 0), ed.rowCol().col);
    try std.testing.expectEqual([2]usize{ ed.lineStart(1), ed.lineStart(2) }, ed.selection().?);
    // Shift on line 3 extends down over lines 1–3; Shift on line 0 then
    // extends up so all four are selected.
    const g3 = gutterOf(&app, 3).?;
    try app.handle(.{ .mouse = .{ .x = g3.x + 1, .y = g3.y, .kind = .press, .button = .left, .mods = .{ .shift = true } } });
    try release(&app, g3.x + 1, g3.y);
    try std.testing.expectEqual([2]usize{ ed.lineStart(1), ed.len() }, ed.selection().?);
    const g0 = gutterOf(&app, 0).?;
    try app.handle(.{ .mouse = .{ .x = g0.x + 3, .y = g0.y, .kind = .press, .button = .left, .mods = .{ .shift = true } } });
    try release(&app, g0.x + 3, g0.y);
    try std.testing.expectEqual([2]usize{ 0, ed.len() }, ed.selection().?);
    // No adapter for `.txt`: no breakpoint, no toast.
    try std.testing.expectEqual(@as(usize, 0), app.dap.bpsFor(notes_path).len);
    try std.testing.expect(app.lastToast() == null);
    // A `.dbg` with an adapter: a press on the number cells flips the
    // breakpoint and parks the cursor at column 1 with nothing selected;
    // a second press clears it.
    var cfg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer cfg_arena.deinit();
    try app.cfg.dap.put(cfg_arena.allocator(), "dbg", .{ .cmd = "not-a-real-adapter" });
    const prog = try std.fs.path.join(std.testing.allocator, &.{ root, "prog.dbg" });
    defer std.testing.allocator.free(prog);
    _ = try app.openPath(prog);
    try app.render();
    const pd = app.activeEditor().?.buf.editor;
    const g2 = gutterOf(&app, 2).?;
    try press(&app, g2.x + 3, g2.y, .left);
    try release(&app, g2.x + 3, g2.y);
    try std.testing.expectEqual(@as(usize, 1), app.dap.bpsFor(prog).len);
    try std.testing.expectEqual(@as(u32, 2), app.dap.bpsFor(prog)[0].line);
    try std.testing.expectEqual(pd.lineStart(2), pd.cursor);
    try std.testing.expect(pd.selection() == null);
    try std.testing.expectEqualStrings("breakpoint set: line 3", app.lastToast().?);
    try press(&app, g2.x + 1, g2.y, .left);
    try release(&app, g2.x + 1, g2.y);
    try std.testing.expectEqual(@as(usize, 0), app.dap.bpsFor(prog).len);
    try std.testing.expectEqualStrings("breakpoint cleared: line 3", app.lastToast().?);
}

/// The first cell of the hover box, or null when none is painted.
fn hoverBoxAt(app: *App) ?struct { x: u16, y: u16 } {
    for (app.hits.items.items) |e| if (e.target == .hover_popup) return .{ .x = e.rect.x + 1, .y = e.rect.y + 1 };
    return null;
}

test "the wheel over the hover box scrolls its lines two an event, never the editor under it; a press puts it away" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    const id = try app.openScratch();
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (0..100) |i| try text.print(std.testing.allocator, "L{d}\n", .{i});
    try app.activeEditor().?.buf.editor.setText(text.items);
    // Thirty lines of hover, as `showPages` would build them.
    var h: lsp.Hover = .{ .pane = id, .arena = @import("../core/alloc.zig").SnapshotArena.init(app.gpa), .pages = &.{}, .active = 0, .at = 0 };
    const a = h.arena.allocator();
    const page = try a.alloc([]const u8, 30);
    for (page, 0..) |*l, i| l.* = try std.fmt.allocPrint(a, "hover line {d}", .{i});
    const pages = try a.alloc([]const []const u8, 1);
    pages[0] = page;
    h.pages = pages;
    app.lsp.hover = h;
    try app.render();
    const box = hoverBoxAt(&app).?;
    // One event: two lines. Three events in a batch: six more.
    try app.handle(.{ .mouse = .{ .x = box.x, .y = box.y, .kind = .scroll_down } });
    try app.tick(app.now_ms);
    try std.testing.expectEqual(@as(usize, 2), app.lsp.hover.?.scroll);
    for (0..3) |_| try app.handle(.{ .mouse = .{ .x = box.x, .y = box.y, .kind = .scroll_down } });
    try app.tick(app.now_ms);
    try std.testing.expectEqual(@as(usize, 8), app.lsp.hover.?.scroll);
    try app.handle(.{ .mouse = .{ .x = box.x, .y = box.y, .kind = .scroll_up } });
    try app.tick(app.now_ms);
    try std.testing.expectEqual(@as(usize, 6), app.lsp.hover.?.scroll);
    // The editor under the box did not move.
    try std.testing.expectEqual(@as(u32, 0), app.activeEditor().?.view.scroll_line);
    // The draw clamps a scroll past the last page of lines.
    app.lsp.hover.?.scroll = 99;
    try app.render();
    try std.testing.expect(app.lsp.hover.?.scroll < 30);
    try press(&app, box.x, box.y, .left);
    try release(&app, box.x, box.y);
    try std.testing.expect(app.lsp.hover == null);
}

test "a picker click opens the row under the pointer — at index 0 and after the cursor moved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    for ([_][]const u8{ "alpha.txt", "bravo.txt", "charlie.txt", "delta.txt" }) |name| try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "x\n" });
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = root, .cols = 120, .rows = 40 });
    defer app.deinit();
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"picker.files" });
    try app.render();
    try std.testing.expect(app.overlay == .picker);
    // Index 0 with the cursor there.
    var row: ?Rect = null;
    for (app.hits.items.items) |e| if (e.target == .overlay_item and e.target.overlay_item == 0) {
        row = e.rect;
    };
    const first = try app.frame.allocator().dupe(u8, app.overlay.picker.labels[app.overlay.picker.filtered.items[0]]);
    try press(&app, row.?.x + 3, row.?.y, .left);
    try release(&app, row.?.x + 3, row.?.y);
    try std.testing.expect(app.overlay == .none);
    try std.testing.expect(std.mem.endsWith(u8, app.panes.get(app.active.?).?.editor.buf.doc.path.?, first));
    // After Down (and the preview it drives), the third row is still the third.
    try command.run(&app, .{ .static = .@"picker.files" });
    try app.handle(.{ .key = Key.named(.down) });
    try app.render();
    row = null;
    for (app.hits.items.items) |e| if (e.target == .overlay_item and e.target.overlay_item == 2) {
        row = e.rect;
    };
    const third = try app.frame.allocator().dupe(u8, app.overlay.picker.labels[app.overlay.picker.filtered.items[2]]);
    try std.testing.expect(!std.mem.eql(u8, first, third));
    try press(&app, row.?.x + 3, row.?.y, .left);
    try release(&app, row.?.x + 3, row.?.y);
    try std.testing.expect(app.overlay == .none);
    try std.testing.expect(std.mem.endsWith(u8, app.panes.get(app.active.?).?.editor.buf.doc.path.?, third));
}

test "a click on a soft-wrapped continuation row lands on that row's chars, on the first screen and scrolled" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    app.activeEditor().?.wrap = true;
    const ed = app.activeEditor().?.buf.editor;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (0..40) |i| {
        try text.print(std.testing.allocator, "line{d:0>3}", .{i + 1});
        // Lines 3 and 30 wrap: a space, then 20 `wrapme_` with no break in them.
        if (i == 2 or i == 29) {
            try text.appendSlice(std.testing.allocator, " ");
            for (0..20) |_| try text.appendSlice(std.testing.allocator, "wrapme_");
        }
        try text.appendSlice(std.testing.allocator, "\n");
    }
    try ed.setText(text.items);
    try app.render();
    // Line 3's number row holds `line003 ` (bytes 0–7); the row under it
    // starts at byte 8, the one under that a text width later.
    const num = cellOf(&app, 2, 0).?;
    const row1 = app.hits.at(num.x, num.y + 1).?.editor_cell;
    try std.testing.expectEqual(@as(u32, 2), row1.line);
    try std.testing.expectEqual(@as(u32, 8), row1.col);
    try press(&app, num.x + 4, num.y + 1, .left);
    try release(&app, num.x + 4, num.y + 1);
    try std.testing.expectEqual(ed.lineStart(2) + 12, ed.cursor);
    const row2 = app.hits.at(num.x, num.y + 2).?.editor_cell;
    try std.testing.expectEqual(@as(u32, 2), row2.line);
    const width = row2.col - 8;
    try std.testing.expect(width > 20);
    try press(&app, num.x + 4, num.y + 2, .left);
    try release(&app, num.x + 4, num.y + 2);
    try std.testing.expectEqual(ed.lineStart(2) + 8 + width + 4, ed.cursor);
    // Past the text of a wrapped row: that row's end, not the next row's chars.
    try press(&app, num.x + 30, num.y, .left);
    try release(&app, num.x + 30, num.y);
    try std.testing.expectEqual(ed.lineStart(2) + 8, ed.cursor);
    // Scrolled so line 30 sits above the cursor's line 32: the same shape.
    ed.placeCursor(31, 0);
    try app.render();
    try std.testing.expect(app.activeEditor().?.view.scroll_line > 10);
    const num30 = cellOf(&app, 29, 0).?;
    const r30 = app.hits.at(num30.x, num30.y + 2).?.editor_cell;
    try std.testing.expectEqual(@as(u32, 29), r30.line);
    try std.testing.expectEqual(@as(u32, 8 + width), r30.col);
    try press(&app, num30.x + 4, num30.y + 2, .left);
    try release(&app, num30.x + 4, num30.y + 2);
    try std.testing.expectEqual(ed.lineStart(29) + 8 + width + 4, ed.cursor);
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
    // (400 ms on: a fresh gesture, one notch, `wheel_lines` lines.)
    app.now_ms += 400;
    try app.handle(.{ .mouse = .{ .x = 10, .y = 5, .kind = .scroll_down } });
    try press(&app, 10, 3, .left);
    try std.testing.expect(app.wheel.pending == null);
    try std.testing.expectEqual(@as(u32, 4), app.activeEditor().?.view.scroll_line);
    // vim: the cursor follows (`wheel_moves_cursor = auto`).
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try app.render();
    app.now_ms += 400;
    try app.handle(.{ .mouse = .{ .x = 10, .y = 5, .kind = .scroll_down } });
    try app.tick(app.now_ms);
    try std.testing.expectEqual(@as(usize, 8), app.activeEditor().?.buf.editor.currentLine());
    // A turn the other way flushes the batch in front of it and is not
    // dispatched raw: it starts the next batch, flushed at the tick.
    app.now_ms += 400;
    try app.handle(.{ .mouse = .{ .x = 10, .y = 5, .kind = .scroll_down } });
    try app.handle(.{ .mouse = .{ .x = 10, .y = 5, .kind = .scroll_up } });
    try std.testing.expectEqual(@as(usize, 11), app.activeEditor().?.buf.editor.currentLine());
    try std.testing.expect(app.wheel.pending.?.mouse.kind == .scroll_up);
    app.now_ms += 400;
    try app.tick(app.now_ms);
    try std.testing.expectEqual(@as(usize, 8), app.activeEditor().?.buf.editor.currentLine());
}

test "wheel: the batch is budgeted through scroll_accel — a fast second notch travels further under normal, 1:1 under off" {
    for ([_]app_mod.Config.ScrollAccel{ .normal, .off }, [_]u32{ 6, 3 }) |setting, second| {
        var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 12 });
        defer app.deinit();
        app.tree.visible = false;
        app.cfg.editor.scroll_accel = setting;
        _ = try app.openScratch();
        var text: std.ArrayListUnmanaged(u8) = .empty;
        defer text.deinit(std.testing.allocator);
        for (0..100) |i| try text.print(std.testing.allocator, "L{d}\n", .{i});
        try app.activeEditor().?.buf.editor.setText(text.items);
        try app.render();
        // The first notch of a gesture is 1:1 at every setting.
        app.now_ms += 1000;
        try app.handle(.{ .mouse = .{ .x = 10, .y = 5, .kind = .scroll_down } });
        try app.tick(app.now_ms);
        try std.testing.expectEqual(@as(u32, 3), app.activeEditor().?.view.scroll_line);
        // 8 ms on (≈125 events/s): normal's factor is 2.5 — two lines
        // (the half carries), times the editor gain of three.
        app.now_ms += 8;
        try app.handle(.{ .mouse = .{ .x = 10, .y = 5, .kind = .scroll_down } });
        try app.tick(app.now_ms);
        try std.testing.expectEqual(3 + second, app.activeEditor().?.view.scroll_line);
    }
}

test "wheel_moves_cursor: always moves the cursor in standard, never pins the view in vim; a scrollbar drag follows the same rule" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 12 });
    defer app.deinit();
    // A narrow screen with the column docked: this test is about
    // what sits beside it, not the width rule (`ui.sidebar_auto_below`).
    app.cfg.ui.sidebar_auto_below = 0;
    app.tree.visible = false;
    _ = try app.openScratch();
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (0..100) |i| try text.print(std.testing.allocator, "L{d}\n", .{i});
    try app.activeEditor().?.buf.editor.setText(text.items);
    try app.render();
    // Standard + always: the cursor rides the wheel.
    app.cfg.editor.wheel_moves_cursor = .always;
    app.now_ms += 1000;
    try app.handle(.{ .mouse = .{ .x = 10, .y = 5, .kind = .scroll_down } });
    try app.tick(app.now_ms);
    try std.testing.expectEqual(@as(usize, 3), app.activeEditor().?.buf.editor.currentLine());
    try std.testing.expect(app.activeEditor().?.view.pin == null);
    // vim + never: the view moves and pins, the cursor stays.
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    app.cfg.editor.wheel_moves_cursor = .never;
    try app.render();
    app.now_ms += 1000;
    try app.handle(.{ .mouse = .{ .x = 10, .y = 5, .kind = .scroll_down } });
    try app.tick(app.now_ms);
    try std.testing.expectEqual(@as(usize, 3), app.activeEditor().?.buf.editor.currentLine());
    try std.testing.expectEqual(@as(u32, 3), app.activeEditor().?.view.scroll_line);
    try std.testing.expect(app.activeEditor().?.view.pin != null);
    // The scrollbar: a press half-way down the track under `never`
    // moves the view, not the cursor; under `always` the cursor goes.
    try app.render();
    const track = scrollbarTrackOf(&app, .{ .pane = app.active.? }).?;
    try press(&app, track.x, track.y + track.h / 2, .left);
    try std.testing.expectEqual(@as(usize, 3), app.activeEditor().?.buf.editor.currentLine());
    try std.testing.expect(app.activeEditor().?.view.scroll_line > 20);
    try release(&app, track.x, track.y + track.h / 2);
    app.cfg.editor.wheel_moves_cursor = .always;
    try app.render();
    try press(&app, track.x, track.y + track.h / 2, .left);
    try std.testing.expect(app.activeEditor().?.buf.editor.currentLine() > 20);
    try release(&app, track.x, track.y + track.h / 2);
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

test "gestures: a divider drag resizes with the minimum kept, a tab drag reorders, the + opens the Create… menu" {
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
    // The `+` after the tabs opens the `Create…` menu under itself;
    // its New ▸ Scratch buffer row opens a scratch in that leaf.
    try app.render();
    var plus: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .button and h.target.button == render.Button.newTab(0)) {
        plus = h.rect;
    };
    try press(&app, plus.?.x + 1, plus.?.y, .left);
    try release(&app, plus.?.x + 1, plus.?.y);
    try std.testing.expect(app.overlay == .menu);
    try std.testing.expectEqualStrings("Create…", app.overlay.menu.title);
    try std.testing.expect(app.overlay.menu.curatable);
    try std.testing.expectEqual(plus.?.x, app.overlay.menu.x);
    try std.testing.expectEqual(plus.?.y + 1, app.overlay.menu.y);
    try app.handle(.{ .key = Key.named(.right) });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.enter) });
    try std.testing.expect(app.overlay == .none);
    try std.testing.expectEqual(@as(usize, 3), leaf.tabs.items.len);
}

// ─── right-click: the structural test ───────────────────────────────────

/// What each hit kind does with the right button. `EnumArray.init`
/// wants every tag, so a new `HitTarget` variant does not compile until
/// it is placed here — with a menu of its own, a delegate that opens
/// one, or a one-word reason it has none. The test below then checks
/// the claim against `mouse`'s own source.
pub const RightClick = union(enum) {
    /// The arm in `mouse` reads `.right` itself.
    here,
    /// The arm hands the press to this call, which reads `.right`.
    delegated: []const u8,
    /// No right-click, and the one-word reason.
    none: []const u8,
};

const HitTag = std.meta.Tag(@import("../ui/hit.zig").HitTarget);

pub const right_click_of = std.EnumArray(HitTag, RightClick).init(.{
    .pane = .here,
    .divider = .{ .none = "drag" },
    .tab = .here,
    .tab_close = .here,
    .breadcrumb = .here,
    .row = .{ .delegated = "rowMouse" },
    .kebab = .{ .delegated = "kebabMouse" },
    .chip = .{ .delegated = "chipMouse" },
    .filter_input = .{ .none = "focus" },
    .scrollbar = .{ .none = "drag" },
    .button = .here,
    .link = .here,
    .menu_item = .here,
    .statusline_seg = .here,
    .tip_row = .{ .none = "left runs the row" },
    .tree_node = .here,
    .tree_root = .here,
    .tree_empty = .here,
    .tree_chip = .{ .none = "one-verb" },
    .info_view = .{ .delegated = "info_view_app.mouse" },
    .script_hit = .here,
    .editor_cell = .{ .delegated = "editorCellMouse" },
    .hover_popup = .{ .none = "dismisses" },
    .gutter = .{ .delegated = "gutterMouse" },
    .fold_arrow = .{ .delegated = "gutterMouse" },
    .overlay_item = .here,
    .dock = .{ .delegated = "dock.mouse" },
    .launcher_dock = .{ .delegated = "launcher_dock.mouse" },
    .rail = .{ .delegated = "activity_bar.mouse" },
    .welcome = .{ .delegated = "welcome_app.mouse" },
    .git_palette = .{ .delegated = "git_palette.partMouse" },
    .http = .{ .delegated = "http_panel.partMouse" },
    .font_update = .{ .none = "one-verb" },
    .ai_placeholder = .{ .none = "one-verb" },
    .search_chip = .{ .none = "one-verb" },
});

/// The source of `mouse`'s arm for `tag`: from `        .tag => ` (the
/// switch's own indent) to the next arm at that indent, or the switch's
/// close.
fn armSource(body: []const u8, tag: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\n        .{s} => ", .{tag}) catch return null;
    const start = std.mem.indexOf(u8, body, needle) orelse return null;
    const rest = body[start + needle.len ..];
    const next_arm = std.mem.indexOf(u8, rest, "\n        .") orelse rest.len;
    const close = std.mem.indexOf(u8, rest, "\n    }") orelse rest.len;
    return rest[0..@min(next_arm, close)];
}

test "right-click: every HitTarget's mouse arm reads the right button, hands it to a call that does, or is listed with a reason" {
    const src = @embedFile("dispatch.zig");
    const start = std.mem.indexOf(u8, src, "\npub fn mouse(").?;
    const body = src[start..];
    inline for (std.meta.fields(HitTag)) |f| {
        const arm = armSource(body, f.name) orelse {
            std.debug.print("no `.{s} =>` arm in dispatch.mouse\n", .{f.name});
            return error.TestUnexpectedResult;
        };
        const claim = right_click_of.get(@field(HitTag, f.name));
        const ok = switch (claim) {
            .here => std.mem.indexOf(u8, arm, ".right") != null,
            .delegated => |call| std.mem.indexOf(u8, arm, call) != null,
            .none => std.mem.indexOf(u8, arm, ".right") == null,
        };
        if (!ok) {
            std.debug.print("`.{s}` is listed as {s} but its arm says otherwise\n", .{ f.name, @tagName(claim) });
            return error.TestUnexpectedResult;
        }
    }
}

test "right-click: armSource finds an arm by its exact tag and stops at the next" {
    const body = "\npub fn mouse() {\n    switch (t) {\n        .tab => |tb| {\n            x\n        },\n        .tab_close => |tb| {\n            .right\n        },\n    }\n}\n";
    try std.testing.expect(std.mem.indexOf(u8, armSource(body, "tab").?, ".right") == null);
    try std.testing.expect(std.mem.indexOf(u8, armSource(body, "tab_close").?, ".right") != null);
    try std.testing.expect(armSource(body, "nope") == null);
}

test "wheel over the tree: a batch is a notch and moves one row; a batch inside the 60 ms window is the same notch; accel on takes the factor's rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const root = try std.testing.allocator.dupe(u8, buf[0..n]);
    defer std.testing.allocator.free(root);
    for (0..12) |i| {
        var name: [12]u8 = undefined;
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = try std.fmt.bufPrint(&name, "f{d:0>2}.txt", .{i}), .data = "x" });
    }
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = root, .cols = 80, .rows = 30 });
    defer app.deinit();
    // A narrow screen with the column docked: this test is about
    // what sits beside it, not the width rule (`ui.sidebar_auto_below`).
    app.cfg.ui.sidebar_auto_below = 0;
    try app.tree.refresh(&app);
    try std.testing.expect(app.tree.rows.items.len >= 12);
    app.cfg.editor.scroll_accel = .off;
    try app.render();
    var row: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .tree_node and h.target.tree_node == 0) {
        row = h.rect;
    };
    const r = row.?;
    const at = struct {
        fn wheel(a: *App, rr: Rect, kind: key_mod.MouseKind) !void {
            try a.handle(.{ .mouse = .{ .x = rr.x + 2, .y = rr.y, .kind = kind } });
        }
    };
    // Three events in one batch — a ghostty detent — step one row.
    app.now_ms += 1000;
    for (0..3) |_| try at.wheel(&app, r, .scroll_down);
    try app.tick(app.now_ms);
    try std.testing.expectEqual(@as(usize, 1), app.tree.cursor);
    // 20 ms on: the same notch, nothing more.
    app.now_ms += 20;
    try at.wheel(&app, r, .scroll_down);
    try app.tick(app.now_ms);
    try std.testing.expectEqual(@as(usize, 1), app.tree.cursor);
    // 60 ms on: the next notch.
    app.now_ms += 60;
    try at.wheel(&app, r, .scroll_down);
    try app.tick(app.now_ms);
    try std.testing.expectEqual(@as(usize, 2), app.tree.cursor);
    // Accel on: a slow notch is a row; a fast follow-up earns the factor
    // (2.5 at normal — two rows, then the carried half makes three).
    app.cfg.editor.scroll_accel = .normal;
    app.now_ms += 1000;
    try at.wheel(&app, r, .scroll_down);
    try app.tick(app.now_ms);
    try std.testing.expectEqual(@as(usize, 3), app.tree.cursor);
    app.now_ms += 8;
    try at.wheel(&app, r, .scroll_down);
    try app.tick(app.now_ms);
    try std.testing.expectEqual(@as(usize, 5), app.tree.cursor);
    app.now_ms += 8;
    try at.wheel(&app, r, .scroll_down);
    try app.tick(app.now_ms);
    try std.testing.expectEqual(@as(usize, 8), app.tree.cursor);
}

test "a context menu taller than the screen: the wheel scrolls it a row per event, the border says which way the rest lies, End reaches the last row, a scrolled row's hit names its item" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 14 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try app.render();
    // The editor body's menu has more rows than a 14-row screen holds.
    try press(&app, 20, 5, .right);
    try release(&app, 20, 5);
    try std.testing.expect(app.overlay == .menu);
    const total = app.overlay.menu.items.len;
    try std.testing.expect(total > 12);
    try app.render();
    const rowOf = struct {
        fn f(a: *App, idx: usize) ?Rect {
            for (a.hits.items.items) |h| if (h.target == .menu_item and h.target.menu_item.menu == 0 and h.target.menu_item.idx == idx) return h.rect;
            return null;
        }
    };
    const screen_mod = @import("../ipc/screen.zig");
    try std.testing.expect(rowOf.f(&app, 0) != null);
    try std.testing.expect(rowOf.f(&app, total - 1) == null);
    var text = try screen_mod.toTestText(std.testing.allocator, &app.screen);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{2193}") != null);
    std.testing.allocator.free(text);
    // Two wheel events over a row: two items off the top.
    const first = rowOf.f(&app, 0).?;
    app.now_ms += 1000;
    for (0..2) |_| try app.handle(.{ .mouse = .{ .x = first.x + 2, .y = first.y + 1, .kind = .scroll_down } });
    try app.tick(app.now_ms);
    try std.testing.expectEqual(@as(usize, 2), app.overlay.menu.scroll);
    try app.render();
    try std.testing.expect(rowOf.f(&app, 0) == null);
    try std.testing.expect(rowOf.f(&app, 2) != null);
    text = try screen_mod.toTestText(std.testing.allocator, &app.screen);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{2195}") != null);
    std.testing.allocator.free(text);
    // End: the cursor on the last row, the window pulled after it.
    try app.handle(.{ .key = Key.named(.end) });
    try app.render();
    try std.testing.expectEqual(total - 1, app.overlay.menu.cursor);
    const last = rowOf.f(&app, total - 1).?;
    try std.testing.expect(app.hits.at(last.x + 1, last.y).?.menu_item.idx == total - 1);
    text = try screen_mod.toTestText(std.testing.allocator, &app.screen);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{2191}") != null);
    std.testing.allocator.free(text);
}

test "a scrollbar drag keeps steering off the bar until the release: the help box" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 16 });
    defer app.deinit();
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"view.help" });
    try app.render();
    const track = scrollbarTrackOf(&app, .{ .pane = HelpUi.scrollbar_owner }).?;
    try press(&app, track.x, track.y + track.h - 1, .left);
    try std.testing.expect(app.overlay.help.scroll > 0);
    try std.testing.expect(app.drag != null and app.drag.? == .bar);
    // The pointer wanders off the bar; the drag still lands the view by its row.
    try dragTo(&app, track.x -| 5, track.y);
    try std.testing.expectEqual(@as(usize, 0), app.overlay.help.scroll);
    try release(&app, track.x -| 5, track.y);
    try std.testing.expect(app.drag == null);
}

test "a submenu's first arrow moves as well as lights: New ▸ then two downs and Enter opens the HTTP request; the File menu's recent list the same" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &pbuf);
    const root = pbuf[0..n];
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "a\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.txt", .data = "b\n" });
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = root, .cols = 120, .rows = 40 });
    defer app.deinit();
    try app.render();
    // The `+` opens Create…; the pointer resting on New opens its child
    // un-highlighted on row 0 (Rust's child starts un-interacted).
    var plus: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .button and h.target.button == render.Button.newTab(0)) {
        plus = h.rect;
    };
    try press(&app, plus.?.x + 1, plus.?.y, .left);
    try release(&app, plus.?.x + 1, plus.?.y);
    try std.testing.expect(app.overlay == .menu);
    try std.testing.expectEqualStrings("Create…", app.overlay.menu.title);
    try app.render();
    var new_row: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .menu_item and h.target.menu_item.menu == 0 and h.target.menu_item.idx == 0) {
        new_row = h.rect;
    };
    try app.handle(.{ .mouse = .{ .x = new_row.?.x + 3, .y = new_row.?.y, .kind = .motion } });
    try std.testing.expect(app.overlay.menu.sub != null);
    try std.testing.expectEqualStrings("Scratch buffer", app.overlay.menu.sub.?.items[0].label);
    try std.testing.expect(!app.overlay.menu.sub.?.highlight);
    // Two downs land on the third row, as Rust's `move_down` does from
    // row 0; Enter runs it.
    try app.handle(.{ .key = key_mod.Key.named(.down) });
    try std.testing.expect(app.overlay.menu.sub.?.highlight);
    try std.testing.expectEqual(@as(usize, 1), app.overlay.menu.sub.?.cursor);
    try app.handle(.{ .key = key_mod.Key.named(.down) });
    try std.testing.expectEqual(@as(usize, 2), app.overlay.menu.sub.?.cursor);
    try std.testing.expectEqualStrings("HTTP request", app.overlay.menu.sub.?.items[2].label);
    try app.handle(.{ .key = key_mod.Key.named(.enter) });
    try std.testing.expect(app.overlay == .none);
    try std.testing.expectEqualStrings("GET  new request", app.panes.get(app.active.?).?.title());
    // The menu bar's one submenu, keyboard-opened: → on "Open recent
    // file" opens the list on row 0; one down is the second-newest file.
    const a = try std.fs.path.join(std.testing.allocator, &.{ root, "a.txt" });
    defer std.testing.allocator.free(a);
    const b = try std.fs.path.join(std.testing.allocator, &.{ root, "b.txt" });
    defer std.testing.allocator.free(b);
    _ = try app.openPath(a);
    _ = try app.openPath(b);
    try menu_bar.openIndex(&app, 1);
    try std.testing.expect(app.overlay == .menu);
    try std.testing.expectEqualStrings("File", app.overlay.menu.title);
    var i: usize = 0;
    while (i < app.overlay.menu.items.len and app.overlay.menu.items[i].submenu.len == 0) : (i += 1) {}
    app.overlay.menu.cursor = i;
    try app.handle(.{ .key = key_mod.Key.named(.right) });
    try std.testing.expect(app.overlay.menu.sub != null);
    try std.testing.expectEqualStrings("b.txt", app.overlay.menu.sub.?.items[0].label);
    try app.handle(.{ .key = key_mod.Key.named(.down) });
    try std.testing.expectEqual(@as(usize, 1), app.overlay.menu.sub.?.cursor);
    try app.handle(.{ .key = key_mod.Key.named(.enter) });
    try std.testing.expect(app.overlay == .none);
    try std.testing.expectEqualStrings("a.txt", app.panes.get(app.active.?).?.title());
}

test "toasts: the transient stack keeps five and drops the oldest, a repeat coalesces, a sticky one is not counted, and Esc clears the transient ones even with an overlay open" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    try app.toastPersistent("job", "indexing…", .info);
    var i: usize = 0;
    while (i < 7) : (i += 1) app.toast("toast {d}", .{i});
    // Five transient plus the sticky one; 0 and 1 were the oldest.
    try std.testing.expectEqual(@as(usize, 6), app.toasts.items.len);
    try std.testing.expectEqualStrings("indexing…", app.toasts.items[0].text);
    try std.testing.expectEqualStrings("toast 2", app.toasts.items[1].text);
    try std.testing.expectEqualStrings("toast 6", app.lastToast().?);
    // The same text again bumps its box instead of stacking a twin.
    app.toast("toast 4", .{});
    try std.testing.expectEqual(@as(usize, 6), app.toasts.items.len);
    try std.testing.expectEqualStrings("toast 4", app.lastToast().?);
    try std.testing.expectEqual(@as(u32, 2), app.toasts.items[app.toasts.items.len - 1].repeats);
    // Esc with the palette open closes the palette AND the toasts; the
    // sticky one stays until its owner dismisses it.
    try command.run(&app, .{ .static = .palette });
    try std.testing.expect(app.overlay == .picker);
    try app.handle(.{ .key = key_mod.Key.named(.esc) });
    try std.testing.expect(app.overlay == .none);
    try std.testing.expectEqual(@as(usize, 1), app.toasts.items.len);
    try std.testing.expectEqualStrings("indexing…", app.toasts.items[0].text);
    app.dismissToast("job");
    try std.testing.expectEqual(@as(usize, 0), app.toasts.items.len);
    // And with nothing open at all.
    app.toast("later", .{});
    try app.handle(.{ .key = key_mod.Key.named(.esc) });
    try std.testing.expectEqual(@as(usize, 0), app.toasts.items.len);
}

test "a paste into the editor lands literally in both profiles: no auto-indent cascade, every line break kept" {
    const pasted = [_][]const u8{
        "    a = 1\r        b = (2\rc = [3]\r", // CR: xterm, Terminal.app, iTerm2
        "    a = 1\n        b = (2\nc = [3]\n", // LF: kitty, wezterm
        "    a = 1\r\n        b = (2\r\nc = [3]\r\n",
    };
    for ([_]input.Style{ .standard, .vim }) |style| for (pasted) |p| {
        var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 12 });
        defer app.deinit();
        try app.setInputStyle(style);
        _ = try app.openScratch();
        const e = app.activeEditor().?;
        e.buf.doc.auto_indent = true;
        e.buf.doc.auto_pair = true;
        if (style == .vim) try app.handle(.{ .key = Key.char('i') });
        try app.handle(.{ .paste = try std.testing.allocator.dupe(u8, p) });
        try std.testing.expectEqualStrings("    a = 1\n        b = (2\nc = [3]\n", e.buf.editor.bytes());
        // One change: one undo takes the whole paste back.
        if (style == .vim) try app.handle(.{ .key = Key.named(.esc) });
        _ = try app.applyOps(e, &.{.undo});
        try std.testing.expectEqualStrings("", e.buf.editor.bytes());
    };
}

/// The first rect the last frame registered for `want` (a `.tab_close`
/// or `.button` target), by its centre cell.
fn hitCentre(app: *App, want: app_mod.PressedButton) ?[2]u16 {
    for (app.hits.items.items) |h| if (firesOnRelease(h.target)) |pb| if (std.meta.eql(pb, want)) {
        return .{ h.rect.x + h.rect.w / 2, h.rect.y + h.rect.h / 2 };
    };
    return null;
}

test "a button fires on the release inside it: a close badge or a strip chip pressed and slid off does nothing; the badge dragged off drags its tab" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 120, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    const a = try app.openScratch();
    const b = try app.openScratch();
    const layout = app.layouts.current();
    try app.render();
    // The first tab's close badge (tab 0 of leaf 0).
    const badge: app_mod.PressedButton = .{ .tab_close = .{ .leaf = 0, .idx = 0 } };
    const at = hitCentre(&app, badge).?;
    // Pressed: armed, nothing closed yet.
    try press(&app, at[0], at[1], .left);
    try std.testing.expect(app.panes.get(a) != null);
    // Slid off onto the editor and released: the badge's tab is being
    // dragged, not closed — the release drops it where it is.
    try dragTo(&app, 60, 20);
    try std.testing.expect(app.drag == null or app.drag.? == .tab);
    try release(&app, 60, 20);
    try std.testing.expect(app.panes.get(a) != null);
    try std.testing.expect(app.drag == null);
    // A press and release on the badge closes the tab.
    try app.render();
    const at2 = hitCentre(&app, badge).?;
    const first = layout.leaf(layout.firstLeaf().?).?.tabs.items[0];
    try press(&app, at2[0], at2[1], .left);
    try release(&app, at2[0], at2[1]);
    try std.testing.expect(app.panes.get(first) == null);
    _ = b;
    // A strip chip (split right): pressed and slid off, no split; pressed
    // and released on it, the split.
    try app.render();
    const chip: app_mod.PressedButton = .{ .button = @intFromEnum(render.Button.split_right) };
    const c = hitCentre(&app, chip).?;
    try press(&app, c[0], c[1], .left);
    try dragTo(&app, 60, 20);
    try release(&app, 60, 20);
    try std.testing.expectEqual(@as(usize, 1), (try layout.leaves(app.frame.allocator())).len);
    try app.render();
    const c2 = hitCentre(&app, chip).?;
    try press(&app, c2[0], c2[1], .left);
    try release(&app, c2[0], c2[1]);
    try std.testing.expectEqual(@as(usize, 2), (try layout.leaves(app.frame.allocator())).len);
}
