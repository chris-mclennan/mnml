//! Whole-line ops: join, indent, outdent, duplicate, move, case.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor = @import("editor.zig");
const Editor = editor.Editor;
const edit_op = @import("edit_op.zig");
const EditOutcome = edit_op.EditOutcome;
const CaseTransform = edit_op.CaseTransform;
const select = @import("select.zig");

/// vim `J` (`keep_space`) / `gJ`.
pub fn joinLines(ed: *Editor, keep_space: bool, out: *EditOutcome) Allocator.Error!void {
    const line = ed.currentLine();
    if (line + 1 >= ed.lineCount()) return;
    try ed.checkpoint();
    const t = ed.bytes();
    const bol = ed.lineStart(line);
    const eol = ed.lineEnd(line);
    var trim_end = eol;
    if (keep_space) {
        while (trim_end > bol and (t[trim_end - 1] == ' ' or t[trim_end - 1] == '\t')) trim_end -= 1;
    }
    const next_bol = eol + 1;
    const next_eol = ed.lineEnd(line + 1);
    var next_first = next_bol;
    if (keep_space) {
        while (next_first < next_eol and (t[next_first] == ' ' or t[next_first] == '\t')) next_first += 1;
    }
    const sep: []const u8 = if (!keep_space or trim_end == bol) "" else " ";
    try ed.splice(trim_end, next_first, sep);
    ed.cursor = trim_end;
    ed.anchor = null;
    out.buffer_changed = true;
}

/// The lines a selection (or the cursor) touches, first..last inclusive.
/// A selection ending exactly at a line start does not include that line.
pub fn selectedLineRange(ed: *const Editor) [2]usize {
    if (ed.selection()) |s| {
        const fl = ed.lineOfByte(s[0]);
        const hl = ed.lineOfByte(s[1]);
        const ll = if (s[1] > s[0] and s[1] == ed.lineStart(hl) and hl > fl) hl - 1 else hl;
        return .{ fl, ll };
    }
    const l = ed.currentLine();
    return .{ l, l };
}

fn restoreCursorAfterLineOp(ed: *Editor, pos: editor.Pos) void {
    ed.cursor = ed.byteAtCol(@min(pos.row, ed.lineCount() - 1), pos.col);
    ed.anchor = null;
}

pub fn indent(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    try ed.checkpoint();
    const pos = ed.rowCol();
    const range = selectedLineRange(ed);
    var pad_buf: [64]u8 = undefined;
    const pad: []const u8 = if (ed.doc.use_tabs) "\t" else blk: {
        const p = pad_buf[0..@min(ed.doc.tab_width, pad_buf.len)];
        @memset(p, ' ');
        break :blk p;
    };
    var line = range[0];
    while (line <= range[1]) : (line += 1) {
        const bol = ed.lineStart(line);
        try ed.splice(bol, bol, pad);
    }
    // The cursor keeps its (row, col) — Rust mnml parity; vim would go
    // to the first non-blank.
    restoreCursorAfterLineOp(ed, pos);
    out.buffer_changed = true;
}

pub fn outdent(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    try ed.checkpoint();
    const pos = ed.rowCol();
    const range = selectedLineRange(ed);
    var changed = false;
    var line = range[0];
    while (line <= range[1]) : (line += 1) {
        const bol = ed.lineStart(line);
        const eol = ed.lineEnd(line);
        var remove: usize = 0;
        var i = bol;
        while (i < eol and remove < ed.doc.tab_width) : (i += 1) {
            if (ed.bytes()[i] == ' ') {
                remove += 1;
            } else if (ed.bytes()[i] == '\t') {
                remove += 1;
                break;
            } else break;
        }
        if (remove > 0) {
            try ed.splice(bol, bol + remove, "");
            changed = true;
        }
    }
    if (changed) {
        restoreCursorAfterLineOp(ed, pos);
        out.buffer_changed = true;
    } else {
        ed.popCheckpoint();
        ed.anchor = null;
    }
}

/// vim's `>` / `<` (`:help >>`): the range shifted as `indent` /
/// `outdent` do, then the cursor on the range's FIRST line at its first
/// non-blank — so `3>>` and `V…>` end where they began and a `.` after
/// them shifts the same lines again, not the ones below.
pub fn shiftToFirstNonBlank(ed: *Editor, out_: bool, out: *EditOutcome) Allocator.Error!void {
    const first = selectedLineRange(ed)[0];
    if (out_) try outdent(ed, out) else try indent(ed, out);
    ed.cursor = ed.firstNonWs(@min(first, ed.lineCount() - 1));
    ed.anchor = null;
}

/// `=`: each line of the range gets the indent the lines above call
/// for — vim's `=` without an `indentexpr`, reduced to the brace rules
/// that fit every C-shaped language: a line takes the indent of the
/// nearest non-blank line above it (as just re-indented), one unit more
/// when that line ends in `{` `(` `[`, one unit less when the line
/// itself opens with `}` `)` `]`. Blank lines are emptied. The unit is
/// the tab width, a tab under `use_tabs`. The cursor lands on the first
/// line's first non-blank.
pub fn reindent(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    try ed.checkpoint();
    const range = selectedLineRange(ed);
    var changed = false;
    var line = range[0];
    while (line <= range[1]) : (line += 1) {
        const bol = ed.lineStart(line);
        const eol = ed.lineEnd(line);
        if (ed.lineIsBlank(line)) {
            if (eol > bol) {
                try ed.splice(bol, eol, "");
                changed = true;
            }
            continue;
        }
        const want = targetIndent(ed, line);
        const have = ed.leadingIndent(line, null);
        var buf: [256]u8 = undefined;
        const text = indentText(ed, want, &buf);
        if (std.mem.eql(u8, have, text)) continue;
        try ed.splice(bol, bol + have.len, text);
        changed = true;
    }
    ed.anchor = null;
    ed.cursor = ed.firstNonWs(@min(range[0], ed.lineCount() - 1));
    ed.goal_col = null;
    if (!changed) {
        ed.popCheckpoint();
        return;
    }
    out.buffer_changed = true;
}

/// The indent column `line` should have, from the non-blank line above.
fn targetIndent(ed: *const Editor, line: usize) usize {
    const unit = @max(ed.doc.tab_width, 1);
    var p = line;
    const prev: ?usize = while (p > 0) {
        p -= 1;
        if (!ed.lineIsBlank(p)) break p;
    } else null;
    var want: usize = 0;
    if (prev) |pl| {
        want = indentColumns(ed, pl);
        const ps = std.mem.trimEnd(u8, ed.lineSlice(pl), " \t");
        if (ps.len > 0 and (ps[ps.len - 1] == '{' or ps[ps.len - 1] == '(' or ps[ps.len - 1] == '[')) want += unit;
    }
    const ls = std.mem.trimStart(u8, ed.lineSlice(line), " \t");
    if (ls.len > 0 and (ls[0] == '}' or ls[0] == ')' or ls[0] == ']')) want -|= unit;
    return want;
}

/// The display column of `line`'s first non-blank (tabs at `tab_width`).
fn indentColumns(ed: *const Editor, line: usize) usize {
    var cols: usize = 0;
    for (ed.leadingIndent(line, null)) |b| cols += if (b == '\t') @max(ed.doc.tab_width, 1) else 1;
    return cols;
}

/// `cols` of indent as text: tabs (plus spaces for a remainder) under
/// `use_tabs`, else spaces. Cut at `buf.len`.
fn indentText(ed: *const Editor, cols: usize, buf: *[256]u8) []const u8 {
    var n: usize = 0;
    var left = cols;
    if (ed.doc.use_tabs) {
        const tw = @max(ed.doc.tab_width, 1);
        while (left >= tw and n < buf.len) : (left -= tw) {
            buf[n] = '\t';
            n += 1;
        }
    }
    while (left > 0 and n < buf.len) : (left -= 1) {
        buf[n] = ' ';
        n += 1;
    }
    return buf[0..n];
}

/// Copy the current line below itself; cursor moves to the copy.
pub fn duplicateLine(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    try ed.checkpoint();
    const pos = ed.rowCol();
    const line = pos.row;
    const bol = ed.lineStart(line);
    const eol = ed.lineEnd(line);
    const copy = try std.mem.concat(ed.gpa, u8, &.{ "\n", ed.bytes()[bol..eol] });
    defer ed.gpa.free(copy);
    try ed.splice(eol, eol, copy);
    ed.cursor = ed.byteAtCol(line + 1, pos.col);
    ed.anchor = null;
    out.buffer_changed = true;
}

/// Swap the current line with its neighbour (`alt+↑` / `alt+↓`).
pub fn moveLine(ed: *Editor, dir: i2, out: *EditOutcome) Allocator.Error!void {
    const pos = ed.rowCol();
    const line = pos.row;
    const other = if (dir < 0) blk: {
        if (line == 0) return;
        break :blk line - 1;
    } else blk: {
        if (line + 1 >= ed.lineCount()) return;
        break :blk line + 1;
    };
    try ed.checkpoint();
    const a = @min(line, other);
    const b = @max(line, other);
    const a_s = ed.lineStart(a);
    const a_e = ed.lineEnd(a);
    const b_s = ed.lineStart(b);
    const b_e = ed.lineEnd(b);
    const joined = try std.mem.concat(ed.gpa, u8, &.{ ed.bytes()[b_s..b_e], "\n", ed.bytes()[a_s..a_e] });
    defer ed.gpa.free(joined);
    try ed.splice(a_s, b_e, joined);
    ed.cursor = ed.byteAtCol(other, pos.col);
    ed.anchor = null;
    out.buffer_changed = true;
}

/// `gu` / `gU` / `g~` over the selection. ASCII-only case mapping; the
/// cursor parks at the range start.
pub fn transformSelectionCase(ed: *Editor, kind: CaseTransform, out: *EditOutcome) Allocator.Error!void {
    const sel = ed.selection() orelse return;
    const src = ed.bytes()[sel[0]..sel[1]];
    const buf = try ed.gpa.alloc(u8, src.len);
    defer ed.gpa.free(buf);
    var changed = false;
    for (src, buf) |c, *o| {
        o.* = switch (kind) {
            .lower => std.ascii.toLower(c),
            .upper => std.ascii.toUpper(c),
            .toggle => if (std.ascii.isUpper(c)) std.ascii.toLower(c) else std.ascii.toUpper(c),
        };
        if (o.* != c) changed = true;
    }
    if (changed) {
        try ed.checkpoint();
        try ed.splice(sel[0], sel[1], buf);
        out.buffer_changed = true;
    }
    ed.cursor = sel[0];
    ed.anchor = null;
}

/// vim `~`: toggle the ASCII letter under the cursor and advance.
pub fn toggleCaseChar(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    if (ed.cursor >= ed.len()) return;
    const b = ed.bytes()[ed.cursor];
    if (std.ascii.isAlphabetic(b)) {
        try ed.checkpoint();
        const t = [_]u8{if (std.ascii.isUpper(b)) std.ascii.toLower(b) else std.ascii.toUpper(b)};
        try ed.splice(ed.cursor, ed.cursor + 1, &t);
        out.buffer_changed = true;
    }
    ed.cursor = ed.nextBoundary(ed.cursor);
}

// ─── comment / number / reflow / align ──────────────────────────────────

/// `gcc` / `gc{motion}` / Ctrl+/: put the buffer's comment token after
/// the indent of every selected line (plus the closer at EOL for block
/// styles), or strip it when the first line already carries one. Blank
/// lines are skipped; an empty token makes this a no-op.
pub fn toggleLineComment(ed: *Editor, out: *EditOutcome) Allocator.Error!void {
    const token = ed.doc.comment_token;
    if (std.mem.trim(u8, token, " \t").len == 0) return;
    const close = ed.doc.comment_token_close;
    const trimmed = std.mem.trimEnd(u8, token, " \t");
    const close_trimmed = std.mem.trimStart(u8, close, " \t");
    const range = selectedLineRange(ed);
    // A selection survives the toggle, both ends kept by (row, col) the
    // way vim's marks sit still: VS Code's Ctrl+/ twice is a no-op,
    // and the line range is the same whichever end the cursor holds. A
    // handler that wants the cursor on the first line afterwards says
    // so (`move_cursor_to_selection_start`, `select_clear`).
    const sel_pos: ?[2]editor.Pos = if (ed.anchor) |a| .{ ed.rowColAt(a), ed.rowColAt(ed.cursor) } else null;
    const pos = ed.rowCol();
    const already = std.mem.startsWith(u8, ed.bytes()[ed.firstNonWs(range[0])..], trimmed);
    try ed.checkpoint();
    var changed = false;
    var line = range[1] + 1;
    while (line > range[0]) {
        line -= 1;
        const ie = ed.firstNonWs(line);
        const eol = ed.lineEnd(line);
        if (ie >= eol) continue;
        if (already) {
            const body = ed.bytes()[ie..eol];
            if (close.len > 0) {
                if (std.mem.endsWith(u8, body, close)) {
                    try ed.splice(eol - close.len, eol, "");
                    changed = true;
                } else if (std.mem.endsWith(u8, body, close_trimmed)) {
                    try ed.splice(eol - close_trimmed.len, eol, "");
                    changed = true;
                }
            }
            const rest = ed.bytes()[ie..];
            if (std.mem.startsWith(u8, rest, token)) {
                try ed.splice(ie, ie + token.len, "");
                changed = true;
            } else if (std.mem.startsWith(u8, rest, trimmed)) {
                try ed.splice(ie, ie + trimmed.len, "");
                changed = true;
            }
        } else {
            if (close.len > 0) try ed.splice(eol, eol, close);
            try ed.splice(ie, ie, token);
            changed = true;
        }
    }
    if (changed) {
        if (sel_pos) |sp| {
            const last = ed.lineCount() - 1;
            ed.anchor = ed.byteAtCol(@min(sp[0].row, last), sp[0].col);
            ed.cursor = ed.byteAtCol(@min(sp[1].row, last), sp[1].col);
            ed.goal_col = null;
        } else restoreCursorAfterLineOp(ed, pos);
        out.buffer_changed = true;
    } else {
        ed.popCheckpoint();
        ed.anchor = null;
    }
}

/// Ctrl+A / Ctrl+X: the number under or after the cursor on this line,
/// a `-` right before it its sign. The cursor
/// lands on the number's last digit (vim).
const NumberKind = enum { decimal, hex, bin };
const NumberSpan = struct { start: usize, end: usize, kind: NumberKind };

fn isBinDigit(b: u8) bool {
    return b == '0' or b == '1';
}

/// The number under or after `from` on the line `[bol, eol)`: the first
/// one that ends past `from`. Neovim's `nrformats=bin,hex`: `0x1f` /
/// `0b101` are read whole from any of their chars; anything else is
/// decimal, a `-` right before the digits part of it (`a-1` is `a` and
/// `-1`). Leading zeros make a decimal, not octal.
fn numberAfter(t: []const u8, bol: usize, eol: usize, from: usize) ?NumberSpan {
    var i = bol;
    while (i < eol) {
        if (!std.ascii.isDigit(t[i])) {
            i += 1;
            continue;
        }
        var span: NumberSpan = undefined;
        if (t[i] == '0' and i + 2 < eol and (t[i + 1] == 'x' or t[i + 1] == 'X') and std.ascii.isHex(t[i + 2])) {
            var end = i + 2;
            while (end < eol and std.ascii.isHex(t[end])) end += 1;
            span = .{ .start = i, .end = end, .kind = .hex };
        } else if (t[i] == '0' and i + 2 < eol and (t[i + 1] == 'b' or t[i + 1] == 'B') and isBinDigit(t[i + 2])) {
            var end = i + 2;
            while (end < eol and isBinDigit(t[end])) end += 1;
            span = .{ .start = i, .end = end, .kind = .bin };
        } else {
            // Neovim's `nrformats` without `unsigned` / `blank`: a `-`
            // right before the digits is the sign, whatever precedes it
            // (`val-3` Ctrl-A is `val-2`).
            var start = i;
            if (start > bol and t[start - 1] == '-') start -= 1;
            var end = i;
            while (end < eol and std.ascii.isDigit(t[end])) end += 1;
            span = .{ .start = start, .end = end, .kind = .decimal };
        }
        if (span.end > from) return span;
        i = span.end;
    }
    return null;
}

/// Add `delta` to the number at `span`; the new span's end, or null when
/// nothing changed. Hex and binary wrap as 64-bit unsigned and keep
/// their digit count and letter case; a zero-padded decimal keeps its
/// width (`007` → `006`, `000` → `-001`) — `:help CTRL-A`. The caller
/// owns the checkpoint.
fn bumpNumber(ed: *Editor, span: NumberSpan, delta: i64) Allocator.Error!?usize {
    const t = ed.bytes();
    const old = t[span.start..span.end];
    var buf: [80]u8 = undefined;
    const new_s: []const u8 = switch (span.kind) {
        .decimal => blk: {
            const n = std.fmt.parseInt(i64, old, 10) catch return null;
            const digits = if (old[0] == '-') old[1..] else old;
            const v = n +| delta;
            const padded = digits.len > 1 and digits[0] == '0';
            const body = std.fmt.bufPrint(buf[40..], "{d}", .{@abs(v)}) catch return null;
            var w: usize = 0;
            if (v < 0) {
                buf[w] = '-';
                w += 1;
            }
            if (padded) while (w + body.len < digits.len + @as(usize, if (v < 0) 1 else 0)) : (w += 1) {
                buf[w] = '0';
            };
            @memcpy(buf[w .. w + body.len], body);
            break :blk buf[0 .. w + body.len];
        },
        .hex, .bin => blk: {
            const base: u8 = if (span.kind == .hex) 16 else 2;
            const digits = old[2..];
            const v = std.fmt.parseInt(u64, digits, base) catch return null;
            const nv: u64 = if (delta >= 0) v +% @as(u64, @intCast(delta)) else v -% @as(u64, @intCast(-delta));
            var upper = false;
            for (digits) |c| if (std.ascii.isUpper(c)) {
                upper = true;
            };
            const body = if (span.kind == .bin)
                std.fmt.bufPrint(buf[40..], "{b}", .{nv}) catch return null
            else if (upper)
                std.fmt.bufPrint(buf[40..], "{X}", .{nv}) catch return null
            else
                std.fmt.bufPrint(buf[40..], "{x}", .{nv}) catch return null;
            buf[0] = old[0];
            buf[1] = old[1];
            var w: usize = 2;
            while (w + body.len < 2 + digits.len) : (w += 1) buf[w] = '0';
            @memcpy(buf[w .. w + body.len], body);
            break :blk buf[0 .. w + body.len];
        },
    };
    if (std.mem.eql(u8, new_s, old)) return null;
    try ed.splice(span.start, span.end, new_s);
    return span.start + new_s.len;
}

pub fn changeNumberAtCursor(ed: *Editor, delta: i64, out: *EditOutcome) Allocator.Error!void {
    const line = ed.currentLine();
    const span = numberAfter(ed.bytes(), ed.lineStart(line), ed.lineEnd(line), ed.cursor) orelse return;
    try ed.checkpoint();
    const end = (try bumpNumber(ed, span, delta)) orelse {
        ed.popCheckpoint();
        return;
    };
    ed.cursor = end - 1;
    ed.anchor = null;
    out.buffer_changed = true;
}

/// `v_CTRL-A` / `v_CTRL-X` (`:help v_CTRL-A`): the first number on each
/// selected line — from the selection's start on its first line — gets
/// `delta`; `progressive` (`g CTRL-A`) gives the k-th line that has a
/// number `k × delta`. One undo step; the cursor parks at the
/// selection's start and the selection ends.
pub fn changeNumbersInSelection(ed: *Editor, delta: i64, progressive: bool, out: *EditOutcome) Allocator.Error!void {
    const sel = ed.selection() orelse return;
    const lo = sel[0];
    const hi = if (sel[1] > sel[0]) sel[1] - 1 else sel[1];
    const first = ed.lineOfByte(lo);
    const last = ed.lineOfByte(hi);
    try ed.checkpoint();
    var changed = false;
    var k: i64 = 1;
    var row = first;
    while (row <= last) : (row += 1) {
        const bol = ed.lineStart(row);
        const from = if (row == first) lo else bol;
        const span = numberAfter(ed.bytes(), bol, ed.lineEnd(row), from) orelse continue;
        if (try bumpNumber(ed, span, if (progressive) delta * k else delta)) |_| changed = true;
        k += 1;
    }
    ed.cursor = ed.snapBoundary(lo);
    ed.anchor = null;
    ed.goal_col = null;
    if (changed) out.buffer_changed = true else ed.popCheckpoint();
}

/// `gq`: greedy word-wrap of the paragraph under the cursor to `width`,
/// keeping the first line's indent on every line. Words are runs of
/// non-blanks joined by one space.
pub fn reflowParagraph(ed: *Editor, width: usize, out: *EditOutcome) Allocator.Error!void {
    const b = select.paragraphBounds(ed, false);
    if (b[1] <= b[0]) return;
    const body = ed.bytes()[b[0]..b[1]];
    if (std.mem.trim(u8, body, " \t\r\n").len == 0) return;
    const first_end = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
    var indent_len: usize = 0;
    while (indent_len < first_end and (body[indent_len] == ' ' or body[indent_len] == '\t')) indent_len += 1;
    const lead = body[0..indent_len];
    const target = @max(width, indent_len + 8);
    var wrapped: std.ArrayList(u8) = .empty;
    defer wrapped.deinit(ed.gpa);
    var it = std.mem.tokenizeAny(u8, body, " \t\r\n");
    var line_chars: usize = 0;
    var first = true;
    while (it.next()) |w| {
        const wlen = std.unicode.utf8CountCodepoints(w) catch w.len;
        if (first) {
            try wrapped.appendSlice(ed.gpa, lead);
            first = false;
            line_chars = indent_len + wlen;
        } else if (line_chars + 1 + wlen > target) {
            try wrapped.append(ed.gpa, '\n');
            try wrapped.appendSlice(ed.gpa, lead);
            line_chars = indent_len + wlen;
        } else {
            try wrapped.append(ed.gpa, ' ');
            line_chars += 1 + wlen;
        }
        try wrapped.appendSlice(ed.gpa, w);
    }
    if (std.mem.eql(u8, wrapped.items, body)) return;
    try ed.checkpoint();
    try ed.splice(b[0], b[1], wrapped.items);
    ed.cursor = b[0];
    ed.anchor = null;
    out.buffer_changed = true;
}

/// `gA{motion}<c>` (mini.align): pad every selected line before its
/// first `on_char` so they line up at the widest column. Lines without
/// the char are left alone; an already-aligned range just drops the
/// selection.
pub fn alignSelection(ed: *Editor, on_char: u21, out: *EditOutcome) Allocator.Error!void {
    const sel = ed.selection() orelse return;
    const first = ed.lineOfByte(sel[0]);
    var last = ed.lineOfByte(sel[1]);
    if (sel[1] > sel[0] and ed.bytes()[sel[1] - 1] == '\n') last -|= 1;
    last = @min(last, ed.lineCount() - 1);
    if (last < first) return;
    const Target = struct { byte: usize, col: usize };
    var targets: std.ArrayList(Target) = .empty;
    defer targets.deinit(ed.gpa);
    var max_col: usize = 0;
    for (first..last + 1) |line| {
        var byte = ed.lineStart(line);
        const eol = ed.lineEnd(line);
        var col: usize = 0;
        while (byte < eol) : (col += 1) {
            if (ed.charAt(byte) == on_char) {
                try targets.append(ed.gpa, .{ .byte = byte, .col = col });
                max_col = @max(max_col, col);
                break;
            }
            byte = ed.nextBoundary(byte);
        }
    }
    var needs = false;
    for (targets.items) |tg| if (tg.col < max_col) {
        needs = true;
    };
    if (!needs) {
        ed.cursor = sel[0];
        ed.anchor = null;
        return;
    }
    try ed.checkpoint();
    var i = targets.items.len;
    while (i > 0) {
        i -= 1;
        const pad = max_col - targets.items[i].col;
        if (pad == 0) continue;
        const spaces = try ed.gpa.alloc(u8, pad);
        defer ed.gpa.free(spaces);
        @memset(spaces, ' ');
        try ed.splice(targets.items[i].byte, targets.items[i].byte, spaces);
    }
    ed.cursor = ed.lineStart(first);
    ed.anchor = null;
    out.buffer_changed = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

test "reindent follows the braces above, empties blank lines, and is a no-op on tidy text" {
    const ed = try Editor.init(std.testing.allocator, "fn f() {\nx;\n   \n  if (a) {\ny;\n}\n}\n");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.anchor = 0;
    ed.cursor = ed.len();
    try reindent(ed, &out);
    try std.testing.expectEqualStrings("fn f() {\n    x;\n\n    if (a) {\n        y;\n    }\n}\n", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    try std.testing.expect(out.buffer_changed and ed.anchor == null);
    // A second pass changes nothing and leaves no undo entry behind.
    const undo_len = ed.doc.history.undoLen();
    out = .{};
    ed.anchor = 0;
    ed.cursor = ed.len();
    try reindent(ed, &out);
    try std.testing.expect(!out.buffer_changed);
    try std.testing.expectEqual(undo_len, ed.doc.history.undoLen());
    // One line: the cursor's, from the line above it; tabs under use_tabs.
    ed.doc.use_tabs = true;
    ed.cursor = ed.lineStart(4);
    try reindent(ed, &out);
    try std.testing.expectEqualStrings("fn f() {\n    x;\n\n    if (a) {\n\t\ty;\n    }\n}\n", ed.doc.text.items);
}

test "toggle comment: line and block styles, indent kept, blank lines skipped, empty token no-op" {
    const ed = try Editor.init(std.testing.allocator, "  a\n\nb");
    defer ed.deinit();
    var out: EditOutcome = .{};
    try toggleLineComment(ed, &out); // no token yet
    try std.testing.expectEqualStrings("  a\n\nb", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 0), ed.doc.history.undoLen());
    ed.doc.comment_token = "// ";
    ed.anchor = 0;
    ed.cursor = 7;
    try toggleLineComment(ed, &out);
    try std.testing.expectEqualStrings("  // a\n\n// b", ed.doc.text.items);
    // The selection stays, each end at its (row, col): the same range
    // again puts the text back.
    try std.testing.expectEqual(@as(?usize, 0), ed.anchor);
    try std.testing.expectEqual(ed.byteAtCol(2, 1), ed.cursor);
    try toggleLineComment(ed, &out);
    try std.testing.expectEqualStrings("  a\n\nb", ed.doc.text.items);
    try std.testing.expectEqual(@as(?usize, 0), ed.anchor);
    try std.testing.expectEqual(ed.len(), ed.cursor);
    ed.anchor = null;
    ed.doc.comment_token = "<!-- ";
    ed.doc.comment_token_close = " -->";
    ed.cursor = 0;
    try toggleLineComment(ed, &out);
    try std.testing.expectEqualStrings("  <!-- a -->\n\nb", ed.doc.text.items);
    try toggleLineComment(ed, &out);
    try std.testing.expectEqualStrings("  a\n\nb", ed.doc.text.items);
}

test "toggle comment keeps a multi-line selection: Ctrl+/ twice is a no-op" {
    const ed = try Editor.init(std.testing.allocator, "fn a() {\n    return 1;\n}\n");
    defer ed.deinit();
    ed.doc.comment_token = "// ";
    var out: EditOutcome = .{};
    // Anchor at the top of line 0, cursor at the top of line 2: line 2
    // is outside the range, as VS Code reads a selection ending at col 0.
    ed.anchor = 0;
    ed.cursor = ed.lineStart(2);
    try toggleLineComment(ed, &out);
    try std.testing.expectEqualStrings("// fn a() {\n    // return 1;\n}\n", ed.doc.text.items);
    try std.testing.expectEqual(@as(?usize, 0), ed.anchor);
    try std.testing.expectEqual(ed.lineStart(2), ed.cursor);
    try toggleLineComment(ed, &out);
    try std.testing.expectEqualStrings("fn a() {\n    return 1;\n}\n", ed.doc.text.items);
    try std.testing.expectEqual(@as(?usize, 0), ed.anchor);
    try std.testing.expectEqual(ed.lineStart(2), ed.cursor);
    // Without a selection the cursor keeps its column (Rust mnml parity).
    ed.anchor = null;
    ed.cursor = ed.byteAtCol(1, 6);
    try toggleLineComment(ed, &out);
    try std.testing.expectEqualStrings("fn a() {\n    // return 1;\n}\n", ed.doc.text.items);
    try std.testing.expectEqual(ed.byteAtCol(1, 6), ed.cursor);
    try std.testing.expect(ed.anchor == null);
}

test "change number: under or after the cursor, a free minus, counts, saturation, cursor on the last digit" {
    const ed = try Editor.init(std.testing.allocator, "value = 41 x-1 y -1");
    defer ed.deinit();
    var out: EditOutcome = .{};
    try changeNumberAtCursor(ed, 1, &out);
    try std.testing.expectEqualStrings("value = 42 x-1 y -1", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 9), ed.cursor);
    try changeNumberAtCursor(ed, -3, &out);
    try std.testing.expectEqualStrings("value = 39 x-1 y -1", ed.doc.text.items);
    ed.cursor = 12; // on the `-` after `x`: it is the sign (Neovim: `x0`)
    try changeNumberAtCursor(ed, 1, &out);
    try std.testing.expectEqualStrings("value = 39 x0 y -1", ed.doc.text.items);
    ed.cursor = 15; // `-1` stands alone
    try changeNumberAtCursor(ed, -1, &out);
    try std.testing.expectEqualStrings("value = 39 x0 y -2", ed.doc.text.items);
    try changeNumberAtCursor(ed, 2, &out);
    try std.testing.expectEqualStrings("value = 39 x0 y 0", ed.doc.text.items);
    try ed.setText("no digits");
    ed.cursor = 0;
    try changeNumberAtCursor(ed, 1, &out);
    try std.testing.expectEqualStrings("no digits", ed.doc.text.items);
    try ed.setText("9223372036854775807");
    ed.cursor = 0;
    try changeNumberAtCursor(ed, 1, &out); // saturates: nothing to change
    try std.testing.expectEqualStrings("9223372036854775807", ed.doc.text.items);
}

test "reflow wraps greedily at the width, keeps the indent, leaves a short paragraph alone" {
    const ed = try Editor.init(std.testing.allocator, "  aaa bbb\n  ccc ddd eee\n\nnext");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.cursor = 3;
    try reflowParagraph(ed, 12, &out);
    try std.testing.expectEqualStrings("  aaa bbb\n  ccc ddd\n  eee\n\nnext", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    try reflowParagraph(ed, 80, &out);
    try std.testing.expectEqualStrings("  aaa bbb ccc ddd eee\n\nnext", ed.doc.text.items);
    ed.cursor = ed.len();
    const undo_len = ed.doc.history.undoLen();
    try reflowParagraph(ed, 80, &out); // already flowed
    try std.testing.expectEqual(undo_len, ed.doc.history.undoLen());
}

test "align pads before the first char per line; lines without it are untouched; aligned range just deselects" {
    const ed = try Editor.init(std.testing.allocator, "let a = 1\nlet bb = 2\nnone\nlet ccc = 3\n");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.anchor = 0;
    ed.cursor = ed.len();
    try alignSelection(ed, '=', &out);
    try std.testing.expectEqualStrings("let a   = 1\nlet bb  = 2\nnone\nlet ccc = 3\n", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    try std.testing.expect(ed.anchor == null);
    ed.anchor = 0;
    ed.cursor = ed.len();
    const undo_len = ed.doc.history.undoLen();
    try alignSelection(ed, '=', &out);
    try std.testing.expectEqual(undo_len, ed.doc.history.undoLen());
    try std.testing.expect(ed.anchor == null);
}

test "J trims and inserts one space; gJ keeps whitespace" {
    const ed = try Editor.init(std.testing.allocator, "ab  \n   cd\nef");
    defer ed.deinit();
    var out: EditOutcome = .{};
    try joinLines(ed, true, &out);
    try std.testing.expectEqualStrings("ab cd\nef", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
    try joinLines(ed, false, &out);
    try std.testing.expectEqualStrings("ab cdef", ed.doc.text.items);
    try joinLines(ed, true, &out); // last line: no-op
    try std.testing.expectEqualStrings("ab cdef", ed.doc.text.items);
}

test "indent / outdent over a selection keep the cursor column" {
    const ed = try Editor.init(std.testing.allocator, "a\nb\nc");
    defer ed.deinit();
    ed.doc.tab_width = 2;
    var out: EditOutcome = .{};
    ed.anchor = 0;
    ed.cursor = 4; // start of line 2 → only lines 0-1
    try indent(ed, &out);
    try std.testing.expectEqualStrings("  a\n  b\nc", ed.doc.text.items);
    try std.testing.expect(ed.anchor == null);
    ed.cursor = 3;
    try outdent(ed, &out);
    try std.testing.expectEqualStrings("a\n  b\nc", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
    ed.cursor = 0;
    try outdent(ed, &out); // nothing to remove → no undo entry
    try std.testing.expectEqual(@as(usize, 2), ed.doc.history.undoLen());
}

test "duplicate, move line, case ops" {
    const ed = try Editor.init(std.testing.allocator, "ab\ncd");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.cursor = 1;
    try duplicateLine(ed, &out);
    try std.testing.expectEqualStrings("ab\nab\ncd", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 4), ed.cursor);
    try moveLine(ed, 1, &out);
    try std.testing.expectEqualStrings("ab\ncd\nab", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 7), ed.cursor);
    try moveLine(ed, 1, &out);
    try std.testing.expectEqualStrings("ab\ncd\nab", ed.doc.text.items);
    ed.anchor = 0;
    ed.cursor = 5;
    try transformSelectionCase(ed, .upper, &out);
    try std.testing.expectEqualStrings("AB\nCD\nab", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    try toggleCaseChar(ed, &out);
    try std.testing.expectEqualStrings("aB\nCD\nab", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
}
