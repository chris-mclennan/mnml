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
    .@"editor.fold_all_brackets" = &foldAllBrackets,
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
    .@"editor.reflow_paragraph" = &reflowParagraph,
    .@"editor.section_next_start" = &sectionNextStart,
    .@"editor.section_prev_start" = &sectionPrevStart,
    .@"editor.section_next_end" = &sectionNextEnd,
    .@"editor.section_prev_end" = &sectionPrevEnd,
    .@"editor.method_next" = &methodNext,
    .@"editor.method_prev" = &methodPrev,
    .@"project.next_todo" = &nextTodo,
    .@"project.prev_todo" = &prevTodo,
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
fn reflowParagraph(app: *App) CommandError!void {
    return one(app, .{ .reflow_paragraph = .{ .width = app.cfg.editor.text_width } });
}

// ─── `]]` `[[` `][` `[]` `]m` `[m` `]t` `[t` ──────────────────────────

/// A section starts on a line whose first char is `{` or a top-level
/// scope keyword at column 0.
fn isSectionStart(line: []const u8) bool {
    if (line.len == 0) return false;
    if (line[0] == '{') return true;
    const kws = [_][]const u8{ "fn ", "pub fn ", "class ", "struct ", "impl ", "trait ", "enum ", "def ", "function ", "async " };
    for (kws) |kw| if (std.mem.startsWith(u8, line, kw)) return true;
    return false;
}

/// A method starts on a line whose first non-blank opens a function,
/// at any indent.
fn isMethodStart(line: []const u8) bool {
    const body = std.mem.trimStart(u8, line, " \t");
    const kws = [_][]const u8{ "fn ", "pub fn ", "async fn ", "def ", "async def ", "function ", "async function ", "func ", "static fn " };
    for (kws) |kw| if (std.mem.startsWith(u8, body, kw)) return true;
    return false;
}

fn isTodoLine(line: []const u8) bool {
    const marks = [_][]const u8{ "TODO", "FIXME", "HACK", "XXX" };
    for (marks) |m| if (std.mem.indexOf(u8, line, m) != null) return true;
    return false;
}

/// Walk from the cursor's line in `dir` to the first line `pred` accepts.
/// `land_on_end` stops one line short of it (the end of the previous
/// section). Toasts `none` when nothing matches.
fn jumpToLine(app: *App, comptime pred: fn ([]const u8) bool, forward: bool, land_on_end: bool, none: []const u8) CommandError!void {
    const e = try app.requireEditor();
    const ed = e.buf.editor;
    const cur = ed.currentLine();
    const total = ed.lineCount();
    var row = cur;
    while (if (forward) row + 1 < total else row > 0) {
        row = if (forward) row + 1 else row - 1;
        if (!pred(ed.lineSlice(row))) continue;
        const target = if (!land_on_end) row else if (forward) row -| 1 else @min(row + 1, total - 1);
        ed.placeCursor(target, 0);
        ed.cursor = ed.firstNonWs(target);
        app.needs_render = true;
        return;
    }
    app.toast("{s}", .{none});
}

fn sectionNextStart(app: *App) CommandError!void {
    return jumpToLine(app, isSectionStart, true, false, "]] — no section forward");
}
fn sectionPrevStart(app: *App) CommandError!void {
    return jumpToLine(app, isSectionStart, false, false, "[[ — no section back");
}
fn sectionNextEnd(app: *App) CommandError!void {
    return jumpToLine(app, isSectionStart, true, true, "][ — no section forward");
}
fn sectionPrevEnd(app: *App) CommandError!void {
    return jumpToLine(app, isSectionStart, false, true, "[] — no section back");
}
fn methodNext(app: *App) CommandError!void {
    return jumpToLine(app, isMethodStart, true, false, "]m — no method forward");
}
fn methodPrev(app: *App) CommandError!void {
    return jumpToLine(app, isMethodStart, false, false, "[m — no method back");
}
fn nextTodo(app: *App) CommandError!void {
    return jumpToLine(app, isTodoLine, true, false, "]t — no TODO forward");
}
fn prevTodo(app: *App) CommandError!void {
    return jumpToLine(app, isTodoLine, false, false, "[t — no TODO back");
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
    const e = try app.requireEditor();
    // Rust's title names the line the cursor is on.
    const title = try std.fmt.allocPrint(app.gpa, "Go to line  (currently {d})", .{e.buf.editor.rowCol().row + 1});
    errdefer app.gpa.free(title);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = Prompt.init(app.gpa, title), .purpose = .goto_line, .title_owned = title } };
    app.focus = .overlay;
    app.needs_render = true;
}

fn fileInfo(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const ed = e.buf.editor;
    const row = ed.currentLine() + 1;
    const total = ed.lineCount();
    const pct = if (total == 0) 0 else row * 100 / total;
    app.toast("{s}{s} · Ln {d}/{d} · {d}%", .{ if (e.buf.doc.path) |p| app.relPath(p) else "[scratch]", if (e.buf.doc.dirty) " [+]" else "", row, total, pct });
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
    for (e.buf.editor.folds.keys(), e.buf.editor.folds.values()) |s, en| if (row >= s and row <= en) return s;
    return null;
}

fn foldAtCursor(app: *App, action: FoldAction) CommandError!void {
    const e = try app.requireEditor();
    const ed = e.buf.editor;
    const row = ed.currentLine();
    if (action != .close) if (foldOwning(e, row)) |owner| {
        _ = e.buf.editor.folds.orderedRemove(owner);
        app.toast("unfolded line {d}", .{owner + 1});
        app.needs_render = true;
        return;
    };
    if (action == .open) return;
    const best = foldRangeAt(ed, row) orelse {
        app.toast("nothing to fold here", .{});
        return;
    };
    try e.buf.editor.folds.put(app.gpa, best[0], best[1]);
    // Keep the map sorted by start so the view walks it in order.
    e.buf.editor.folds.sort(struct {
        keys: []const usize,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return ctx.keys[a] < ctx.keys[b];
        }
    }{ .keys = e.buf.editor.folds.keys() });
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

/// `editor.fold_all_brackets` (`zM` without a server): one stack scan
/// per bracket family closes every multi-line pair. The first fold to
/// claim a start line keeps it; the cursor lands on the fold that
/// swallowed it.
fn foldAllBrackets(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const ed = e.buf.editor;
    const text = ed.bytes();
    const arena = app.frame.allocator();
    var stack: std.ArrayListUnmanaged(usize) = .empty;
    var added: usize = 0;
    for ([_][2]u8{ .{ '{', '}' }, .{ '[', ']' }, .{ '(', ')' } }) |pr| {
        stack.clearRetainingCapacity();
        for (text, 0..) |ch, i| {
            if (ch == pr[0]) {
                try stack.append(arena, i);
            } else if (ch == pr[1]) {
                const o = stack.pop() orelse continue;
                const lo = ed.lineOfByte(o);
                const hi = ed.lineOfByte(i);
                if (hi <= lo or e.buf.editor.folds.contains(lo)) continue;
                try e.buf.editor.folds.put(app.gpa, lo, hi);
                added += 1;
            }
        }
    }
    if (added == 0) {
        app.toast("nothing to fold", .{});
        return;
    }
    e.buf.editor.folds.sort(struct {
        keys: []const usize,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return ctx.keys[a] < ctx.keys[b];
        }
    }{ .keys = e.buf.editor.folds.keys() });
    if (foldOwning(e, ed.currentLine())) |owner| if (ed.currentLine() > owner) ed.setCursor(ed.lineStart(owner));
    app.toast("folded {d} block(s)", .{added});
    app.needs_render = true;
}

/// Every bracket block spanning more than one line — `{}`, `[]`, `()`
/// — as `(first row, last row)`, innermost pairs included; what `zj` /
/// `zk` step between and `zM` closes. Frame arena.
pub fn allFoldRanges(ed: *const Editor, arena: std.mem.Allocator) std.mem.Allocator.Error![]const [2]usize {
    const text = ed.bytes();
    var stack: std.ArrayListUnmanaged(usize) = .empty;
    var out: std.ArrayListUnmanaged([2]usize) = .empty;
    for ([_][2]u8{ .{ '{', '}' }, .{ '[', ']' }, .{ '(', ')' } }) |pr| {
        stack.clearRetainingCapacity();
        for (text, 0..) |ch, i| {
            if (ch == pr[0]) {
                try stack.append(arena, i);
            } else if (ch == pr[1]) {
                const o = stack.pop() orelse continue;
                const lo = ed.lineOfByte(o);
                const hi = ed.lineOfByte(i);
                if (hi > lo) try out.append(arena, .{ lo, hi });
            }
        }
    }
    return out.items;
}

fn unfoldAll(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const n = e.buf.editor.folds.count();
    e.buf.editor.folds.clearRetainingCapacity();
    app.toast("unfolded {d} fold(s)", .{n});
    app.needs_render = true;
}

// ─── bracket match (vim `%`) ────────────────────────────────────────────

/// Jump to the bracket paired with the one under the cursor; when the
/// cursor is not on a bracket, the first one after it on the line.
/// Silent when there is nothing to match.
fn bracketMatch(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const ed = e.buf.editor;
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
    const list = e.buf.doc.change_list.items;
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
    const list = e.buf.doc.change_list.items;
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

test "fold_all_brackets closes every multi-line pair once, outermost first per start line, and parks the cursor on its fold" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.editor.setText("fn a() {\n  x = [\n    1,\n  ];\n}\nfn b(\n  y,\n) {}\nz = (1)\n");
    e.buf.editor.setCursor(e.buf.editor.lineStart(2));
    try command.run(&app, .{ .static = .@"editor.fold_all_brackets" });
    // `{…}` 0–4, `[…]` 1–3, `(…)` 5–7; `(1)` is one line.
    try t.expectEqualSlices(usize, &.{ 0, 1, 5 }, e.buf.editor.folds.keys());
    try t.expectEqualSlices(usize, &.{ 4, 3, 7 }, e.buf.editor.folds.values());
    try t.expectEqualStrings("folded 3 block(s)", app.lastToast().?);
    try t.expectEqual(@as(usize, 0), e.buf.editor.currentLine());
    // Again: nothing new.
    try command.run(&app, .{ .static = .@"editor.fold_all_brackets" });
    try t.expectEqualStrings("nothing to fold", app.lastToast().?);
    try t.expectEqual(@as(usize, 3), e.buf.editor.folds.count());
}

test "folds: toggle picks the smallest enclosing block, zo/zc are idempotent, unfold_all clears" {
    var app = try appWith("fn main() {\n    one;\n    two;\n    three;\n}\nlet end = 1;");
    defer app.deinit();
    const e = app.activeEditor().?;
    e.buf.editor.placeCursor(2, 4);
    try command.run(&app, .{ .static = .@"editor.toggle_fold" });
    try t.expectEqual(@as(usize, 1), e.buf.editor.folds.count());
    try t.expectEqual(@as(usize, 0), e.buf.editor.folds.keys()[0]);
    try t.expectEqual(@as(usize, 4), e.buf.editor.folds.values()[0]);
    try t.expectEqualStrings("folded 4 lines", app.lastToast().?);
    // Closing again is a no-op; opening removes; opening twice stays open.
    try command.run(&app, .{ .static = .@"editor.close_fold" });
    try t.expectEqual(@as(usize, 1), e.buf.editor.folds.count());
    try command.run(&app, .{ .static = .@"editor.open_fold" });
    try t.expectEqual(@as(usize, 0), e.buf.editor.folds.count());
    try command.run(&app, .{ .static = .@"editor.open_fold" });
    try t.expectEqual(@as(usize, 0), e.buf.editor.folds.count());
    // A header line folds its own block.
    e.buf.editor.placeCursor(0, 0);
    try command.run(&app, .{ .static = .@"editor.toggle_fold" });
    try t.expectEqual(@as(usize, 1), e.buf.editor.folds.count());
    try command.run(&app, .{ .static = .@"editor.unfold_all" });
    try t.expectEqual(@as(usize, 0), e.buf.editor.folds.count());
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

test "section, method and TODO jumps walk the file both ways and toast at the ends" {
    var app = try appWith("use x;\n\nfn a() {\n    fn inner() {}\n    // TODO one\n}\n\nstruct B;\n    def m():\n        pass\n");
    defer app.deinit();
    const e = app.activeEditor().?;
    try command.run(&app, .{ .static = .@"editor.section_next_start" });
    try t.expectEqual(@as(usize, 2), e.buf.editor.currentLine());
    try command.run(&app, .{ .static = .@"editor.section_next_start" });
    try t.expectEqual(@as(usize, 7), e.buf.editor.currentLine());
    try command.run(&app, .{ .static = .@"editor.section_next_start" });
    try t.expectEqualStrings("]] — no section forward", app.lastToast().?);
    try command.run(&app, .{ .static = .@"editor.section_prev_end" });
    try t.expectEqual(@as(usize, 3), e.buf.editor.currentLine());
    try command.run(&app, .{ .static = .@"editor.section_prev_start" });
    try t.expectEqual(@as(usize, 2), e.buf.editor.currentLine());
    try command.run(&app, .{ .static = .@"editor.method_next" });
    try t.expectEqual(@as(usize, 3), e.buf.editor.currentLine());
    try t.expectEqual(@as(usize, 4), e.buf.editor.colAtByte(e.buf.editor.cursor));
    try command.run(&app, .{ .static = .@"editor.method_next" });
    try t.expectEqual(@as(usize, 8), e.buf.editor.currentLine());
    try command.run(&app, .{ .static = .@"editor.method_prev" });
    try command.run(&app, .{ .static = .@"editor.method_prev" });
    try t.expectEqual(@as(usize, 2), e.buf.editor.currentLine());
    try command.run(&app, .{ .static = .@"project.next_todo" });
    try t.expectEqual(@as(usize, 4), e.buf.editor.currentLine());
    try command.run(&app, .{ .static = .@"project.next_todo" });
    try t.expectEqualStrings("]t — no TODO forward", app.lastToast().?);
    try command.run(&app, .{ .static = .@"project.prev_todo" });
    try t.expectEqualStrings("[t — no TODO back", app.lastToast().?);
}

test "goto_line opens the prompt titled exactly `Go to line`" {
    var app = try appWith("a\nb\nc");
    defer app.deinit();
    try command.run(&app, .{ .static = .@"editor.goto_line" });
    try t.expect(app.overlay == .prompt);
    try t.expectEqualStrings("Go to line  (currently 1)", app.overlay.prompt.state.title);
    try t.expect(app.focus == .overlay);
}
