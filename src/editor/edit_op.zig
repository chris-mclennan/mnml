//! `EditOp` — every text-editing intent an input handler can express
//! (D4). 139 tags. The editor applies them through one exhaustive
//! switch in `apply.zig`; nothing else mutates buffer text.
//!
//! Payload slices (`insert_str`, `replace_selection`, `replace_range.text`)
//! and the recursive `repeat.inner` / `atomic` point into the FRAME arena.
//! The two cross-iteration holders — dot-repeat and macro registers — call
//! `dupe(gpa)` / `free(gpa)`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const CaseTransform = enum { lower, upper, toggle };

/// How `gv` re-selects the remembered range: the Visual mode it was
/// made in (`:help gv`).
pub const SelectionShape = enum { charwise, linewise, block };

pub const EditOp = union(enum) {
    // ── motion ──
    move_left,
    move_right,
    move_up,
    move_down,
    move_word_left,
    move_word_right,
    move_word_right_no_cross_line,
    /// `l` / `h` as operator targets (`x` = `dl`): stop at the line's
    /// ends instead of crossing the `\n`.
    move_right_no_cross_line,
    move_left_no_cross_line,
    move_word_end,
    /// `cw` / `cW` for `n` words (`:help cw`): the end of the current
    /// word — staying when already there — then `e` for the rest; on a
    /// blank, a `w`. Lands one char short so the caller's inclusive
    /// `move_right` covers the target.
    move_word_end_cw: u32,
    move_big_word_end_cw: u32,
    move_word_end_back,
    move_big_word_right,
    move_big_word_right_no_cross_line,
    move_big_word_left,
    move_big_word_end,
    move_big_word_end_back,
    move_line_start,
    move_line_first_non_ws,
    move_down_first_non_ws,
    move_up_first_non_ws,
    move_line_last_non_ws,
    move_paragraph: struct { forward: bool },
    move_sentence: struct { forward: bool },
    move_line_end,
    move_line_last_char,
    /// Display-row motions; the payload is the wrap width (0 = no wrap).
    move_visual_down: usize,
    move_visual_up: usize,
    move_visual_line_start: usize,
    move_visual_line_end: usize,
    move_buffer_start,
    move_buffer_end,
    /// 1-based line (`3G`); 0 and 1 both mean the first line.
    move_to_line: usize,
    /// 1-based column in chars (`5|`).
    move_to_col: usize,
    set_cursor_byte: usize,
    page_up,
    page_down,
    half_page_up,
    half_page_down,

    // ── selection ──
    select_start,
    select_clear,
    remember_selection,
    select_line,
    select_line_to_end,
    select_all,
    select_word,
    select_inner_word,
    select_around_word,
    select_inner_big_word,
    select_around_big_word,
    select_inner_quote: u21,
    select_around_quote: u21,
    select_inner_smart_quote,
    select_around_smart_quote,
    /// `pad`: a space inside each delimiter (vim-surround's opener form).
    surround_selection: struct { open: u21, close: u21, pad: bool = false },
    delete_surround: u21,
    change_surround: struct { from: u21, to: u21 },
    select_inner_bracket: u21,
    select_around_bracket: u21,
    select_inner_tag,
    select_around_tag,
    select_inner_paragraph,
    select_around_paragraph,
    /// `is` / `as` (`:help is`): the sentence under the cursor — up to
    /// a `.` `!` `?` followed by white space, or the paragraph's edge;
    /// `as` takes the white space after it (before it, when none follows).
    select_inner_sentence,
    select_around_sentence,
    select_inner_function,
    select_around_function,
    select_inner_class,
    select_around_class,
    select_inner_argument,
    select_around_argument,
    select_inner_indent_block,
    select_around_indent_block,
    select_outer_indent_block,
    restore_last_selection: SelectionShape,
    swap_anchor_cursor,
    move_cursor_to_selection_start,
    normalize_linewise_selection,
    /// `V…c`: the same lines, the last one's `\n` left out — so a
    /// replace keeps one (empty) line where they were, as `cc` does.
    normalize_linewise_selection_inner,
    make_selection_inclusive,
    continue_insert_run,
    find_char_on_line: struct { ch: u21, forward: bool, before: bool, inclusive: bool, repeat: bool },

    // ── multi-cursor / block ──
    add_cursor_below,
    add_cursor_above,
    clear_extra_cursors,
    add_cursor_at_next_word,
    block_select_start,
    block_select_clear,
    /// `$` in V-BLOCK: the rectangle runs to every line's end (`:help
    /// v_$`); false again after a horizontal motion.
    block_eol: bool,
    yank_block,
    delete_block,

    // ── insert ──
    insert_char: u21,
    insert_str: []const u8,
    insert_char_from_line: struct { above: bool },
    insert_newline,
    insert_newline_below,
    insert_newline_above,

    // ── delete ──
    backspace,
    delete_forward,
    delete_word_left,
    delete_word_right,
    delete_to_line_start,
    delete_to_line_end,
    delete_line,
    delete_selection,
    replace_selection: []const u8,
    replace_char_at_cursor: u21,
    overwrite_char_and_advance: u21,
    replace_undo_one,
    replace_session_begin,
    replace_range: struct { start: usize, end: usize, text: []const u8 },

    // ── line ops ──
    indent,
    outdent,
    /// vim `>` / `<`: the selected lines (or the cursor's) shifted, the
    /// cursor on the range's first line at its first non-blank
    /// (`:help >>`) — where `indent` keeps the cursor's (row, col).
    indent_to_first_non_blank,
    outdent_to_first_non_blank,
    /// `=`: the selected lines (or the cursor's) re-indented by the
    /// buffer's brace rules.
    reindent,
    toggle_line_comment,
    move_line_up,
    move_line_down,
    duplicate_line,
    join_lines: struct { keep_space: bool },
    transform_selection_case: CaseTransform,
    toggle_case_char,
    change_number_at_cursor: struct { delta: i64 },
    /// `v_CTRL-A` / `v_CTRL-X`: the first number on every selected line;
    /// `progressive` (`v_g_CTRL-A`) adds `delta`, then 2×, 3×…
    change_numbers_in_selection: struct { delta: i64, progressive: bool },
    reflow_paragraph: struct { width: usize },
    align_selection: struct { on_char: u21 },

    // ── registers / clipboard ──
    set_register_hint: ?u21,
    yank_line,
    yank_lines_count: u32,
    yank_selection,
    yank_selection_linewise,
    cut_selection,
    paste_after,
    paste_before,
    paste_after_end,
    paste_before_end,
    /// `]p` / `[p`: a linewise put whose indent is adjusted to the
    /// current line's (`register.putIndentedTimes`).
    paste_after_indent,
    paste_before_indent,
    paste,

    // ── history / grouping ──
    undo,
    redo,
    repeat: struct { count: u32, inner: *const EditOp },
    atomic: []const EditOp,

    comptime {
        std.debug.assert(@typeInfo(EditOp).@"union".fields.len == 145);
    }

    /// Whether the op can change buffer text (vs. move / select / yank / meta).
    pub fn isMutation(op: EditOp) bool {
        return switch (op) {
            .repeat => |r| r.inner.isMutation(),
            .atomic => |ops| for (ops) |o| {
                if (o.isMutation()) break true;
            } else false,
            // motions
            .move_left, .move_right, .move_up, .move_down, .move_word_left, .move_word_right, .move_word_right_no_cross_line, .move_right_no_cross_line, .move_left_no_cross_line, .move_word_end, .move_word_end_cw, .move_big_word_end_cw, .move_word_end_back, .move_big_word_right, .move_big_word_right_no_cross_line, .move_big_word_left, .move_big_word_end, .move_big_word_end_back, .move_line_start, .move_line_first_non_ws, .move_down_first_non_ws, .move_up_first_non_ws, .move_line_last_non_ws, .move_paragraph, .move_sentence, .move_line_end, .move_line_last_char, .move_visual_down, .move_visual_up, .move_visual_line_start, .move_visual_line_end, .move_buffer_start, .move_buffer_end, .move_to_line, .move_to_col, .set_cursor_byte, .page_up, .page_down, .half_page_up, .half_page_down => false,
            // selection
            .select_start, .select_clear, .remember_selection, .select_line, .select_line_to_end, .select_all, .select_word, .select_inner_word, .select_around_word, .select_inner_big_word, .select_around_big_word, .select_inner_quote, .select_around_quote, .select_inner_smart_quote, .select_around_smart_quote, .select_inner_bracket, .select_around_bracket, .select_inner_tag, .select_around_tag, .select_inner_paragraph, .select_around_paragraph, .select_inner_sentence, .select_around_sentence, .select_inner_function, .select_around_function, .select_inner_class, .select_around_class, .select_inner_argument, .select_around_argument, .select_inner_indent_block, .select_around_indent_block, .select_outer_indent_block, .restore_last_selection, .swap_anchor_cursor, .move_cursor_to_selection_start, .normalize_linewise_selection, .normalize_linewise_selection_inner, .make_selection_inclusive, .continue_insert_run, .find_char_on_line => false,
            .add_cursor_below, .add_cursor_above, .clear_extra_cursors, .add_cursor_at_next_word, .block_select_start, .block_select_clear, .block_eol, .yank_block => false,
            .set_register_hint, .yank_line, .yank_lines_count, .yank_selection, .yank_selection_linewise, .undo, .redo, .replace_session_begin => false,
            else => true,
        };
    }

    /// Vertical motions keep the goal column; everything else resets it.
    pub fn preservesGoalCol(op: EditOp) bool {
        return switch (op) {
            .move_up, .move_down, .page_up, .page_down, .half_page_up, .half_page_down, .move_visual_down, .move_visual_up, .move_down_first_non_ws, .move_up_first_non_ws => true,
            .repeat => |r| r.inner.preservesGoalCol(),
            .atomic => |ops| for (ops) |o| {
                if (!o.preservesGoalCol()) break false;
            } else true,
            else => false,
        };
    }

    /// `undo` / `redo`, bare or counted — the changelist skips history hops.
    pub fn isUndoOrRedo(op: EditOp) bool {
        return switch (op) {
            .undo, .redo => true,
            .repeat => |r| r.inner.isUndoOrRedo(),
            else => false,
        };
    }

    /// Whether the op reads or writes a register — the vim handler prefixes
    /// these with `set_register_hint` when a `"x` is pending.
    pub fn touchesClipboard(op: EditOp) bool {
        return switch (op) {
            .yank_line, .yank_lines_count, .yank_selection, .yank_selection_linewise, .yank_block, .paste_after, .paste_before, .paste_after_end, .paste_before_end, .paste_after_indent, .paste_before_indent, .paste, .cut_selection, .delete_selection, .delete_line, .delete_forward, .delete_word_left, .delete_word_right, .delete_to_line_start, .delete_to_line_end, .delete_block => true,
            .repeat => |r| r.inner.touchesClipboard(),
            .atomic => |ops| for (ops) |o| {
                if (o.touchesClipboard()) break true;
            } else false,
            else => false,
        };
    }

    /// The count a `{count}.` replaces: a `repeat`'s, or a counted
    /// motion's own. Null for an op with no count to speak of.
    pub fn countPtr(op: *EditOp) ?*u32 {
        return switch (op.*) {
            .repeat => |*r| &r.count,
            .move_word_end_cw, .move_big_word_end_cw => |*n| n,
            else => null,
        };
    }

    /// A typed character (possibly counted) — keeps the coalescing undo run alive.
    pub fn isInsertChar(op: EditOp) bool {
        return switch (op) {
            .insert_char => true,
            .repeat => |r| r.inner.isInsertChar(),
            else => false,
        };
    }

    /// Deep copy onto `gpa` so the op can outlive the frame arena.
    pub fn dupe(op: EditOp, gpa: Allocator) Allocator.Error!EditOp {
        return switch (op) {
            .insert_str => |s| .{ .insert_str = try gpa.dupe(u8, s) },
            .replace_selection => |s| .{ .replace_selection = try gpa.dupe(u8, s) },
            .replace_range => |r| .{ .replace_range = .{ .start = r.start, .end = r.end, .text = try gpa.dupe(u8, r.text) } },
            .repeat => |r| blk: {
                const inner = try gpa.create(EditOp);
                errdefer gpa.destroy(inner);
                inner.* = try r.inner.dupe(gpa);
                break :blk .{ .repeat = .{ .count = r.count, .inner = inner } };
            },
            .atomic => |ops| blk: {
                const copy = try gpa.alloc(EditOp, ops.len);
                var n: usize = 0;
                errdefer {
                    for (copy[0..n]) |o| o.free(gpa);
                    gpa.free(copy);
                }
                for (ops) |o| {
                    copy[n] = try o.dupe(gpa);
                    n += 1;
                }
                break :blk .{ .atomic = copy };
            },
            else => op,
        };
    }

    /// Release a `dupe`d op. Never call on a frame-arena op.
    pub fn free(op: EditOp, gpa: Allocator) void {
        switch (op) {
            .insert_str => |s| gpa.free(s),
            .replace_selection => |s| gpa.free(s),
            .replace_range => |r| gpa.free(r.text),
            .repeat => |r| {
                r.inner.free(gpa);
                gpa.destroy(r.inner);
            },
            .atomic => |ops| {
                for (ops) |o| o.free(gpa);
                gpa.free(ops);
            },
            else => {},
        }
    }
};

/// A byte-range edit hint for incremental reparse: `(start, old_end,
/// new_end)` in the pre-edit coordinate space.
pub const TextEdit = struct {
    start_byte: usize,
    old_end_byte: usize,
    new_end_byte: usize,
};

/// What `Editor.apply` reports back so the caller can sync dirty state,
/// the clipboard, scroll and (later) the LSP. `text_edits` is allocated on
/// the arena the caller passed to `apply`; `clipboard_set` borrows the
/// clipboard's own storage and is valid until the clipboard's next write.
///
/// CONTRACT: `buffer_changed and text_edits.len == 0` ⇒ the caller drops
/// any cached parse tree and reparses from scratch.
pub const EditOutcome = struct {
    buffer_changed: bool = false,
    cursor_moved: bool = false,
    clipboard_set: ?[]const u8 = null,
    clipboard_linewise: bool = false,
    text_edits: []const TextEdit = &.{},
    /// Byte range just yanked or deleted — the inc-yank flash.
    yanked_range: ?[2]usize = null,
};

test "dupe/free round-trips the recursive shapes leak-free" {
    const gpa = std.testing.allocator;
    const inner: EditOp = .{ .insert_str = "hi" };
    const ops = [_]EditOp{ .move_left, .{ .repeat = .{ .count = 3, .inner = &inner } }, .{ .replace_range = .{ .start = 0, .end = 1, .text = "x" } } };
    const op: EditOp = .{ .atomic = &ops };
    const copy = try op.dupe(gpa);
    defer copy.free(gpa);
    try std.testing.expectEqual(@as(usize, 3), copy.atomic.len);
    try std.testing.expectEqualStrings("hi", copy.atomic[1].repeat.inner.insert_str);
    try std.testing.expect(copy.atomic[1].repeat.inner.insert_str.ptr != inner.insert_str.ptr);
    try std.testing.expect(op.isMutation());
    const down: EditOp = .move_down;
    try std.testing.expect(!(EditOp{ .repeat = .{ .count = 2, .inner = &down } }).isMutation());
    try std.testing.expect((EditOp{ .repeat = .{ .count = 2, .inner = &down } }).preservesGoalCol());
}
