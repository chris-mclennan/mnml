//! The one exhaustive switch over `EditOp` (D4). Each prong delegates to
//! its family module; a tag with no implementation yet returns
//! `error.Unsupported` with a `TODO(vim-slice: …)` naming the slice that
//! owns it. Adding a prong here never touches the handlers.

const std = @import("std");
const editor = @import("editor.zig");
const Editor = editor.Editor;
const Error = editor.Error;
const Clipboard = editor.Clipboard;
const edit_op = @import("edit_op.zig");
const EditOp = edit_op.EditOp;
const EditOutcome = edit_op.EditOutcome;
const motion = @import("motion.zig");
const insert = @import("insert.zig");
const delete = @import("delete.zig");
const select = @import("select.zig");
const line = @import("line.zig");
const register = @import("register.zig");
const undo = @import("undo.zig");
const mc = @import("multicursor.zig");
const block = @import("block.zig");
const surround = @import("surround.zig");

pub fn applyOne(ed: *Editor, op: EditOp, vp: usize, clip: *Clipboard, out: *EditOutcome) Error!void {
    switch (op) {
        // ── grouping ──
        .repeat => |r| {
            // `[count]p` is one put of the text `count` times over, not
            // `count` puts (`:help p`); the op stays a `repeat` so
            // `{count}.` can still replace the count.
            if (register.isPut(r.inner.*)) return register.putRepeated(ed, r.inner.*, r.count, clip, out);
            // `{count}dd` past the end takes what is there (`:help dd`),
            // never a line above the one it started on.
            const count: u32 = if (r.inner.* == .delete_line) @intCast(@min(r.count, @max(ed.lineCount() -| ed.currentLine(), 1))) else r.count;
            if (r.inner.isMutation() and count > 1) {
                const tok = try ed.beginAtomic();
                defer ed.endAtomic(tok);
                for (0..count) |_| try applyOne(ed, r.inner.*, vp, clip, out);
            } else {
                for (0..count) |_| try applyOne(ed, r.inner.*, vp, clip, out);
            }
        },
        .atomic => |ops| {
            const tok = try ed.beginAtomic();
            defer ed.endAtomic(tok);
            for (ops) |o| try applyOne(ed, o, vp, clip, out);
        },

        // ── motion ──
        .move_left => {
            motion.left(ed);
            try mc.moveExtras(ed, motion.left);
        },
        .move_right => {
            motion.right(ed);
            try mc.moveExtras(ed, motion.right);
        },
        .move_up => {
            motion.vertical(ed, -1);
            try mc.moveExtras(ed, motion.up);
        },
        .move_down => {
            motion.vertical(ed, 1);
            try mc.moveExtras(ed, motion.down);
        },
        .page_up => motion.page(ed, -1, vp),
        .page_down => motion.page(ed, 1, vp),
        .half_page_up => motion.page(ed, -1, vp / 2),
        .half_page_down => motion.page(ed, 1, vp / 2),
        .move_word_right => {
            motion.wordRight(ed);
            try mc.moveExtras(ed, motion.wordRight);
        },
        .move_word_right_no_cross_line => motion.wordRightNoCrossLine(ed),
        .move_right_no_cross_line => {
            motion.rightNoCrossLine(ed);
            try mc.moveExtras(ed, motion.rightNoCrossLine);
        },
        .move_left_no_cross_line => {
            motion.leftNoCrossLine(ed);
            try mc.moveExtras(ed, motion.leftNoCrossLine);
        },
        .move_word_left => {
            motion.wordLeft(ed);
            try mc.moveExtras(ed, motion.wordLeft);
        },
        .move_word_end => {
            motion.wordEnd(ed);
            try mc.moveExtras(ed, motion.wordEnd);
        },
        .move_word_end_cw => |n| motion.wordEndCw(ed, n, false),
        .move_big_word_end_cw => |n| motion.wordEndCw(ed, n, true),
        .move_word_end_back => motion.wordEndBack(ed),
        .move_big_word_right => motion.bigWordRight(ed),
        .move_big_word_right_no_cross_line => motion.bigWordRightNoCrossLine(ed),
        .move_big_word_left => motion.bigWordLeft(ed),
        .move_big_word_end => motion.bigWordEnd(ed),
        .move_big_word_end_back => motion.bigWordEndBack(ed),
        .move_line_start => {
            motion.lineStart(ed);
            try mc.moveExtras(ed, motion.lineStart);
        },
        .move_line_first_non_ws => {
            motion.lineFirstNonWs(ed);
            try mc.moveExtras(ed, motion.lineFirstNonWs);
        },
        .move_down_first_non_ws => motion.downFirstNonWs(ed),
        .move_up_first_non_ws => motion.upFirstNonWs(ed),
        .move_line_last_non_ws => motion.lineLastNonWs(ed),
        .move_paragraph => |p| motion.paragraph(ed, p.forward),
        .move_sentence => |p| motion.sentence(ed, p.forward),
        .move_line_end => {
            motion.lineEnd(ed);
            try mc.moveExtras(ed, motion.lineEnd);
        },
        .move_line_last_char => {
            motion.lineLastChar(ed);
            try mc.moveExtras(ed, motion.lineLastChar);
        },
        .move_visual_down, .move_visual_up, .move_visual_line_start, .move_visual_line_end => return error.Unsupported, // TODO(vim-slice: motions) display-row motions under wrap
        .move_buffer_start => motion.bufferStart(ed),
        .move_buffer_end => motion.bufferEnd(ed),
        .move_to_line => |n| motion.toLine(ed, n),
        .move_to_col => |n| motion.toCol(ed, n),
        .set_cursor_byte => |b| motion.setCursorByte(ed, b),
        .find_char_on_line => |f| motion.findCharOnLine(ed, f.ch, f.forward, f.before, f.inclusive, f.repeat),

        // ── selection ──
        .select_start => select.selectStart(ed),
        .select_clear => select.selectClear(ed),
        .remember_selection => ed.rememberSelection(),
        .select_line => select.selectLine(ed),
        .select_line_to_end => select.selectLineToEnd(ed),
        .select_all => select.selectAll(ed),
        .select_word, .select_inner_word => select.innerWord(ed),
        .select_around_word => select.aroundWord(ed, false),
        .select_inner_big_word => select.innerBigWord(ed),
        .select_around_big_word => select.aroundWord(ed, true),
        .select_inner_quote => |q| select.quote(ed, q, false),
        .select_around_quote => |q| select.quote(ed, q, true),
        .select_inner_smart_quote, .select_around_smart_quote => return error.Unsupported, // TODO(vim-slice: text-objects) iq / aq
        .surround_selection => |s| try surround.surroundSelection(ed, s.open, s.close, s.pad, out),
        .delete_surround => |c| try surround.deleteSurround(ed, c, out),
        .change_surround => |c| try surround.changeSurround(ed, c.from, c.to, out),
        .select_inner_bracket => |b| select.bracket(ed, b, false),
        .select_around_bracket => |b| select.bracket(ed, b, true),
        .select_inner_tag => select.tag(ed, false),
        .select_around_tag => select.tag(ed, true),
        .select_inner_paragraph => select.paragraph(ed, false),
        .select_around_paragraph => select.paragraph(ed, true),
        .select_inner_sentence => select.sentence(ed, false),
        .select_around_sentence => select.sentence(ed, true),
        .select_inner_function => select.object(ed, .function, false),
        .select_around_function => select.object(ed, .function, true),
        .select_inner_class => select.object(ed, .class, false),
        .select_around_class => select.object(ed, .class, true),
        .select_inner_argument => select.argument(ed, false),
        .select_around_argument => select.argument(ed, true),
        .select_inner_indent_block, .select_around_indent_block, .select_outer_indent_block => return error.Unsupported, // TODO(vim-slice: text-objects) ii / ai / aI
        .restore_last_selection => |shape| select.restoreLastSelection(ed, shape),
        .swap_anchor_cursor => select.swapAnchorCursor(ed),
        .move_cursor_to_selection_start => select.moveCursorToSelectionStart(ed),
        .normalize_linewise_selection => select.normalizeLinewiseSelection(ed),
        .normalize_linewise_selection_inner => select.normalizeLinewiseSelectionInner(ed),
        .make_selection_inclusive => select.makeSelectionInclusive(ed),
        .continue_insert_run => select.continueInsertRun(ed),

        // ── multi-cursor / block ──
        .add_cursor_below => try mc.addCursorBelow(ed),
        .add_cursor_above => try mc.addCursorAbove(ed),
        .clear_extra_cursors => mc.clear(ed),
        .add_cursor_at_next_word => try mc.addCursorAtNextWord(ed),
        .block_select_start => block.selectStart(ed),
        .block_select_clear => block.selectClear(ed),
        .block_eol => |v| ed.block_eol = v,
        .yank_block => try block.yankBlock(ed, clip, out),
        .delete_block => try block.deleteBlock(ed, clip, out),

        // ── insert ──
        .insert_char => |c| try insert.insertChar(ed, c, out),
        .insert_str => |s| try insert.insertStr(ed, s, out),
        .insert_char_from_line => |p| try insert.insertCharFromLine(ed, p.above, out),
        .insert_newline => try insert.insertNewline(ed, out),
        .insert_newline_below => try insert.insertNewlineBelow(ed, out),
        .insert_newline_above => try insert.insertNewlineAbove(ed, out),

        // ── delete ──
        .backspace => try delete.backspace(ed, out),
        .delete_forward => try delete.deleteForward(ed, out),
        .delete_word_left => try delete.deleteWordLeft(ed, out),
        .delete_word_right => try delete.deleteWordRight(ed, out),
        .delete_to_line_start => try delete.deleteToLineStart(ed, out),
        .delete_to_line_end => try delete.deleteToLineEnd(ed, out),
        .delete_line => try delete.deleteLine(ed, clip, out),
        .delete_selection => try delete.deleteSelection(ed, clip, out),
        .replace_selection => |s| try delete.replaceSelection(ed, s, out),
        .replace_char_at_cursor => |c| try delete.replaceCharAtCursor(ed, c, out),
        .overwrite_char_and_advance => |c| try insert.overwriteCharAndAdvance(ed, c, out),
        .replace_undo_one => try insert.replaceUndoOne(ed, out),
        .replace_session_begin => insert.replaceSessionBegin(ed),
        .replace_range => |r| try delete.replaceRange(ed, r.start, r.end, r.text, out),

        // ── line ops ──
        .indent => try line.indent(ed, out),
        .outdent => try line.outdent(ed, out),
        .indent_to_first_non_blank => try line.shiftToFirstNonBlank(ed, false, out),
        .outdent_to_first_non_blank => try line.shiftToFirstNonBlank(ed, true, out),
        .reindent => try line.reindent(ed, out),
        .toggle_line_comment => try line.toggleLineComment(ed, out),
        .move_line_up => try line.moveLine(ed, -1, out),
        .move_line_down => try line.moveLine(ed, 1, out),
        .duplicate_line => try line.duplicateLine(ed, out),
        .join_lines => |j| try line.joinLines(ed, j.keep_space, out),
        .transform_selection_case => |k| try line.transformSelectionCase(ed, k, out),
        .toggle_case_char => try line.toggleCaseChar(ed, out),
        .change_number_at_cursor => |n| try line.changeNumberAtCursor(ed, n.delta, out),
        .change_numbers_in_selection => |n| try line.changeNumbersInSelection(ed, n.delta, n.progressive, out),
        .reflow_paragraph => |r| try line.reflowParagraph(ed, r.width, out),
        .align_selection => |a| try line.alignSelection(ed, a.on_char, out),

        // ── registers ──
        .set_register_hint => |r| register.setRegisterHint(clip, r),
        .yank_line => try register.yankLine(ed, clip, out),
        .yank_lines_count => |n| try register.yankLinesCount(ed, n, clip, out),
        .yank_selection => try register.yankSelection(ed, clip, out),
        .yank_selection_linewise => try register.yankSelectionLinewise(ed, clip, out),
        .cut_selection => try delete.cutSelection(ed, clip, out),
        .paste_after => try register.pasteAfter(ed, clip, out),
        .paste_before => try register.pasteBefore(ed, clip, out),
        .paste_after_end => try register.pasteAfterEnd(ed, clip, out),
        .paste_before_end => try register.pasteBeforeEnd(ed, clip, out),
        .paste_after_indent => try register.pasteAfterIndent(ed, clip, out),
        .paste_before_indent => try register.pasteBeforeIndent(ed, clip, out),
        .paste => try register.paste(ed, clip, out),

        // ── history ──
        .undo => try undo.undoOp(ed, out),
        .redo => try undo.redoOp(ed, out),
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

fn applyAll(ed: *Editor, clip: *Clipboard, arena: std.mem.Allocator, ops: []const EditOp) !EditOutcome {
    var last: EditOutcome = .{};
    for (ops) |o| last = try ed.apply(o, 10, clip, arena);
    return last;
}

test "apply: repeat + atomic collapse to one undo step; undo/redo round-trip" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var clip = Clipboard.init(gpa);
    defer clip.deinit();
    const ed = try Editor.init(gpa, "abcdef");
    defer ed.deinit();
    _ = try ed.apply(.{ .repeat = .{ .count = 3, .inner = &.delete_forward } }, 10, &clip, arena);
    try std.testing.expectEqualStrings("def", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 1), ed.doc.history.undoLen());
    _ = try ed.apply(.undo, 10, &clip, arena);
    try std.testing.expectEqualStrings("abcdef", ed.doc.text.items);
    _ = try ed.apply(.redo, 10, &clip, arena);
    try std.testing.expectEqualStrings("def", ed.doc.text.items);
    const group = [_]EditOp{ .{ .insert_char = 'x' }, .move_left, .{ .insert_str = "yz" } };
    _ = try ed.apply(.{ .atomic = &group }, 10, &clip, arena);
    try std.testing.expectEqualStrings("yzxdef", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 2), ed.doc.history.undoLen());
    _ = try ed.apply(.undo, 10, &clip, arena);
    try std.testing.expectEqualStrings("def", ed.doc.text.items);
}

test "apply: outcome flags, text edit inference, changelist, goal col" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var clip = Clipboard.init(gpa);
    defer clip.deinit();
    const ed = try Editor.init(gpa, "ab\ncd");
    defer ed.deinit();
    var out = try ed.apply(.move_right, 10, &clip, arena);
    try std.testing.expect(out.cursor_moved and !out.buffer_changed);
    out = try ed.apply(.{ .insert_char = 'X' }, 10, &clip, arena);
    try std.testing.expect(out.buffer_changed);
    try std.testing.expectEqual(@as(usize, 1), out.text_edits.len);
    try std.testing.expectEqual(edit_op.TextEdit{ .start_byte = 1, .old_end_byte = 1, .new_end_byte = 2 }, out.text_edits[0]);
    try std.testing.expectEqual(@as(usize, 1), ed.doc.change_list.items.len);
    // Replace-range reports its explicit extent.
    out = try ed.apply(.{ .replace_range = .{ .start = 0, .end = 2, .text = "Q" } }, 10, &clip, arena);
    try std.testing.expectEqual(edit_op.TextEdit{ .start_byte = 0, .old_end_byte = 2, .new_end_byte = 1 }, out.text_edits[0]);
    // A join is not a single-extent cursor-relative edit → no hint → drop the tree.
    ed.cursor = 0;
    out = try ed.apply(.{ .join_lines = .{ .keep_space = true } }, 10, &clip, arena);
    try std.testing.expect(out.buffer_changed and out.text_edits.len == 0);
    // Goal column survives vertical motion only.
    try ed.setText("abcd\nx\nabcd");
    ed.cursor = 3;
    _ = try ed.apply(.move_down, 10, &clip, arena);
    _ = try ed.apply(.move_down, 10, &clip, arena);
    try std.testing.expectEqual(@as(usize, 10), ed.cursor);
    _ = try ed.apply(.move_left, 10, &clip, arena);
    try std.testing.expect(ed.goal_col == null);
    // Unsupported tags are reported, not silently dropped.
    try std.testing.expectError(error.Unsupported, ed.apply(.select_inner_smart_quote, 10, &clip, arena));
}

test "property: cursor stays on a boundary and text stays valid UTF-8" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var clip = Clipboard.init(gpa);
    defer clip.deinit();
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    const seed_chars = [_]u21{ 'a', 'b', ' ', '\n', 'é', '世', '(', ')', '"', '.', '\t', '😀', '_', '\n' };
    var text = std.ArrayList(u8).empty;
    defer text.deinit(gpa);
    for (0..200) |_| try insert.appendChar(&text, gpa, seed_chars[rnd.uintLessThan(usize, seed_chars.len)]);
    const ed = try Editor.init(gpa, text.items);
    defer ed.deinit();
    ed.doc.comment_token = "// ";
    const inner_ops = [_]EditOp{ .move_right, .delete_forward, .{ .insert_char = 'z' }, .move_down };
    const ops = [_]EditOp{
        .move_left,                                                             .move_right,                                            .move_up,                                                                                                        .move_down,
        .move_word_left,                                                        .move_word_right,                                       .move_word_end,                                                                                                  .move_word_end_back,
        .move_big_word_right,                                                   .move_big_word_left,                                    .move_big_word_end,                                                                                              .move_big_word_end_back,
        .move_word_right_no_cross_line,                                         .move_big_word_right_no_cross_line,                     .move_line_start,                                                                                                .move_line_end,
        .move_line_first_non_ws,                                                .move_line_last_non_ws,                                 .move_line_last_char,                                                                                            .move_down_first_non_ws,
        .move_up_first_non_ws,                                                  .{ .move_paragraph = .{ .forward = true } },            .{ .move_paragraph = .{ .forward = false } },                                                                    .{ .move_sentence = .{ .forward = true } },
        .{ .move_sentence = .{ .forward = false } },                            .move_buffer_start,                                     .move_buffer_end,                                                                                                .{ .move_to_line = 3 },
        .{ .move_to_col = 4 },                                                  .{ .set_cursor_byte = 7 },                              .page_up,                                                                                                        .page_down,
        .half_page_up,                                                          .half_page_down,                                        .{ .find_char_on_line = .{ .ch = 'a', .forward = true, .before = false, .inclusive = false, .repeat = false } }, .{ .find_char_on_line = .{ .ch = 'b', .forward = false, .before = true, .inclusive = true, .repeat = true } },
        .select_start,                                                          .select_clear,                                          .select_line,                                                                                                    .select_line_to_end,
        .select_all,                                                            .select_word,                                           .select_inner_word,                                                                                              .select_around_word,
        .select_inner_big_word,                                                 .select_around_big_word,                                .{ .select_inner_quote = '"' },                                                                                  .{ .select_around_quote = '"' },
        .{ .select_inner_bracket = '(' },                                       .{ .select_around_bracket = '(' },                      .select_inner_paragraph,                                                                                         .select_around_paragraph,
        .select_inner_tag,                                                      .select_around_tag,                                     .{ .restore_last_selection = .charwise },                                                                        .swap_anchor_cursor,
        .move_cursor_to_selection_start,                                        .normalize_linewise_selection,                          .normalize_linewise_selection_inner,                                                                             .make_selection_inclusive,
        .{ .insert_char = 'é' },
        .paste_after_indent,                                                    .paste_before_indent,                                   .{ .insert_char = '\n' },
        .{ .insert_str = "世界" },
        .{ .insert_char_from_line = .{ .above = true } },                       .insert_newline,                                        .insert_newline_below,                                                                                           .insert_newline_above,
        .backspace,                                                             .delete_forward,                                        .delete_word_left,                                                                                               .delete_word_right,
        .delete_to_line_start,                                                  .delete_to_line_end,                                    .delete_line,                                                                                                    .delete_selection,
        .{ .replace_selection = "r" },
        .{ .replace_char_at_cursor = '😀' },
        .{ .overwrite_char_and_advance = 'q' },                                 .replace_undo_one,                                      .replace_session_begin,                                                                                          .{ .replace_range = .{ .start = 2, .end = 5, .text = "x" } },
        .indent,                                                                .outdent,                                               .move_line_up,                                                                                                   .move_line_down,
        .duplicate_line,                                                        .{ .join_lines = .{ .keep_space = true } },             .{ .join_lines = .{ .keep_space = false } },                                                                     .{ .transform_selection_case = .toggle },
        .toggle_case_char,                                                      .{ .set_register_hint = 'a' },                          .yank_line,                                                                                                      .{ .yank_lines_count = 2 },
        .yank_selection,                                                        .yank_selection_linewise,                               .cut_selection,                                                                                                  .paste_after,
        .paste_before,                                                          .paste_after_end,                                       .paste_before_end,                                                                                               .paste,
        .undo,                                                                  .redo,                                                  .{ .repeat = .{ .count = 3, .inner = &inner_ops[0] } },                                                          .{ .repeat = .{ .count = 2, .inner = &inner_ops[1] } },
        .{ .repeat = .{ .count = 2, .inner = &inner_ops[2] } },                 .{ .repeat = .{ .count = 4, .inner = &inner_ops[3] } }, .{ .atomic = &inner_ops },                                                                                       .remember_selection,
        .add_cursor_below,                                                      .add_cursor_above,                                      .add_cursor_at_next_word,                                                                                        .clear_extra_cursors,
        .block_select_start,                                                    .block_select_clear,                                    .yank_block,                                                                                                     .delete_block,
        .{ .surround_selection = .{ .open = '(', .close = ')', .pad = true } }, .{ .delete_surround = '"' },                            .{ .change_surround = .{ .from = '(', .to = '[' } },                                                             .{ .delete_surround = 't' },
        .toggle_line_comment,                                                   .{ .change_number_at_cursor = .{ .delta = 3 } },        .{ .reflow_paragraph = .{ .width = 12 } },                                                                       .{ .align_selection = .{ .on_char = '(' } },
        .{ .restore_last_selection = .linewise },                               .{ .restore_last_selection = .block },                  .{ .change_numbers_in_selection = .{ .delta = -2, .progressive = true } },
    };
    for (0..3000) |_| {
        const op = ops[rnd.uintLessThan(usize, ops.len)];
        _ = try ed.apply(op, 4, &clip, arena);
        try std.testing.expect(ed.isBoundary(ed.cursor));
        try std.testing.expect(ed.cursor <= ed.len());
        if (ed.anchor) |a| try std.testing.expect(ed.isBoundary(a) and a <= ed.len());
        for (ed.extra_cursors.items, ed.extra_anchors.items) |c, a| {
            try std.testing.expect(ed.isBoundary(c) and c <= ed.len() and c != ed.cursor);
            if (a) |av| try std.testing.expect(ed.isBoundary(av) and av <= ed.len());
        }
        try std.testing.expect(std.unicode.utf8ValidateSlice(ed.doc.text.items));
        if (ed.len() > 20_000) try ed.setText("reset\n");
    }
}
