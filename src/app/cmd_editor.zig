//! `editor.*` runners: the go-to-line prompt, bracket folds, bracket
//! match, the change-list jumps, the input style switch, the plain
//! ops that only forward an `EditOp` to the active buffer, the
//! buffer-level vim commands a runner can reach (`.`, `q`, `@@`, `gi`),
//! the insert-mode `Ctrl+R` registers and keyword completion.

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
const PaneId = app_mod.PaneId;
const dispatch = @import("dispatch.zig");
const ex_verbs = @import("ex_verbs.zig");
const context_menus = @import("context_menus.zig");
const statusline = @import("../ui/statusline.zig");
const syntax = @import("syntax.zig");

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
    .@"vim.dot_repeat" = &dotRepeat,
    .@"vim.macro_toggle" = &macroToggle,
    .@"vim.macro_replay" = &macroReplay,
    .@"vim.go_to_last_insert" = &goToLastInsert,
    .@"editor.repeat_last_substitute" = &repeatLastSubstitute,
    .@"editor.insert_alt_filename" = &insertAltFilename,
    .@"editor.insert_last_search" = &insertLastSearch,
    .@"editor.insert_last_inserted" = &insertLastInserted,
    .@"editor.input_mode_menu" = &inputModeMenu,
    .@"editor.keyword_complete" = &keywordComplete,
    .@"editor.keyword_complete_back" = &keywordCompleteBack,
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
    // Esc goes back where Ctrl+G came from (the tree); Enter to the line.
    const back = app.overlayReturnFocus();
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = Prompt.init(app.gpa, title), .purpose = .goto_line, .title_owned = title, .return_focus = back } };
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
    const best = foldRangeAt(ed, foldRulesParsed(e), row) orelse {
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

/// How a file's blocks are delimited, for every fold the editor makes
/// itself (`za`, `zM`, `zj`/`zk`, the gutter chevron). Bracket pairs
/// always fold; an indentation-structured language also folds a header
/// line together with the more-indented lines under it — for Python or
/// YAML that is the only block there is.
pub const FoldRules = struct {
    indent: bool = false,
    /// The language's non-bracket blocks — `do … end`, elements,
    /// sections, `let` bindings — read off the syntax tree.
    tree: ?syntax.FoldTree = null,
};

/// Languages whose blocks are indented suites rather than bracket
/// pairs, by extension; a grammar key (a `#!/usr/bin/env python`
/// script) counts too.
const indent_block_exts = [_][]const u8{ "py", "pyi", "pyw", "yaml", "yml", "nim", "nims", "coffee" };

pub fn foldRulesFor(e: *const EditorPane) FoldRules {
    const text = e.buf.editor.bytes();
    const key = syntax.keyFor(e.buf.doc.path, text[0..@min(text.len, 256)]);
    const ext: []const u8 = if (e.buf.doc.path) |p| blk: {
        const x = std.fs.path.extension(p);
        break :blk if (x.len > 1) x[1..] else "";
    } else "";
    const tree = syntax.FoldTree.of(key, e.syntax.keptRoot());
    for (indent_block_exts) |i| {
        if (key) |k| if (std.mem.eql(u8, k, i)) return .{ .indent = true, .tree = tree };
        if (std.ascii.eqlIgnoreCase(ext, i)) return .{ .indent = true, .tree = tree };
    }
    return .{ .tree = tree };
}

/// `foldRulesFor` after bringing the tree up to the text — what a fold
/// command reads; the gutter's per-frame question keeps the cheap one.
pub fn foldRulesParsed(e: *EditorPane) FoldRules {
    _ = e.syntax.parsedRoot(e.buf.editor);
    return foldRulesFor(e);
}

/// The smallest multi-line block around `row`: the bracket pair that
/// encloses the cursor, an unmatched opener on the cursor's own line
/// (vim folds the block a header line starts, not its parent), and —
/// when the rules say so — the indented block the line heads or sits in.
pub fn foldRangeAt(ed: *const Editor, rules: FoldRules, row: usize) ?[2]usize {
    return foldRangeFrom(ed, rules, row, ed.cursor);
}

/// Does a fold START on `row`? What the gutter's hover chevron asks —
/// the same rule `editor.toggle_fold` applies, read from the line
/// itself rather than from the cursor, so the chevron never offers a
/// fold the command would refuse to make.
pub fn foldStartsAt(ed: *const Editor, rules: FoldRules, row: usize) bool {
    // The cheap half first. `foldRangeFrom`'s other candidate — the pair
    // that ENCLOSES the line's start — always opens on an earlier line,
    // so a fold can only begin here if this line has an opener nothing
    // on it closes. The whole-file scan is skipped for every line that
    // has none, which is what lets `ui.always_show_fold_arrows` ask this
    // of every visible line instead of just the hovered one.
    // An indented block likewise only starts on a line the next
    // non-blank line is indented past.
    const tree_start = if (rules.tree) |ft| ft.startingOn(row, ed.lineStart(row), ed.lineEnd(row)) != null else false;
    if (!hasUnmatchedOpener(ed, row) and !(rules.indent and headsIndentedLines(ed, row)) and !tree_start) return false;
    const r = foldRangeFrom(ed, rules, row, ed.lineStart(row)) orelse return false;
    return r[0] == row;
}

/// Does `row` end with a bracket nothing later on the line closes? One
/// pass over the line, no look past it.
fn hasUnmatchedOpener(ed: *const Editor, row: usize) bool {
    const text = ed.bytes();
    const ls = ed.lineStart(row);
    const le = ed.lineEnd(row);
    for ([_][2]u8{ .{ '{', '}' }, .{ '[', ']' }, .{ '(', ')' } }) |pr| {
        var open = false;
        var i = ls;
        while (i < le) : (i += 1) {
            if (text[i] == pr[0]) open = true else if (text[i] == pr[1] and open) open = false;
        }
        if (open) return true;
    }
    return false;
}

/// `foldRangeAt` from an explicit byte: `from` is where the search for
/// an enclosing pair starts. A fold that starts on `row` comes from the
/// unmatched opener on `row`'s own line either way.
pub fn foldRangeFrom(ed: *const Editor, rules: FoldRules, row: usize, from: usize) ?[2]usize {
    const text = ed.bytes();
    const pairs = [_][2]u8{ .{ '{', '}' }, .{ '[', ']' }, .{ '(', ')' } };
    var best: ?[2]usize = null;
    const ls = ed.lineStart(row);
    const le = ed.lineEnd(row);
    for (pairs) |pr| {
        if (enclosingPair(text, from, pr[0], pr[1])) |p| consider(ed, &best, p[0], p[1]);
        // Last unmatched opener on `row`'s own line.
        var open_pos: ?usize = null;
        var i = ls;
        while (i < le) : (i += 1) {
            if (text[i] == pr[0]) open_pos = i else if (text[i] == pr[1] and open_pos != null) open_pos = null;
        }
        if (open_pos) |o| if (matchForward(text, o, pr[0], pr[1])) |c| consider(ed, &best, o, c);
    }
    if (rules.indent) {
        if (indentBlockHeadedBy(ed, row)) |b| considerRows(&best, b);
        if (indentBlockAround(ed, row)) |b| considerRows(&best, b);
    }
    if (rules.tree) |ft| if (ft.around(from, row, ls, le)) |b| considerRows(&best, b);
    return best;
}

fn considerRows(best: *?[2]usize, b: [2]usize) void {
    if (b[1] <= b[0]) return;
    if (best.* == null or (best.*.?[1] - best.*.?[0]) > (b[1] - b[0])) best.* = b;
}

// ─── indented blocks ────────────────────────────────────────────────────

/// `row`'s indentation in columns (a tab to the next multiple of 8), or
/// null for a line that is only whitespace — blank lines belong to
/// whatever block surrounds them.
fn lineIndent(ed: *const Editor, row: usize) ?usize {
    const text = ed.bytes();
    var col: usize = 0;
    for (text[ed.lineStart(row)..ed.lineEnd(row)]) |ch| switch (ch) {
        ' ' => col += 1,
        '\t' => col = (col / 8 + 1) * 8,
        '\r' => {},
        else => return col,
    };
    return null;
}

fn nextNonBlank(ed: *const Editor, row: usize) ?usize {
    var r = row + 1;
    while (r < ed.lineCount()) : (r += 1) if (lineIndent(ed, r) != null) return r;
    return null;
}

/// Is the next non-blank line after `row` indented past it?
fn headsIndentedLines(ed: *const Editor, row: usize) bool {
    const ind = lineIndent(ed, row) orelse return false;
    const next = nextNonBlank(ed, row) orelse return false;
    return lineIndent(ed, next).? > ind;
}

/// The block `row` heads: `row` through the last non-blank line before
/// one back at `row`'s indentation or less. A header whose line leaves
/// a bracket open is that bracket's block, not an indented one — the
/// continuation lines of a call are its arguments.
fn indentBlockHeadedBy(ed: *const Editor, row: usize) ?[2]usize {
    if (!headsIndentedLines(ed, row) or hasUnmatchedOpener(ed, row)) return null;
    const ind = lineIndent(ed, row).?;
    var last = row;
    var r = row + 1;
    while (r < ed.lineCount()) : (r += 1) {
        const i = lineIndent(ed, r) orelse continue;
        if (i <= ind) break;
        last = r;
    }
    return .{ row, last };
}

/// The indented block `row` sits inside: the nearest line above that is
/// indented less, and the block it heads.
fn indentBlockAround(ed: *const Editor, row: usize) ?[2]usize {
    const ind = lineIndent(ed, row) orelse blk: {
        const next = nextNonBlank(ed, row) orelse return null;
        break :blk lineIndent(ed, next).?;
    };
    var r = row;
    while (r > 0) {
        r -= 1;
        const i = lineIndent(ed, r) orelse continue;
        if (i >= ind) continue;
        const b = indentBlockHeadedBy(ed, r) orelse return null;
        return if (row <= b[1]) b else null;
    }
    return null;
}

/// Every indented block in the file, as `(header row, last row)`.
fn appendIndentBlocks(ed: *const Editor, arena: std.mem.Allocator, out: *std.ArrayListUnmanaged([2]usize)) std.mem.Allocator.Error!void {
    var r: usize = 0;
    while (r < ed.lineCount()) : (r += 1) if (indentBlockHeadedBy(ed, r)) |b| try out.append(arena, b);
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
/// per bracket family closes every multi-line pair, then — for an
/// indentation-structured language — every indented block. The first
/// fold to claim a start line keeps it; the cursor lands on the fold
/// that swallowed it.
pub fn foldAllBrackets(app: *App) CommandError!void {
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
    const rules = foldRulesParsed(e);
    if (rules.indent or rules.tree != null) {
        var blocks: std.ArrayListUnmanaged([2]usize) = .empty;
        if (rules.indent) try appendIndentBlocks(ed, arena, &blocks);
        if (rules.tree) |ft| try ft.all(arena, &blocks);
        for (blocks.items) |b| {
            if (e.buf.editor.folds.contains(b[0])) continue;
            try e.buf.editor.folds.put(app.gpa, b[0], b[1]);
            added += 1;
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
/// — as `(first row, last row)`, innermost pairs included, and the
/// indented blocks when the rules fold those; what `zj` / `zk` step
/// between and `zM` closes. Frame arena.
pub fn allFoldRanges(ed: *const Editor, rules: FoldRules, arena: std.mem.Allocator) std.mem.Allocator.Error![]const [2]usize {
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
    if (rules.indent) try appendIndentBlocks(ed, arena, &out);
    if (rules.tree) |ft| try ft.all(arena, &out);
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
    @import("jumplist.zig").noteJumpMotion(app);
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

// ─── `.` / `q` / `@@` / `gi` from a runner ──────────────────────────────

/// The active editor with its pane id, for the buffer-level commands.
fn activeWithId(app: *App) CommandError!struct { id: PaneId, e: *EditorPane } {
    const e = try app.requireEditor();
    const id = app.active orelse return error.NoActivePane;
    return .{ .id = id, .e = e };
}

/// `vim.dot_repeat`: the buffer replays its last change, as `.` does.
fn dotRepeat(app: *App) CommandError!void {
    const a = try activeWithId(app);
    if (a.e.buf.dot == null) {
        app.toast("nothing to repeat", .{});
        return;
    }
    try dispatch.runBufferApp(app, a.id, a.e, .{ .dot_repeat = 0 });
}

/// `vim.macro_toggle` (the statusline's macro chip): idle ⇒ record into
/// the anonymous register; recording ⇒ stop and keep it.
fn macroToggle(app: *App) CommandError!void {
    const a = try activeWithId(app);
    const was = a.e.buf.isRecording();
    try dispatch.runBufferApp(app, a.id, a.e, .{ .macro_record_into = '@' });
    if (was) app.toast("macro recorded", .{}) else app.toast("recording macro · q to stop", .{});
}

/// `vim.macro_replay`: the last recorded macro, once.
fn macroReplay(app: *App) CommandError!void {
    const a = try activeWithId(app);
    const reg = app.clipboard.last_recorded orelse {
        app.toast("no macro to replay", .{});
        return;
    };
    if (app.clipboard.macro(reg) == null) {
        app.toast("no macro to replay", .{});
        return;
    }
    try dispatch.runBufferApp(app, a.id, a.e, .{ .macro_replay_from = .{ .reg = '@', .count = 1, .recorded = true } });
}

/// `gi`: back to where the last change ended, in Insert.
fn goToLastInsert(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const list = e.buf.doc.change_list.items;
    if (list.len == 0) {
        app.toast("no recent edit", .{});
        return;
    }
    // Where typing stopped (`'^`); a buffer changed only by other means
    // falls back to its last change.
    const pos = e.buf.doc.last_insert orelse list[list.len - 1];
    const ed = e.buf.editor;
    ed.placeCursor(@min(pos.row, ed.lineCount() - 1), pos.col);
    ed.anchor = null;
    e.buf.input.requestInsertMode();
    app.needs_render = true;
}

/// `&`: the last `:s` again on the cursor's line.
fn repeatLastSubstitute(app: *App) CommandError!void {
    return ex_verbs.ampersand(app, null, "", false);
}

// ─── insert-mode `Ctrl+R #` / `/` / `.` ─────────────────────────────────

/// The `ctrl+r`-family inserts: into the `:` line while it is open,
/// otherwise into the buffer at the cursor (`cmd_app.zig` has the
/// same seam for `%`, `:` and the word registers).
fn insertText(app: *App, e: *EditorPane, text: []const u8) CommandError!void {
    if (e.buf.input.isCmdlineOpen()) return dispatch.cmdlineInsert(app, e, text);
    try app.splice(e, e.buf.editor.cursor, e.buf.editor.cursor, text);
}

/// The alternate file (`:b#`'s pane): the most recently used other
/// pane that is an editor with a path.
fn alternatePath(app: *App) ?[]const u8 {
    for (app.pane_mru.items) |id| {
        if (app.active == id) continue;
        const other = app.panes.editor(id) orelse continue;
        if (other.buf.doc.path) |p| return p;
    }
    return null;
}

fn insertAltFilename(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const arena = app.frame.allocator();
    const path = alternatePath(app) orelse return app.diag.fail(arena, "E23: no alternate file", .{});
    return insertText(app, e, try arena.dupe(u8, app.relPath(path)));
}

/// `Ctrl+R /`: the editor's live query, else the last accepted one.
fn insertLastSearch(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const arena = app.frame.allocator();
    const q: []const u8 = if (e.find.query.items.len > 0) e.find.query.items else app.find_history.getLastOrNull() orelse return app.diag.fail(arena, "no previous search", .{});
    return insertText(app, e, try arena.dupe(u8, q));
}

/// `Ctrl+R .`: what the last Insert session typed.
fn insertLastInserted(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const arena = app.frame.allocator();
    const text = e.buf.lastInserted() orelse "";
    if (text.len == 0) return app.diag.fail(arena, "nothing inserted yet", .{});
    return insertText(app, e, try arena.dupe(u8, text));
}

// ─── the statusline mode chip's menu ────────────────────────────────────

/// `editor.input_mode_menu`: the keymap menu, one row above the mode
/// chip; at the origin before the first frame has placed it.
fn inputModeMenu(app: *App) CommandError!void {
    var x: u16 = 0;
    var y: u16 = 0;
    for (app.hits.items.items) |h| if (h.target == .statusline_seg and h.target.statusline_seg == statusline.seg_mode) {
        x = h.rect.x;
        y = h.rect.y -| 1;
    };
    try context_menus.openModeMenu(app, x, y);
}

// ─── insert-mode `Ctrl+N` / `Ctrl+P`: keyword completion ────────────────

fn keywordComplete(app: *App) CommandError!void {
    return keywordCycle(app, false);
}
fn keywordCompleteBack(app: *App) CommandError!void {
    return keywordCycle(app, true);
}

/// A keyword byte: ASCII alphanumerics, `_`, and anything non-ASCII.
fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn addDistinct(gpa: Allocator, list: *std.ArrayListUnmanaged([]u8), word: []const u8) Allocator.Error!void {
    for (list.items) |w| if (std.mem.eql(u8, w, word)) return;
    const owned = try gpa.dupe(u8, word);
    errdefer gpa.free(owned);
    try list.append(gpa, owned);
}

/// The first press completes the keyword before the cursor with the
/// nearest word extending it — after the cursor first for `Ctrl+N`,
/// before it for `Ctrl+P`, wrapping round the buffer. A press that
/// finds the buffer where the last one left it steps to the next
/// candidate, `Ctrl+P` back, and past the last one to the bare prefix.
fn keywordCycle(app: *App, back: bool) CommandError!void {
    const arena = app.frame.allocator();
    const e = try app.requireEditor();
    const id = app.active orelse return error.NoActivePane;
    const ed = e.buf.editor;
    if (app.keyword_complete) |*st| {
        if (st.pane == id and st.cursor == ed.cursor and st.len == ed.len()) {
            const n = st.candidates.len + 1;
            st.idx = (st.idx + if (back == st.back) 1 else n - 1) % n;
            const from = st.prefix[1];
            const tail: []const u8 = if (st.idx < st.candidates.len) st.candidates[st.idx][st.prefix[1] - st.prefix[0] ..] else "";
            try app.splice(e, from, from + st.inserted, tail);
            st.inserted = tail.len;
            st.cursor = ed.cursor;
            st.len = ed.len();
            if (st.idx < st.candidates.len) app.toast("{s} ({d}/{d})", .{ st.candidates[st.idx], st.idx + 1, st.candidates.len }) else app.toast("back to original", .{});
            return;
        }
        st.deinit(app.gpa);
        app.keyword_complete = null;
    }
    const text = ed.bytes();
    const cur = ed.cursor;
    var start = cur;
    while (start > 0 and isWordByte(text[start - 1])) start -= 1;
    if (start == cur) return app.diag.fail(arena, "no keyword before the cursor", .{});
    const prefix = text[start..cur];
    // The words extending the prefix, in text order, split at the cursor.
    var before: std.ArrayListUnmanaged([]const u8) = .empty;
    var after: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (!isWordByte(text[i])) {
            i += 1;
            continue;
        }
        const s = i;
        while (i < text.len and isWordByte(text[i])) i += 1;
        // The word being typed is not its own completion.
        if (s == start) continue;
        const w = text[s..i];
        if (w.len <= prefix.len or !std.mem.startsWith(u8, w, prefix)) continue;
        try (if (s < start) &before else &after).append(arena, w);
    }
    var ordered: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (ordered.items) |w| app.gpa.free(w);
        ordered.deinit(app.gpa);
    }
    if (back) {
        var k = before.items.len;
        while (k > 0) : (k -= 1) try addDistinct(app.gpa, &ordered, before.items[k - 1]);
        k = after.items.len;
        while (k > 0) : (k -= 1) try addDistinct(app.gpa, &ordered, after.items[k - 1]);
    } else {
        for (after.items) |w| try addDistinct(app.gpa, &ordered, w);
        for (before.items) |w| try addDistinct(app.gpa, &ordered, w);
    }
    if (ordered.items.len == 0) {
        app.toast("no match", .{});
        return;
    }
    const prefix_len = prefix.len;
    const first = ordered.items[0][prefix_len..];
    try app.splice(e, cur, cur, first);
    app.keyword_complete = .{
        .pane = id,
        .prefix = .{ start, cur },
        .candidates = try ordered.toOwnedSlice(app.gpa),
        .idx = 0,
        .inserted = first.len,
        .back = back,
        .cursor = ed.cursor,
        .len = ed.len(),
    };
    app.toast("{s} (1/{d})", .{ app.keyword_complete.?.candidates[0], app.keyword_complete.?.candidates.len });
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

test "foldStartsAt answers for the line, not the cursor — what the gutter's chevron asks" {
    var app = try appWith("fn main() {\n    if x {\n        one;\n    }\n}\nlet end = 1;");
    defer app.deinit();
    const ed = app.activeEditor().?.buf.editor;
    // The cursor deep inside the nested block does not change the
    // answer for any other line: only the two header lines start a fold.
    ed.placeCursor(2, 8);
    try t.expect(foldStartsAt(ed, .{}, 0));
    try t.expect(foldStartsAt(ed, .{}, 1));
    try t.expect(!foldStartsAt(ed, .{}, 2));
    try t.expect(!foldStartsAt(ed, .{}, 3));
    try t.expect(!foldStartsAt(ed, .{}, 4));
    try t.expect(!foldStartsAt(ed, .{}, 5));
    // And the answer is the command's: folding line 1 gives 1..3.
    ed.placeCursor(1, 0);
    try command.run(&app, .{ .static = .@"editor.toggle_fold" });
    try t.expectEqual(@as(usize, 1), app.activeEditor().?.buf.editor.folds.keys()[0]);
    try t.expectEqual(@as(usize, 3), app.activeEditor().?.buf.editor.folds.values()[0]);
}

test "a line whose brackets all close on it starts no fold — foldStartsAt's cheap half" {
    var app = try appWith("let v = f(1);\nfn one() {}\nfn two() {\n    a();\n}\nlet end = 1;");
    defer app.deinit();
    const ed = app.activeEditor().?.buf.editor;
    // A call whose `(` closes on the line, and a body whose `{}` does
    // too: neither can start a fold, and neither pays for a scan of the
    // file to learn it.
    try t.expect(!foldStartsAt(ed, .{}, 0));
    try t.expect(!foldStartsAt(ed, .{}, 1));
    // The one line with an opener nothing on it closes does start one.
    try t.expect(foldStartsAt(ed, .{}, 2));
    try t.expect(!foldStartsAt(ed, .{}, 3));
    try t.expect(!foldStartsAt(ed, .{}, 5));
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

test "Python folds on its indented suites: a def or class folds its body, a bracket inside still folds as a bracket" {
    const py =
        \\class Holder:
        \\    def one(self):
        \\        a = 1
        \\
        \\        return a
        \\
        \\    def two(self):
        \\        x = {
        \\            "k": 1,
        \\        }
        \\        return x
        \\top = 1
        \\
    ;
    var app = try appWith(py);
    defer app.deinit();
    const e = app.activeEditor().?;
    try e.buf.setPath("/tmp/mnml-zig-fold-test.py");
    const ed = e.buf.editor;
    const rules = foldRulesFor(e);
    try t.expect(rules.indent);
    // A body line folds the def it sits in, blank lines inside included,
    // the trailing blank line before the next def not.
    ed.placeCursor(2, 8);
    try command.run(&app, .{ .static = .@"editor.toggle_fold" });
    try t.expectEqualSlices(usize, &.{1}, ed.folds.keys());
    try t.expectEqualSlices(usize, &.{4}, ed.folds.values());
    try t.expectEqualStrings("folded 3 lines", app.lastToast().?);
    try command.run(&app, .{ .static = .@"editor.unfold_all" });
    // A header folds its own block; the class header folds the class.
    try t.expectEqual(@as(?[2]usize, .{ 6, 10 }), foldRangeFrom(ed, rules, 6, ed.lineStart(6)));
    try t.expectEqual(@as(?[2]usize, .{ 0, 10 }), foldRangeFrom(ed, rules, 0, ed.lineStart(0)));
    // Inside the dict the bracket pair is the smaller block; the dict's
    // own opener line is the bracket's, not an indented header.
    try t.expectEqual(@as(?[2]usize, .{ 7, 9 }), foldRangeFrom(ed, rules, 8, ed.lineStart(8) + 12));
    try t.expectEqual(@as(?[2]usize, .{ 7, 9 }), foldRangeFrom(ed, rules, 7, ed.lineStart(7)));
    try t.expectEqual(@as(?[2]usize, null), foldRangeFrom(ed, rules, 11, ed.lineStart(11)));
    // The gutter's chevron offers exactly the header lines.
    for (0..12) |r| try t.expectEqual(r == 0 or r == 1 or r == 6 or r == 7, foldStartsAt(ed, rules, r));
    // `zM`: the dict, then every indented block.
    ed.placeCursor(2, 8);
    try command.run(&app, .{ .static = .@"editor.fold_all_brackets" });
    try t.expectEqualSlices(usize, &.{ 0, 1, 6, 7 }, ed.folds.keys());
    try t.expectEqualSlices(usize, &.{ 10, 4, 10, 9 }, ed.folds.values());
    try t.expectEqualStrings("folded 4 block(s)", app.lastToast().?);
    try t.expectEqual(@as(usize, 0), ed.currentLine());
    // `zj` / `zk` see the same blocks.
    const all = try allFoldRanges(ed, rules, app.frame.allocator());
    try t.expectEqual(@as(usize, 4), all.len);
    // A brace language keeps its bracket-only rules: the same text as
    // Rust has nothing to fold on a body line.
    try command.run(&app, .{ .static = .@"editor.unfold_all" });
    try e.buf.setPath("/tmp/mnml-zig-fold-test.rs");
    try t.expect(!foldRulesFor(e).indent);
    ed.placeCursor(2, 8);
    try command.run(&app, .{ .static = .@"editor.toggle_fold" });
    try t.expectEqualStrings("nothing to fold here", app.lastToast().?);
}

test "indent folds: tabs, a comment at its indent, and a YAML mapping" {
    var app = try appWith("a:\n  b: 1\n  c:\n    - x\n    - y\nd: 2\n");
    defer app.deinit();
    const e = app.activeEditor().?;
    try e.buf.setPath("/tmp/mnml-zig-fold-test.yaml");
    const ed = e.buf.editor;
    const rules = foldRulesFor(e);
    try t.expect(rules.indent);
    try t.expectEqual(@as(?[2]usize, .{ 0, 4 }), foldRangeFrom(ed, rules, 1, ed.lineStart(1)));
    try t.expectEqual(@as(?[2]usize, .{ 2, 4 }), foldRangeFrom(ed, rules, 3, ed.lineStart(3)));
    try t.expectEqual(@as(?[2]usize, null), foldRangeFrom(ed, rules, 5, ed.lineStart(5)));
    try ed.setText("if x:\n\tone()\n\t# note\n\ttwo()\nend()\n");
    try e.buf.setPath("/tmp/mnml-zig-fold-test.py");
    try t.expectEqual(@as(?[2]usize, .{ 0, 3 }), foldRangeFrom(ed, rules, 2, ed.lineStart(2)));
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
    // Each change is AT the typed character (Neovim's `g;`), col 1.
    try t.expectEqualStrings("g; → 6:1", app.lastToast().?);
    try command.run(&app, .{ .static = .@"editor.jump_prev_edit" });
    try t.expectEqualStrings("g; → 1:1", app.lastToast().?);
    try command.run(&app, .{ .static = .@"editor.jump_prev_edit" });
    try t.expectEqualStrings("no earlier edit", app.lastToast().?);
    try command.run(&app, .{ .static = .@"editor.jump_next_edit" });
    try t.expectEqualStrings("g, → 6:1", app.lastToast().?);
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

test "goto_line reads VS Code's forms: `-1` is the last line, `2,4` line 2 column 4; Esc goes back to the tree it came from, Enter to the line" {
    var app = try appWith("a\nbbbbbb\nc\nd");
    defer app.deinit();
    const e = app.activeEditor().?;
    const Case = struct { in: []const u8, row: usize, col: usize };
    for ([_]Case{ .{ .in = "-1", .row = 3, .col = 0 }, .{ .in = "2,4", .row = 1, .col = 3 }, .{ .in = "2:5", .row = 1, .col = 4 }, .{ .in = "-9", .row = 0, .col = 0 }, .{ .in = "99", .row = 3, .col = 0 } }) |c| {
        try command.run(&app, .{ .static = .@"editor.goto_line" });
        for (c.in) |ch| try dispatch.key(&app, Key.char(ch));
        try dispatch.key(&app, Key.named(.enter));
        try t.expectEqual(c.row, e.buf.editor.rowCol().row);
        try t.expectEqual(c.col, e.buf.editor.rowCol().col);
    }
    app.focus = .tree;
    try command.run(&app, .{ .static = .@"editor.goto_line" });
    try dispatch.key(&app, Key.named(.esc));
    try t.expect(app.focus == .tree);
    try command.run(&app, .{ .static = .@"editor.goto_line" });
    try dispatch.key(&app, Key.char('2'));
    try dispatch.key(&app, Key.named(.enter));
    try t.expect(app.focus == .pane);
    // A picker opened from the tree goes back there on Esc too.
    app.focus = .tree;
    try command.run(&app, .{ .static = .palette });
    try t.expect(app.overlay == .picker);
    try dispatch.key(&app, Key.named(.esc));
    try t.expect(app.focus == .tree);
}

const buffer_mod = @import("../editor/buffer.zig");
const Key = app_mod.Key;

/// Keys in `buffer.parseKeys` notation, through the app's own dispatch.
fn feed(app: *App, spec: []const u8) !void {
    const keys = try buffer_mod.parseKeys(t.allocator, spec);
    defer t.allocator.free(keys);
    for (keys) |k| try dispatch.key(app, k);
}

fn realRoot(tmp: *std.testing.TmpDir, gpa: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}

test "vim.dot_repeat, vim.macro_toggle and vim.macro_replay reach the buffer from a runner, and the handler's `q` stays in step" {
    var app = try appWith("alpha\nbravo\ncharlie");
    defer app.deinit();
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    const e = app.activeEditor().?;
    try command.run(&app, .{ .static = .@"vim.dot_repeat" });
    try t.expectEqualStrings("nothing to repeat", app.lastToast().?);
    try feed(&app, "iX<esc>j0");
    try command.run(&app, .{ .static = .@"vim.dot_repeat" });
    try t.expectEqualStrings("Xalpha\nXbravo\ncharlie", e.buf.editor.bytes());
    // A macro started and stopped by the runner keeps every key typed
    // between (no `q` to drop), and replays from the runner.
    try command.run(&app, .{ .static = .@"vim.macro_replay" });
    try t.expectEqualStrings("no macro to replay", app.lastToast().?);
    try command.run(&app, .{ .static = .@"vim.macro_toggle" });
    try t.expectEqualStrings("recording macro · q to stop", app.lastToast().?);
    try t.expect(e.buf.isRecording());
    try feed(&app, "A!<esc>j0");
    try command.run(&app, .{ .static = .@"vim.macro_toggle" });
    try t.expectEqualStrings("macro recorded", app.lastToast().?);
    try t.expect(!e.buf.isRecording());
    try t.expectEqualStrings("A!<esc>j0", app.clipboard.macro('@').?);
    try command.run(&app, .{ .static = .@"vim.macro_replay" });
    try t.expectEqualStrings("Xalpha\nXbravo!\ncharlie!", e.buf.editor.bytes());
    // The handler's own `q` stops a runner-started recording.
    try command.run(&app, .{ .static = .@"vim.macro_toggle" });
    try feed(&app, "xq");
    try t.expect(!e.buf.isRecording());
    try t.expectEqualStrings("x", app.clipboard.macro('@').?);
}

test "& repeats the last :s on the cursor's line; nothing to repeat is E35" {
    var app = try appWith("aa\naa");
    defer app.deinit();
    const e = app.activeEditor().?;
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"editor.repeat_last_substitute" }));
    try t.expectEqualStrings(":& — E35: no previous substitute", app.lastToast().?);
    try dispatch.runExLine(&app, "s/a/b/");
    try t.expectEqualStrings("ba\naa", e.buf.editor.bytes());
    e.buf.editor.placeCursor(1, 0);
    try command.run(&app, .{ .static = .@"editor.repeat_last_substitute" });
    try t.expectEqualStrings("ba\nba", e.buf.editor.bytes());
}

test "Ctrl+R # inserts the alternate file's workspace-relative path, into the : line while it is open; none is E23" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"editor.insert_alt_filename" }));
    try t.expectEqualStrings("E23: no alternate file", app.lastToast().?);
    for ([_][]const u8{ "a.txt", "b.txt" }) |name| {
        try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = name[0..1] });
        const path = try std.fs.path.join(t.allocator, &.{ root, name });
        defer t.allocator.free(path);
        _ = try app.openPath(path);
    }
    try command.run(&app, .{ .static = .@"editor.insert_alt_filename" });
    try t.expectEqualStrings("a.txtb", app.activeEditor().?.buf.editor.bytes());
    try feed(&app, ":");
    try command.run(&app, .{ .static = .@"editor.insert_alt_filename" });
    try t.expectEqualStrings("a.txt", app.activeEditor().?.buf.input.cmdlineGet().?);
    try t.expectEqualStrings("a.txtb", app.activeEditor().?.buf.editor.bytes());
}

test "Ctrl+R / inserts the live query, else the last accepted search; none fails" {
    var app = try appWith("text");
    defer app.deinit();
    const e = app.activeEditor().?;
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"editor.insert_last_search" }));
    try t.expectEqualStrings("no previous search", app.lastToast().?);
    try app.find_history.append(app.gpa, try app.gpa.dupe(u8, "old"));
    try command.run(&app, .{ .static = .@"editor.insert_last_search" });
    try t.expectEqualStrings("oldtext", e.buf.editor.bytes());
    try e.find.setQuery("live", e.buf.editor.bytes(), null);
    try command.run(&app, .{ .static = .@"editor.insert_last_search" });
    try t.expectEqualStrings("oldlivetext", e.buf.editor.bytes());
}

test "Ctrl+R . inserts what the last Insert session typed; none fails" {
    var app = try appWith("alpha\nbravo");
    defer app.deinit();
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    const e = app.activeEditor().?;
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"editor.insert_last_inserted" }));
    try t.expectEqualStrings("nothing inserted yet", app.lastToast().?);
    try feed(&app, "iab<bs>c<esc>jA");
    try command.run(&app, .{ .static = .@"editor.insert_last_inserted" });
    try feed(&app, "<esc>");
    try t.expectEqualStrings("acalpha\nbravoac", e.buf.editor.bytes());
}

test "editor.input_mode_menu opens the keymap menu one row above the mode chip, at the origin before a frame" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 24 });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"editor.input_mode_menu" });
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("Keymap", app.overlay.menu.title);
    try t.expectEqual(@as(u16, 0), app.overlay.menu.x);
    try t.expectEqual(@as(u16, 0), app.overlay.menu.y);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    try app.render();
    var chip: ?@import("../ui/rect.zig") = null;
    for (app.hits.items.items) |h| if (h.target == .statusline_seg and h.target.statusline_seg == statusline.seg_mode) {
        chip = h.rect;
    };
    try t.expect(chip.?.y > 0);
    try command.run(&app, .{ .static = .@"editor.input_mode_menu" });
    try t.expect(app.overlay == .menu);
    try t.expectEqual(chip.?.x, app.overlay.menu.x);
    try t.expectEqual(chip.?.y - 1, app.overlay.menu.y);
}

test "gi returns to where the last change ended, in Insert; nothing yet toasts" {
    var app = try appWith("alpha\nbravo\ncharlie");
    defer app.deinit();
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    const e = app.activeEditor().?;
    try command.run(&app, .{ .static = .@"vim.go_to_last_insert" });
    try t.expectEqualStrings("no recent edit", app.lastToast().?);
    try feed(&app, "iX<esc>G0");
    try t.expectEqual(@as(usize, 2), e.buf.editor.currentLine());
    try command.run(&app, .{ .static = .@"vim.go_to_last_insert" });
    try t.expect(e.buf.input.mode() == .insert);
    try t.expectEqual(@as(usize, 0), e.buf.editor.currentLine());
    try t.expectEqual(@as(usize, 1), e.buf.editor.colAtByte(e.buf.editor.cursor));
    try feed(&app, "Y<esc>");
    try t.expectEqualStrings("XYalpha\nbravo\ncharlie", e.buf.editor.bytes());
    // The handler's own `gi` runs the same runner.
    try feed(&app, "G0giZ<esc>");
    try t.expectEqualStrings("XYZalpha\nbravo\ncharlie", e.buf.editor.bytes());
}

test "keyword completion cycles the nearest words extending the prefix, wraps to the bare prefix, and starts over after another edit" {
    var app = try appWith("alphabet\nalpine\nx\nal");
    defer app.deinit();
    const e = app.activeEditor().?;
    const ed = e.buf.editor;
    ed.setCursor(ed.len());
    try command.run(&app, .{ .static = .@"editor.keyword_complete" });
    try t.expectEqualStrings("alphabet\nalpine\nx\nalphabet", ed.bytes());
    try t.expectEqualStrings("alphabet (1/2)", app.lastToast().?);
    try command.run(&app, .{ .static = .@"editor.keyword_complete" });
    try t.expectEqualStrings("alphabet\nalpine\nx\nalpine", ed.bytes());
    try command.run(&app, .{ .static = .@"editor.keyword_complete" });
    try t.expectEqualStrings("alphabet\nalpine\nx\nal", ed.bytes());
    try t.expectEqualStrings("back to original", app.lastToast().?);
    try command.run(&app, .{ .static = .@"editor.keyword_complete" });
    try t.expectEqualStrings("alphabet\nalpine\nx\nalphabet", ed.bytes());
    // `Ctrl+P` inside the cycle steps back.
    try command.run(&app, .{ .static = .@"editor.keyword_complete_back" });
    try t.expectEqualStrings("alphabet\nalpine\nx\nal", ed.bytes());
    try command.run(&app, .{ .static = .@"editor.keyword_complete_back" });
    try t.expectEqualStrings("alphabet\nalpine\nx\nalpine", ed.bytes());
    // Any other edit ends the cycle: the next press reads the buffer afresh.
    try app.splice(e, ed.cursor, ed.cursor, "!");
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"editor.keyword_complete" }));
    try t.expectEqualStrings("no keyword before the cursor", app.lastToast().?);
    try t.expect(app.keyword_complete == null);
    // A first `Ctrl+P` looks backward: nearest above first, then round from the bottom.
    try ed.setText("al\nalpine\nalphabet\nalp");
    ed.setCursor(2);
    try command.run(&app, .{ .static = .@"editor.keyword_complete_back" });
    try t.expectEqualStrings("alp\nalpine\nalphabet\nalp", ed.bytes());
    try command.run(&app, .{ .static = .@"editor.keyword_complete_back" });
    try t.expectEqualStrings("alphabet\nalpine\nalphabet\nalp", ed.bytes());
    // The same buffer, `Ctrl+N` first: the nearest below.
    try ed.setText("al\nalpine\nalphabet");
    ed.setCursor(2);
    try command.run(&app, .{ .static = .@"editor.keyword_complete" });
    try t.expectEqualStrings("alpine\nalpine\nalphabet", ed.bytes());
    // No word extends the prefix.
    try ed.setText("zzz\nal");
    ed.setCursor(ed.len());
    try command.run(&app, .{ .static = .@"editor.keyword_complete" });
    try t.expectEqualStrings("no match", app.lastToast().?);
    try t.expect(app.keyword_complete == null);
}

test "insert-mode Ctrl+N / Ctrl+P reach the handler's completion ahead of the vim keymap's tree toggle and file picker; Normal keeps them" {
    var app = try appWith("alphabet\nal");
    defer app.deinit();
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    const e = app.activeEditor().?;
    e.buf.editor.setCursor(e.buf.editor.len());
    const tree_before = app.tree.visible;
    try feed(&app, "a<c-n>");
    try t.expectEqualStrings("alphabet\nalphabet", e.buf.editor.bytes());
    try t.expectEqual(tree_before, app.tree.visible);
    try feed(&app, "<c-p>");
    try t.expectEqualStrings("alphabet\nal", e.buf.editor.bytes());
    try t.expect(app.overlay != .picker);
    try feed(&app, "<esc><c-n>");
    try t.expectEqual(!tree_before, app.tree.visible);
}
