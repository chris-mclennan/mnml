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
const ex = @import("ex.zig");
const find_mod = @import("find.zig");
const cmd_find = @import("cmd_find.zig");
const cmd_file = @import("cmd_file.zig");
const cmd_picker = @import("cmd_picker.zig");
const Prompt = app_mod.Prompt;
const Confirm = app_mod.Confirm;
const Picker = app_mod.Picker;
const FindBar = app_mod.FindBar;
const fuzzy = @import("../ui/fuzzy.zig");
const todos = @import("../todos.zig");

// ─── keys ───────────────────────────────────────────────────────────────

pub fn key(app: *App, k: Key) Allocator.Error!void {
    app.needs_render = true;
    switch (app.overlay) {
        .none => {},
        else => return overlayKey(app, k),
    }
    if (app.find_bar != null) return findBarKey(app, k);
    if (app.focus == .tree and app.tree.visible) {
        if (try app.tree.handleKey(app, k)) return;
        _ = try chordChain(app, k);
        return;
    }
    if (app.focus == .panel and app.right_panel != null) {
        const took = switch (app.focus.panel) {
            .todos => try todos.handleKey(app, k),
            .notes, .findings, .sessions => false,
        };
        if (took) return;
        _ = try chordChain(app, k);
        return;
    }

    const pane_id = app.active;
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
    const editor_first = ed != null and (cmdline_open or (bare_space and (!modal or op_pending)) or (typing_mode and plain) or (op_pending and plain) or (modal and plain and !bare_space));
    if (!editor_first and app.chord.len == 0 and ed == null) {
        // No pane: only chords do anything.
        _ = try chordChain(app, k);
        return;
    }
    if (!editor_first) {
        if (try chordChain(app, k)) return;
    }
    const e = ed orelse return;
    const consumed = try feedEditor(app, pane_id.?, e, k);
    if (!consumed and editor_first) _ = try chordChain(app, k);
}

/// Feed one key to the editor and act on what it reports. Returns
/// false when the editor did not want the key.
fn feedEditor(app: *App, pane_id: PaneId, e: *EditorPane, k: Key) Allocator.Error!bool {
    const arena = app.frame.allocator();
    const before_mode = e.buf.input.mode();
    const mark = markPrefix(e);
    const mark_key: ?u8 = if (k.typed()) |c| (if (c < 128 and std.ascii.isAlphabetic(@intCast(c))) @as(u8, @intCast(c)) else null) else null;
    const had_mark: bool = if (mark != null and mark_key != null) e.buf.marks.contains(mark_key.?) else false;
    const trigger = before_mode == .insert and isAbbrevTrigger(k);
    const wrap_width: ?usize = if (e.wrap orelse app.cfg.wrap) app.pane_cols else null;
    cmd_find.seedCtxMatches(e);

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
            e.hl_dirty = true;
            if (trigger) try expandAbbreviation(app, e);
        },
        .app => |cmd| try handleAppCommand(app, pane_id, e, cmd),
    }
    // Marks toast from here: the buffer handles them silently.
    if (mark != null and mark_key != null and ev != .unhandled) {
        const c = mark_key.?;
        switch (mark.?) {
            .set => app.toast("mark '{c} set", .{c}),
            .jump => if (!had_mark) app.toast("no mark '{c}", .{c}) else {
                const p = e.buf.editor.rowCol();
                app.toast("→ '{c} {d}:{d}", .{ c, p.row + 1, p.col + 1 });
            },
        }
    }
    // The editor cannot hold a block anchor yet; remember where the
    // visual block started so `I` / `A` / `c` know their rectangle.
    const after_mode = e.buf.input.mode();
    if (after_mode == .visual_block and before_mode != .visual_block) e.block_anchor = e.buf.editor.cursor;
    if (after_mode != .visual_block) e.block_anchor = null;
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
            app.chord.deadline_ms = app.now_ms + @as(i64, @intCast(app.cfg.chord_timeout_ms));
            return true;
        },
        .pending => {
            try setFallback(app, null);
            app.chord.deadline_ms = app.now_ms + @as(i64, @intCast(app.cfg.chord_timeout_ms));
            return true;
        },
        .none => {
            const fallback = app.chord.fallback;
            app.chord.fallback = null;
            const was_first = app.chord.len == 1;
            app.chord.clear(app.gpa);
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
                    app.chord.deadline_ms = app.now_ms + @as(i64, @intCast(app.cfg.chord_timeout_ms));
                    return true;
                },
                .pending => {
                    app.chord.deadline_ms = app.now_ms + @as(i64, @intCast(app.cfg.chord_timeout_ms));
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
pub fn expireChords(app: *App) Allocator.Error!void {
    if (app.chord.deadline_ms == null) return;
    const fallback = app.chord.fallback;
    app.chord.fallback = null;
    app.chord.clear(app.gpa);
    if (fallback) |fb| {
        defer freeTarget(app, fb);
        try runTarget(app, fb);
    }
    app.needs_render = true;
}

// ─── overlays ───────────────────────────────────────────────────────────

fn restoreFocus(app: *App) void {
    app.focus = if (app.active) |a| .{ .pane = a } else .tree;
}

fn closeOverlay(app: *App) void {
    const back: ?app_mod.FocusId = if (app.overlay == .menu) app.overlay.menu.return_focus else null;
    app.overlay.deinit(app.gpa);
    if (back) |f| {
        app.focus = f;
        if (f == .panel and app.right_panel == null) restoreFocus(app);
    } else restoreFocus(app);
}

/// A menu row was chosen: close the menu, then act.
fn runMenuAction(app: *App, action: command.MenuAction) Allocator.Error!void {
    closeOverlay(app);
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
            .notes, .findings, .sessions => {},
        },
        .none => {},
    }
}

fn overlayKey(app: *App, k: Key) Allocator.Error!void {
    const gpa = app.gpa;
    switch (app.overlay) {
        .none => {},
        .prompt => |*p| switch (try Prompt.handleKey(&p.state, gpa, k)) {
            .consumed => {},
            .cancel => closeOverlay(app),
            .submit => {
                const text = try app.frame.allocator().dupe(u8, p.state.buf.items);
                const purpose = p.purpose;
                closeOverlay(app);
                try acceptPrompt(app, purpose, text);
            },
        },
        .confirm => |*c| switch (Confirm.handleKey(&c.state, k)) {
            .consumed => {},
            .cancel => closeOverlay(app),
            .choose => |i| {
                const purpose = c.purpose;
                closeOverlay(app);
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
            .consumed => {},
            .cancel => closeOverlay(app),
            .changed => try refilterPicker(app),
            .accept => |i| try cmd_picker.accept(app, i),
        },
        .menu => |*m| {
            const last = m.items.len -| 1;
            switch (k.code) {
                .esc => closeOverlay(app),
                .enter => if (m.items.len > 0) try runMenuAction(app, m.items[m.cursor].action),
                .up => m.cursor -|= 1,
                .down => m.cursor = @min(m.cursor + 1, last),
                .home => m.cursor = 0,
                .end => m.cursor = last,
                .char => |c| switch (c) {
                    'k' => m.cursor -|= 1,
                    'j' => m.cursor = @min(m.cursor + 1, last),
                    'q' => closeOverlay(app),
                    else => {},
                },
                else => {},
            }
        },
    }
}

pub fn refilterPicker(app: *App) Allocator.Error!void {
    const p = &app.overlay.picker;
    p.filtered.clearRetainingCapacity();
    const q = p.state.query.items;
    const Scored = struct { idx: u32, score: u32 };
    var scored: std.ArrayListUnmanaged(Scored) = .empty;
    defer scored.deinit(app.gpa);
    for (p.labels, 0..) |label, i| {
        if (fuzzy.score(q, label)) |s| try scored.append(app.gpa, .{ .idx = @intCast(i), .score = s });
    }
    if (q.len > 0) std.mem.sort(Scored, scored.items, {}, struct {
        fn lt(_: void, a: Scored, b: Scored) bool {
            return a.score > b.score or (a.score == b.score and a.idx < b.idx);
        }
    }.lt);
    for (scored.items) |s| try p.filtered.append(app.gpa, s.idx);
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
        .replace => try cmd_find.replaceAll(app, text),
        .filter_shell => try filterThroughShell(app, text),
        .new_todo => todos.appendTodo(app, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => {},
            else => if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("todo: {s}", .{@errorName(err)}),
        },
    }
}

fn acceptConfirm(app: *App, purpose: app_mod.ConfirmPurpose, choice: usize) Allocator.Error!void {
    switch (purpose) {
        .close_pane => |id| switch (choice) {
            0 => {
                const e = app.panes.editor(id) orelse return;
                if (e.buf.path == null) {
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
    }
}

// ─── the find bar ───────────────────────────────────────────────────────

fn findBarKey(app: *App, k: Key) Allocator.Error!void {
    const fb = &app.find_bar.?;
    switch (try FindBar.handleKey(&fb.state, app.gpa, k)) {
        .consumed, .toggle_regex, .toggle_case, .focus_toggle => {},
        .cancel => app.closeFindBar(true),
        .changed => try cmd_find.liveUpdate(app),
        .submit => try cmd_find.acceptFromBar(app),
        .next => try cmd_find.stepFind(app, 1),
        .prev => try cmd_find.stepFind(app, -1),
        .replace_one => try cmd_find.replaceCurrent(app),
        .replace_all => {
            const text = try app.frame.allocator().dupe(u8, fb.state.replace.items);
            try cmd_find.replaceAll(app, text);
        },
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
    const e = app.activeEditor() orelse return;
    const copy = try app.frame.allocator().dupe(u8, text);
    _ = try app.applyOps(e, &.{.{ .insert_str = copy }});
}

// ─── mouse ──────────────────────────────────────────────────────────────

pub fn mouse(app: *App, m: Mouse) Allocator.Error!void {
    app.needs_render = true;
    app.hover = .{ .x = m.x, .y = m.y };
    const target = app.hits.at(m.x, m.y) orelse {
        if (m.kind == .press and app.overlay == .menu) closeOverlay(app);
        return;
    };
    // A press anywhere but on the menu dismisses it; the press then
    // goes on to whatever it landed on.
    if (m.kind == .press and app.overlay == .menu and target != .menu_item) closeOverlay(app);
    switch (target) {
        // The list panels (D6): one prong per hit kind, routed by panel.
        .row => |pr| switch (pr.panel) {
            .todos => try todos.rowMouse(app, pr.idx, m),
            .notes, .findings, .sessions => {},
        },
        .kebab => |pr| switch (pr.panel) {
            .todos => try todos.kebabMouse(app, pr.idx, m),
            .notes, .findings, .sessions => {},
        },
        .chip => |c| switch (c.panel) {
            .todos => try todos.chipMouse(app, c.kind, m),
            .notes, .findings, .sessions => {},
        },
        .filter_input => |p| switch (p) {
            .todos => todos.filterMouse(app, m),
            .notes, .findings, .sessions => {},
        },
        .scrollbar => |sb| switch (sb.owner) {
            .panel => |p| switch (p) {
                .todos => if (hitRect(app, m.x, m.y)) |r| todos.scrollbarMouse(app, r, m),
                .notes, .findings, .sessions => {},
            },
            .pane => {},
        },
        .menu_item => |mi| if (m.kind == .press) {
            if (app.overlay != .menu) return;
            const items = app.overlay.menu.items;
            if (mi.idx >= items.len) return;
            try runMenuAction(app, items[mi.idx].action);
        },
        .editor_cell => |cell| {
            if (m.kind == .scroll_up or m.kind == .scroll_down) {
                const e = app.panes.editor(cell.pane) orelse return;
                const delta: i32 = if (m.kind == .scroll_up) -3 else 3;
                const cur: i64 = e.view.scroll_line;
                const max: i64 = @intCast(e.buf.editor.lineCount() -| 1);
                e.view.scroll_line = @intCast(std.math.clamp(cur + delta, 0, max));
                return;
            }
            if (m.kind != .press and m.kind != .drag) return;
            if (app.overlay != .none) closeOverlay(app);
            if (app.active != cell.pane) app.showPane(cell.pane);
            const e = app.panes.editor(cell.pane) orelse return;
            const ed = &e.buf.editor;
            const line = @min(cell.line, ed.lineCount() - 1);
            // The column under the pointer: the hit's first column plus the offset.
            const hit_rect = hitRect(app, m.x, m.y) orelse return;
            const col = cell.col + (m.x - hit_rect.x);
            if (m.kind == .drag) {
                if (ed.anchor == null) ed.anchor = ed.cursor;
                ed.placeCursor(line, col);
            } else {
                ed.anchor = null;
                ed.placeCursor(line, col);
            }
        },
        .tab => |t| {
            if (m.kind != .press) return;
            const layout = app.layouts.current();
            const leaves = layout.leaves(app.frame.allocator()) catch return;
            if (t.leaf >= leaves.len) return;
            const leaf = layout.leaf(leaves[t.leaf]) orelse return;
            if (t.idx >= leaf.tabs.items.len) return;
            const pane = leaf.tabs.items[t.idx];
            if (m.button == .middle) return app.closePane(pane, false);
            app.showPane(pane);
        },
        .overlay_item => |i| {
            if (m.kind != .press) return;
            switch (app.overlay) {
                .confirm => |*c| {
                    const purpose = c.purpose;
                    closeOverlay(app);
                    try acceptConfirm(app, purpose, i);
                },
                .picker => try cmd_picker.accept(app, i),
                .which_key => |*w| {
                    const kids = whichkey.continuations(w.slice());
                    if (i >= kids.len) return;
                    try overlayKey(app, Key.char(kids[i].key));
                },
                else => {},
            }
        },
        .pane => |id| if (m.kind == .press) {
            if (app.overlay != .none) closeOverlay(app);
            app.showPane(id);
        },
        .tree_node => |idx| switch (m.kind) {
            .press => {
                if (app.overlay != .none) closeOverlay(app);
                if (m.button == .left) try app.tree.activate(app, idx) else app.tree.cursor = idx;
            },
            .scroll_up => app.tree.cursor -|= 3,
            .scroll_down => app.tree.cursor = @min(app.tree.cursor + 3, app.tree.rows.items.len -| 1),
            else => {},
        },
        else => {},
    }
}

fn hitRect(app: *App, x: u16, y: u16) ?@import("../ui/rect.zig") {
    var i = app.hits.items.items.len;
    while (i > 0) {
        i -= 1;
        const e = app.hits.items.items[i];
        if (e.rect.contains(x, y)) return e.rect;
    }
    return null;
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
        // Buffer-local; the buffer answered them before we got here.
        .dot_repeat, .set_mark, .jump_to_mark_line, .jump_to_mark_exact, .macro_record_into, .macro_replay_from => {},
        .block_insert_start => |b| try beginBlockInsert(app, pane_id, e, b.append, false),
        .block_change_start => try beginBlockInsert(app, pane_id, e, false, true),
        .block_replace_with => |r| try blockReplace(app, e, r.ch),
        .filter_lines_from_cursor => |f| {
            const row = e.buf.editor.currentLine();
            const last = @min(row + @max(f.count, 1) - 1, e.buf.editor.lineCount() - 1);
            try openFilterPrompt(app, row, last);
        },
        .filter_paragraph_from_cursor => |p| {
            const range = paragraphRows(&e.buf.editor, p.around);
            try openFilterPrompt(app, range[0], range[1]);
        },
        .repeat_insert_start => |r| try beginRepeatInsert(app, pane_id, e, r.count, r.above),
        .operator_linewise_to => |o| try linewiseOp(app, e, o.op, o.target),
        .cmdline_tab_complete => try cmdlineTabComplete(app, e),
        .cmdline_popup_move => |d| try cmdlineCycle(app, e, d),
        .cmdline_insert_cursor_word => |big| try cmdlineInsertWord(app, e, big),
        .cmdline_paste_from_clipboard => try cmdlineInsert(app, e, app.clipboard.text()),
        .flash_start => |f| flashJump(e, f.a, f.b),
    }
}

/// Run an ex line; a failure toasts the reason (or the error name).
pub fn runExLine(app: *App, line: []const u8) Allocator.Error!void {
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
    const anchor = e.block_anchor orelse return null;
    const ed = &e.buf.editor;
    const a = ed.rowColAt(anchor);
    const b = ed.rowCol();
    return .{ .r0 = @min(a.row, b.row), .r1 = @max(a.row, b.row), .c0 = @min(a.col, b.col), .c1 = @max(a.col, b.col) };
}

/// `I` / `A` / `c` on a visual block: (for `c`) cut the rectangle, put
/// the cursor on the first row at the insert column, enter Insert, and
/// remember the rectangle so the typed run is replayed on Esc.
fn beginBlockInsert(app: *App, pane_id: PaneId, e: *EditorPane, append: bool, change: bool) Allocator.Error!void {
    const rect = blockRect(e) orelse {
        e.buf.input.requestInsertMode();
        return;
    };
    e.block_anchor = null;
    const ed = &e.buf.editor;
    var col = if (append) rect.c1 + 1 else rect.c0;
    if (change) {
        // Delete the rectangle bottom-up so earlier offsets stay valid.
        var row = rect.r1 + 1;
        try ed.checkpoint();
        while (row > rect.r0) {
            row -= 1;
            const s = ed.byteAtCol(row, rect.c0);
            const en = @min(ed.byteAtCol(row, rect.c1 + 1), ed.lineEnd(row));
            if (en > s) try ed.splice(s, en, "");
        }
        col = rect.c0;
        e.hl_dirty = true;
    }
    const start = @min(ed.byteAtCol(rect.r0, col), ed.lineEnd(rect.r0));
    ed.setCursor(start);
    ed.anchor = null;
    e.buf.input.requestInsertMode();
    app.block_insert = .{ .pane = pane_id, .first_row = rect.r0, .last_row = rect.r1, .col = col, .start_byte = start, .len_before = ed.len() };
}

/// `r<ch>` on a visual block: every cell in the rectangle becomes `ch`.
fn blockReplace(app: *App, e: *EditorPane, ch: u21) Allocator.Error!void {
    const rect = blockRect(e) orelse return;
    e.block_anchor = null;
    const ed = &e.buf.editor;
    var glyph: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(ch, &glyph) catch return;
    try ed.checkpoint();
    var row = rect.r1 + 1;
    while (row > rect.r0) {
        row -= 1;
        var c = rect.c1 + 1;
        while (c > rect.c0) {
            c -= 1;
            const s = ed.byteAtCol(row, c);
            if (s >= ed.lineEnd(row)) continue;
            const cp_len = std.unicode.utf8ByteSequenceLength(ed.bytes()[s]) catch 1;
            try ed.splice(s, s + cp_len, glyph[0..n]);
        }
    }
    ed.setCursor(ed.byteAtCol(rect.r0, rect.c0));
    e.buf.dirty = !std.mem.eql(u8, ed.bytes(), e.buf.saved_text);
    e.hl_dirty = true;
    _ = app;
}

/// `<count>o` / `<count>O`: open one line now, replicate on Esc.
fn beginRepeatInsert(app: *App, pane_id: PaneId, e: *EditorPane, count: u32, above: bool) Allocator.Error!void {
    e.buf.input.requestInsertMode();
    _ = try app.applyOps(e, &.{if (above) .insert_newline_above else .insert_newline_below});
    const ed = &e.buf.editor;
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
        const ed = &e.buf.editor;
        if (ed.len() < b.len_before) return;
        const typed_len = ed.len() - b.len_before;
        if (typed_len == 0 or b.start_byte + typed_len > ed.len()) return;
        const typed = try app.frame.allocator().dupe(u8, ed.bytes()[b.start_byte .. b.start_byte + typed_len]);
        if (std.mem.indexOfScalar(u8, typed, '\n') != null) return;
        var row = b.last_row + 1;
        while (row > b.first_row + 1) {
            row -= 1;
            if (row >= ed.lineCount()) continue;
            const at = @min(ed.byteAtCol(row, b.col), ed.lineEnd(row));
            try ed.splice(at, at, typed);
        }
        ed.setCursor(b.start_byte);
        e.buf.dirty = !std.mem.eql(u8, ed.bytes(), e.buf.saved_text);
        e.hl_dirty = true;
        app.needs_render = true;
    }
    if (app.repeat_insert) |r| {
        const e = app.panes.editor(r.pane) orelse {
            app.repeat_insert = null;
            return;
        };
        if (e.buf.input.mode() == .insert) return;
        app.repeat_insert = null;
        const ed = &e.buf.editor;
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
        e.buf.dirty = !std.mem.eql(u8, ed.bytes(), e.buf.saved_text);
        e.hl_dirty = true;
        app.needs_render = true;
    }
}

// ── linewise operators to a line target ──

/// `dG` / `dgg` / `<n>dG` / `yG`…: `target` null = last line, 0 = first,
/// n = 1-based line. Whole lines, inclusive, into the unnamed register.
fn linewiseOp(app: *App, e: *EditorPane, op: u8, target: ?u32) Allocator.Error!void {
    const ed = &e.buf.editor;
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
            e.buf.dirty = !std.mem.eql(u8, ed.bytes(), e.buf.saved_text);
            e.hl_dirty = true;
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
    const ed = &e.buf.editor;
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

const ex_names = [_][]const u8{ "write", "wq", "quit", "edit", "bdelete", "bnext", "bprev", "sort", "retab", "substitute", "set", "registers", "marks", "abbreviate", "unabbreviate", "noh", "tabclose", "tabnew", "tabnext", "tabprev", "tabfirst", "tablast" };
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
        var is_path_cmd = false;
        for (path_commands) |p| if (std.mem.eql(u8, p, head)) {
            is_path_cmd = true;
        };
        if (!is_path_cmd) return;
        const dir_rel = std.fs.path.dirname(partial) orelse "";
        const stem = std.fs.path.basename(partial);
        const dir_abs = try app.absPath(if (dir_rel.len == 0) "." else dir_rel);
        var dir = std.Io.Dir.cwd().openDir(app.io, dir_abs, .{ .iterate = true }) catch return;
        defer dir.close(app.io);
        var it = dir.iterate();
        while (it.next(app.io) catch null) |entry| {
            if (!std.mem.startsWith(u8, entry.name, stem)) continue;
            if (entry.name[0] == '.' and (stem.len == 0 or stem[0] != '.')) continue;
            const rel = if (dir_rel.len == 0) try gpa.dupe(u8, entry.name) else try std.fs.path.join(gpa, &.{ dir_rel, entry.name });
            errdefer gpa.free(rel);
            const full = try std.mem.concat(gpa, u8, &.{ head, " ", rel, if (entry.kind == .directory) "/" else "" });
            gpa.free(rel);
            try cands.append(gpa, full);
        }
        std.mem.sort([]u8, cands.items, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
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

fn cmdlineInsert(app: *App, e: *EditorPane, text: []const u8) Allocator.Error!void {
    const line = e.buf.input.cmdlineGet() orelse return;
    const caret = e.buf.input.cmdlineCaret() orelse line.len;
    var clean: std.ArrayListUnmanaged(u8) = .empty;
    defer clean.deinit(app.gpa);
    for (text) |c| if (c != '\n' and c != '\r') try clean.append(app.gpa, c);
    const joined = try std.mem.concat(app.frame.allocator(), u8, &.{ line[0..caret], clean.items, line[caret..] });
    try e.buf.input.cmdlineSet(joined);
    e.buf.input.setCmdlineCaret(caret + clean.items.len);
}

// ── flash ──

/// `s<a><b>`: jump to the next `ab` after the cursor (wrapping).
fn flashJump(e: *EditorPane, a: u21, b: u21) void {
    var pat: [8]u8 = undefined;
    const na = std.unicode.utf8Encode(a, pat[0..4]) catch return;
    const nb = std.unicode.utf8Encode(b, pat[na..]) catch return;
    const needle = pat[0 .. na + nb];
    const ed = &e.buf.editor;
    const text = ed.bytes();
    const from = @min(ed.cursor + 1, text.len);
    const hit = std.mem.indexOfPos(u8, text, from, needle) orelse std.mem.indexOf(u8, text, needle) orelse return;
    ed.setCursor(hit);
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
