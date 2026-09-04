//! `editor.*` runners: the go-to-line prompt, bracket folds, bracket
//! match, the change-list jumps, the input style switch, and the plain
//! ops that only forward an `EditOp` to the active buffer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const EditorPane = app_mod.EditorPane;
const Prompt = app_mod.Prompt;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const EditOp = @import("../editor/edit_op.zig").EditOp;
const Editor = @import("../editor/editor.zig").Editor;

pub const table = .{
    .@"editor.goto_line" = &gotoLine,
    .@"editor.toggle_fold" = &toggleFold,
    .@"editor.open_fold" = &openFold,
    .@"editor.close_fold" = &closeFold,
    .@"editor.unfold_all" = &unfoldAll,
    .@"editor.bracket_match" = &bracketMatch,
    .@"editor.jump_prev_edit" = &jumpPrevEdit,
    .@"editor.jump_next_edit" = &jumpNextEdit,
    .@"editor.use_vim" = &useVim,
    .@"editor.use_standard" = &useStandard,
    .@"editor.file_info" = &fileInfo,
    .@"editor.add_cursor_below" = &addCursorBelow,
    .@"editor.add_cursor_above" = &addCursorAbove,
    .@"editor.add_cursor_at_next_word" = &addCursorAtNextWord,
    .@"editor.clear_extra_cursors" = &clearExtraCursors,
    .@"editor.undo" = &undo,
    .@"editor.redo" = &redo,
    .@"editor.select_all" = &selectAll,
    .@"editor.cut" = &cut,
    .@"editor.copy" = &copy,
    .@"editor.paste" = &paste,
    .@"editor.delete_line" = &deleteLine,
    .@"editor.indent_line" = &indentLine,
    .@"editor.outdent_line" = &outdentLine,
    .@"editor.move_line_up" = &moveLineUp,
    .@"editor.move_line_down" = &moveLineDown,
    .@"editor.toggle_line_comment" = &toggleLineComment,
};

fn one(app: *App, op: EditOp) CommandError!void {
    const e = try app.requireEditor();
    _ = try app.applyOps(e, &.{op});
}

fn addCursorBelow(app: *App) CommandError!void {
    return one(app, .add_cursor_below);
}
fn addCursorAbove(app: *App) CommandError!void {
    return one(app, .add_cursor_above);
}
fn addCursorAtNextWord(app: *App) CommandError!void {
    return one(app, .add_cursor_at_next_word);
}
fn clearExtraCursors(app: *App) CommandError!void {
    return one(app, .clear_extra_cursors);
}
fn undo(app: *App) CommandError!void {
    return one(app, .undo);
}
fn redo(app: *App) CommandError!void {
    return one(app, .redo);
}
fn selectAll(app: *App) CommandError!void {
    return one(app, .select_all);
}
fn cut(app: *App) CommandError!void {
    const e = try app.requireEditor();
    _ = try app.applyOps(e, &.{if (e.buf.editor.hasSelection()) .cut_selection else .delete_line});
}
fn copy(app: *App) CommandError!void {
    const e = try app.requireEditor();
    _ = try app.applyOps(e, &.{if (e.buf.editor.hasSelection()) .yank_selection else .yank_line});
}
fn paste(app: *App) CommandError!void {
    return one(app, .paste);
}
fn deleteLine(app: *App) CommandError!void {
    return one(app, .delete_line);
}
fn indentLine(app: *App) CommandError!void {
    return one(app, .indent);
}
fn outdentLine(app: *App) CommandError!void {
    return one(app, .outdent);
}
fn moveLineUp(app: *App) CommandError!void {
    return one(app, .move_line_up);
}
fn moveLineDown(app: *App) CommandError!void {
    return one(app, .move_line_down);
}
fn toggleLineComment(app: *App) CommandError!void {
    return one(app, .toggle_line_comment);
}

fn useVim(app: *App) CommandError!void {
    try app.setInputStyle(.vim);
    app.toast("keymap: vim", .{});
}

fn useStandard(app: *App) CommandError!void {
    try app.setInputStyle(.standard);
    app.toast("keymap: standard", .{});
}

fn gotoLine(app: *App) CommandError!void {
    _ = try app.requireEditor();
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = Prompt.init(app.gpa, "Go to line"), .purpose = .goto_line } };
    app.focus = .overlay;
    app.needs_render = true;
}

fn fileInfo(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const ed = &e.buf.editor;
    const row = ed.currentLine() + 1;
    const total = ed.lineCount();
    const pct = if (total == 0) 0 else row * 100 / total;
    app.toast("{s}{s} · Ln {d}/{d} · {d}%", .{ if (e.buf.path) |p| app.relPath(p) else "[scratch]", if (e.buf.dirty) " [+]" else "", row, total, pct });
}

// ─── folds (Rust `fold_methods.rs`) ─────────────────────────────────────

const FoldAction = enum { toggle, open, close };

fn toggleFold(app: *App) CommandError!void {
    return foldAtCursor(app, .toggle);
}
fn openFold(app: *App) CommandError!void {
    return foldAtCursor(app, .open);
}
fn closeFold(app: *App) CommandError!void {
    return foldAtCursor(app, .close);
}

/// The closed fold whose range holds `row`, if any.
fn foldOwning(e: *const EditorPane, row: usize) ?usize {
    for (e.buf.folds.keys(), e.buf.folds.values()) |s, en| if (row >= s and row <= en) return s;
    return null;
}

fn foldAtCursor(app: *App, action: FoldAction) CommandError!void {
    const e = try app.requireEditor();
    const ed = &e.buf.editor;
    const row = ed.currentLine();
    if (action != .close) if (foldOwning(e, row)) |owner| {
        _ = e.buf.folds.orderedRemove(owner);
        app.toast("unfolded line {d}", .{owner + 1});
        app.needs_render = true;
        return;
    };
    if (action == .open) return;
    const best = foldRangeAt(ed, row) orelse {
        app.toast("nothing to fold here", .{});
        return;
    };
    try e.buf.folds.put(app.gpa, best[0], best[1]);
    // Keep the map sorted by start so the view walks it in order.
    e.buf.folds.sort(struct {
        keys: []const usize,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return ctx.keys[a] < ctx.keys[b];
        }
    }{ .keys = e.buf.folds.keys() });
    if (row > best[0]) ed.setCursor(ed.lineStart(best[0]));
    app.toast("folded {d} lines", .{best[1] - best[0]});
    app.needs_render = true;
}

/// The smallest multi-line bracket block around `row`: the pair that
/// encloses the cursor, or an unmatched opener on the cursor's own line
/// (vim folds the block a header line starts, not its parent).
pub fn foldRangeAt(ed: *const Editor, row: usize) ?[2]usize {
    const text = ed.bytes();
    const pairs = [_][2]u8{ .{ '{', '}' }, .{ '[', ']' }, .{ '(', ')' } };
    var best: ?[2]usize = null;
    const ls = ed.lineStart(row);
    const le = ed.lineEnd(row);
    for (pairs) |pr| {
        if (enclosingPair(text, ed.cursor, pr[0], pr[1])) |p| consider(ed, &best, p[0], p[1]);
        // Last unmatched opener on the cursor's line.
        var open_pos: ?usize = null;
        var i = ls;
        while (i < le) : (i += 1) {
            if (text[i] == pr[0]) open_pos = i else if (text[i] == pr[1] and open_pos != null) open_pos = null;
        }
        if (open_pos) |o| if (matchForward(text, o, pr[0], pr[1])) |c| consider(ed, &best, o, c);
    }
    return best;
}

fn consider(ed: *const Editor, best: *?[2]usize, open_byte: usize, close_byte: usize) void {
    const lo = ed.lineOfByte(open_byte);
    const hi = ed.lineOfByte(close_byte);
    if (hi <= lo) return;
    if (best.* == null or (best.*.?[1] - best.*.?[0]) > (hi - lo)) best.* = .{ lo, hi };
}

/// The innermost `open … close` pair with the cursor inside it.
fn enclosingPair(text: []const u8, cursor: usize, open: u8, close: u8) ?[2]usize {
    var depth: usize = 0;
    var i = @min(cursor, text.len);
    var open_byte: ?usize = null;
    while (i > 0) {
        i -= 1;
        if (text[i] == close) {
            depth += 1;
        } else if (text[i] == open) {
            if (depth == 0) {
                open_byte = i;
                break;
            }
            depth -= 1;
        }
    }
    const o = open_byte orelse return null;
    const c = matchForward(text, o, open, close) orelse return null;
    return .{ o, c };
}

fn matchForward(text: []const u8, open_byte: usize, open: u8, close: u8) ?usize {
    var depth: usize = 1;
    var i = open_byte + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == open) {
            depth += 1;
        } else if (text[i] == close) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn matchBackward(text: []const u8, close_byte: usize, open: u8, close: u8) ?usize {
    var depth: usize = 1;
    var i = close_byte;
    while (i > 0) {
        i -= 1;
        if (text[i] == close) {
            depth += 1;
        } else if (text[i] == open) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn unfoldAll(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const n = e.buf.folds.count();
    e.buf.folds.clearRetainingCapacity();
    app.toast("unfolded {d} fold(s)", .{n});
    app.needs_render = true;
}

// ─── bracket match (vim `%`) ────────────────────────────────────────────

/// Jump to the bracket paired with the one under the cursor; when the
/// cursor is not on a bracket, the first one after it on the line.
/// Silent when there is nothing to match.
fn bracketMatch(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const ed = &e.buf.editor;
    const text = ed.bytes();
    const pairs = [_][2]u8{ .{ '(', ')' }, .{ '[', ']' }, .{ '{', '}' } };
    var at = ed.cursor;
    const le = ed.lineEnd(ed.currentLine());
    while (at < le and bracketKind(text[at], &pairs) == null) at += 1;
    if (at >= le) return;
    const kind = bracketKind(text[at], &pairs).?;
    const pr = pairs[kind.idx];
    const target = if (kind.open) matchForward(text, at, pr[0], pr[1]) else matchBackward(text, at, pr[0], pr[1]);
    const dest = target orelse return;
    ed.setCursor(dest);
    ed.goal_col = null;
    app.needs_render = true;
}

fn bracketKind(c: u8, pairs: []const [2]u8) ?struct { idx: usize, open: bool } {
    for (pairs, 0..) |p, i| {
        if (c == p[0]) return .{ .idx = i, .open = true };
        if (c == p[1]) return .{ .idx = i, .open = false };
    }
    return null;
}

// ─── change list (`g;` / `g,`) ──────────────────────────────────────────

fn jumpPrevEdit(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const list = e.buf.editor.change_list.items;
    if (list.len == 0) {
        app.toast("no earlier edit", .{});
        return;
    }
    var nav: app_mod.ChangeNav = app.change_nav orelse .{ .idx = list.len, .len = list.len };
    if (nav.len != list.len) nav = .{ .idx = list.len, .len = list.len };
    if (nav.idx == 0) {
        app.toast("no earlier edit", .{});
        return;
    }
    nav.idx -= 1;
    app.change_nav = .{ .idx = nav.idx, .len = list.len };
    const pos = list[nav.idx];
    e.buf.editor.placeCursor(@min(pos.row, e.buf.editor.lineCount() - 1), pos.col);
    const now = e.buf.editor.rowCol();
    app.toast("g; → {d}:{d}", .{ now.row + 1, now.col + 1 });
    app.needs_render = true;
}

fn jumpNextEdit(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const list = e.buf.editor.change_list.items;
    const nav = app.change_nav orelse {
        app.toast("at newest edit", .{});
        return;
    };
    if (nav.len != list.len or nav.idx + 1 >= list.len) {
        app.toast("at newest edit", .{});
        return;
    }
    const idx = nav.idx + 1;
    app.change_nav = .{ .idx = idx, .len = list.len };
    const pos = list[idx];
    e.buf.editor.placeCursor(@min(pos.row, e.buf.editor.lineCount() - 1), pos.col);
    const now = e.buf.editor.rowCol();
    app.toast("g, → {d}:{d}", .{ now.row + 1, now.col + 1 });
    app.needs_render = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn appWith(text: []const u8) !App {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    errdefer app.deinit();
    _ = try app.openScratch();
    try app.activeEditor().?.buf.editor.setText(text);
    return app;
}

test "folds: toggle picks the smallest enclosing block, zo/zc are idempotent, unfold_all clears" {
    var app = try appWith("fn main() {\n    one;\n    two;\n    three;\n}\nlet end = 1;");
    defer app.deinit();
    const e = app.activeEditor().?;
    e.buf.editor.placeCursor(2, 4);
    try command.run(&app, .{ .static = .@"editor.toggle_fold" });
    try t.expectEqual(@as(usize, 1), e.buf.folds.count());
    try t.expectEqual(@as(usize, 0), e.buf.folds.keys()[0]);
    try t.expectEqual(@as(usize, 4), e.buf.folds.values()[0]);
    try t.expectEqualStrings("folded 4 lines", app.lastToast().?);
    // Closing again is a no-op; opening removes; opening twice stays open.
    try command.run(&app, .{ .static = .@"editor.close_fold" });
    try t.expectEqual(@as(usize, 1), e.buf.folds.count());
    try command.run(&app, .{ .static = .@"editor.open_fold" });
    try t.expectEqual(@as(usize, 0), e.buf.folds.count());
    try command.run(&app, .{ .static = .@"editor.open_fold" });
    try t.expectEqual(@as(usize, 0), e.buf.folds.count());
    // A header line folds its own block.
    e.buf.editor.placeCursor(0, 0);
    try command.run(&app, .{ .static = .@"editor.toggle_fold" });
    try t.expectEqual(@as(usize, 1), e.buf.folds.count());
    try command.run(&app, .{ .static = .@"editor.unfold_all" });
    try t.expectEqual(@as(usize, 0), e.buf.folds.count());
    e.buf.editor.placeCursor(5, 0);
    try command.run(&app, .{ .static = .@"editor.toggle_fold" });
    try t.expectEqualStrings("nothing to fold here", app.lastToast().?);
}

test "bracket match jumps both ways, nested pairs, and to the first bracket on the line" {
    var app = try appWith("((inner)) x\ncall(a, b)");
    defer app.deinit();
    const e = app.activeEditor().?;
    try command.run(&app, .{ .static = .@"editor.bracket_match" });
    try t.expectEqual(@as(usize, 8), e.buf.editor.cursor);
    try command.run(&app, .{ .static = .@"editor.bracket_match" });
    try t.expectEqual(@as(usize, 0), e.buf.editor.cursor);
    e.buf.editor.placeCursor(1, 1);
    try command.run(&app, .{ .static = .@"editor.bracket_match" });
    try t.expectEqual(@as(usize, 21), e.buf.editor.cursor);
    e.buf.editor.placeCursor(0, 10);
    try command.run(&app, .{ .static = .@"editor.bracket_match" });
    try t.expectEqual(@as(usize, 10), e.buf.editor.cursor);
}

test "change list: g; walks back through edits, g, forward, with the toasts the gate asserts" {
    var app = try appWith("line0\nline1\nline2\nline3\nline4\nline5\nline6");
    defer app.deinit();
    const e = app.activeEditor().?;
    e.buf.editor.placeCursor(0, 0);
    _ = try app.applyOps(e, &.{.{ .insert_char = 'X' }});
    e.buf.editor.placeCursor(5, 0);
    _ = try app.applyOps(e, &.{.{ .insert_char = 'Y' }});
    e.buf.editor.placeCursor(3, 0);
    try command.run(&app, .{ .static = .@"editor.jump_prev_edit" });
    try t.expectEqualStrings("g; → 6:2", app.lastToast().?);
    try command.run(&app, .{ .static = .@"editor.jump_prev_edit" });
    try t.expectEqualStrings("g; → 1:2", app.lastToast().?);
    try command.run(&app, .{ .static = .@"editor.jump_prev_edit" });
    try t.expectEqualStrings("no earlier edit", app.lastToast().?);
    try command.run(&app, .{ .static = .@"editor.jump_next_edit" });
    try t.expectEqualStrings("g, → 6:2", app.lastToast().?);
    try command.run(&app, .{ .static = .@"editor.jump_next_edit" });
    try t.expectEqualStrings("at newest edit", app.lastToast().?);
}

test "goto_line opens the prompt titled exactly `Go to line`" {
    var app = try appWith("a\nb\nc");
    defer app.deinit();
    try command.run(&app, .{ .static = .@"editor.goto_line" });
    try t.expect(app.overlay == .prompt);
    try t.expectEqualStrings("Go to line", app.overlay.prompt.state.title);
    try t.expect(app.focus == .overlay);
}
