//! Cursor motions. Every function moves `ed.cursor` and nothing else
//! (the `apply` wrapper handles goal-column bookkeeping). All results
//! land on char boundaries because they walk `nextBoundary` /
//! `prevBoundary` rather than adding to bytes.

const std = @import("std");
const editor = @import("editor.zig");
const Editor = editor.Editor;
const classOf = editor.classOf;
const isSpace = editor.isSpace;

pub fn left(ed: *Editor) void {
    ed.cursor = ed.prevBoundary(ed.cursor);
}

pub fn right(ed: *Editor) void {
    ed.cursor = ed.nextBoundary(ed.cursor);
}

/// `l` as an operator target: up to the line's end, never onto the
/// next line — `dl` (`x`) on the last char takes just that char.
pub fn rightNoCrossLine(ed: *Editor) void {
    const eol = ed.lineEnd(ed.currentLine());
    if (ed.cursor < eol) ed.cursor = ed.nextBoundary(ed.cursor);
}

/// `l` in Normal / Visual under NvChad's `whichwrap+=<>[]hl`: the next
/// char, and from a line's last char (or an empty line) the next line's
/// first — never the slot past the last char. Stays on the last line's
/// last char (`:help 'whichwrap'`).
pub fn rightWrap(ed: *Editor) void {
    const line = ed.currentLine();
    const eol = ed.lineEnd(line);
    const next = ed.nextBoundary(ed.cursor);
    if (ed.cursor < eol and next < eol) {
        ed.cursor = next;
        return;
    }
    if (line + 1 < ed.lineCount()) ed.cursor = ed.lineStart(line + 1);
}

/// `h` under `whichwrap+=h`: the previous char, and from a line's start
/// the previous line's last char.
pub fn leftWrap(ed: *Editor) void {
    const line = ed.currentLine();
    const bol = ed.lineStart(line);
    if (ed.cursor > bol) {
        ed.cursor = ed.prevBoundary(@min(ed.cursor, ed.lineEnd(line)));
        return;
    }
    if (line == 0) return;
    const pbol = ed.lineStart(line - 1);
    const peol = ed.lineEnd(line - 1);
    ed.cursor = if (peol > pbol) ed.prevBoundary(peol) else pbol;
}

/// `h` as an operator target: stops at the line's start.
pub fn leftNoCrossLine(ed: *Editor) void {
    const bol = ed.lineStart(ed.currentLine());
    if (ed.cursor > bol) ed.cursor = ed.prevBoundary(ed.cursor);
}

/// One line up (`dir < 0`) or down, keeping the goal column. On the
/// first / last line nothing moves (`:help j`; `vim -es`: `G$j` stays
/// at 13:22) — a phantom line below the last is never a target.
pub fn vertical(ed: *Editor, dir: i2) void {
    const line = ed.currentLine();
    const target = if (dir < 0) blk: {
        if (line == 0) return;
        break :blk line - 1;
    } else blk: {
        if (line + 1 >= ed.lineCount()) return;
        break :blk line + 1;
    };
    const gc = ed.goalCol();
    ed.cursor = ed.byteAtVcol(target, gc);
}

/// `vertical` as unary motions — the shape a multi-cursor fan-out takes.
pub fn up(ed: *Editor) void {
    vertical(ed, -1);
}

pub fn down(ed: *Editor) void {
    vertical(ed, 1);
}

pub fn page(ed: *Editor, dir: i2, rows: usize) void {
    for (0..@max(rows, 1)) |_| vertical(ed, dir);
}

// ─── word (`w` `b` `e` `ge`) ────────────────────────────────────────────

/// `w`: skip the run under the cursor, then whitespace.
pub fn wordRight(ed: *Editor) void {
    ed.cursor = wordRightFrom(ed, ed.cursor);
}

pub fn wordRightFrom(ed: *const Editor, from: usize) usize {
    const n = ed.len();
    var i = @min(from, n);
    if (ed.charAt(i)) |c| {
        const cls = classOf(c);
        if (cls != .space) {
            while (i < n) {
                const d = ed.charAt(i) orelse break;
                if (classOf(d) != cls) break;
                i = ed.nextBoundary(i);
            }
        }
    }
    while (i < n) {
        const d = ed.charAt(i) orelse break;
        if (classOf(d) != .space) break;
        i = ed.nextBoundary(i);
    }
    return i;
}

/// `dw` shape: like `w` but never past the end of the current line.
pub fn wordRightNoCrossLine(ed: *Editor) void {
    const eol = ed.lineEnd(ed.currentLine());
    wordRight(ed);
    if (ed.cursor > eol) ed.cursor = eol;
}

/// `b`: back over whitespace, then to the start of the run.
pub fn wordLeft(ed: *Editor) void {
    ed.cursor = wordLeftFrom(ed, ed.cursor);
}

pub fn wordLeftFrom(ed: *const Editor, from: usize) usize {
    var i = @min(from, ed.len());
    while (i > 0) {
        const c = ed.charBefore(i) orelse break;
        if (classOf(c) != .space) break;
        i = ed.prevBoundary(i);
    }
    if (ed.charBefore(i)) |c| {
        const cls = classOf(c);
        while (i > 0) {
            const d = ed.charBefore(i) orelse break;
            if (classOf(d) != cls) break;
            i = ed.prevBoundary(i);
        }
    }
    return i;
}

/// `e`: forward to the last char of the current/next word.
pub fn wordEnd(ed: *Editor) void {
    const n = ed.len();
    if (ed.cursor >= n) return;
    var i = ed.nextBoundary(ed.cursor);
    while (i < n) {
        const c = ed.charAt(i) orelse break;
        if (classOf(c) != .space) break;
        i = ed.nextBoundary(i);
    }
    if (ed.charAt(i)) |c| {
        const cls = classOf(c);
        while (i < n) {
            const nxt = ed.nextBoundary(i);
            const d = ed.charAt(nxt) orelse break;
            if (classOf(d) != cls) break;
            i = nxt;
        }
    }
    ed.cursor = i;
}

/// `ge`: back to the last char of the previous word.
pub fn wordEndBack(ed: *Editor) void {
    if (ed.cursor == 0) return;
    var i = ed.prevBoundary(ed.cursor);
    if (ed.charAt(i)) |c| {
        const cls = classOf(c);
        if (cls != .space) {
            while (i > 0) {
                const d = ed.charAt(i) orelse break;
                if (classOf(d) != cls) break;
                i = ed.prevBoundary(i);
            }
        }
    }
    while (i > 0) {
        const d = ed.charAt(i) orelse break;
        if (classOf(d) != .space) break;
        i = ed.prevBoundary(i);
    }
    ed.cursor = i;
}

/// `cw` / `cW` over `n` words (`:help cw`): the cursor's own word ends
/// the first count when the cursor is inside it (staying put when it is
/// already on the last char), a blank under the cursor is crossed like
/// `w`, and every further count is an `e`. The result is one char short
/// of the exclusive end — the operator's inclusive `move_right` covers
/// the last char.
pub fn wordEndCw(ed: *Editor, n: u32, big: bool) void {
    var i: u32 = 0;
    while (i < @max(n, 1)) : (i += 1) {
        const c = ed.charAt(ed.cursor) orelse return;
        if (i == 0) {
            if (c == '\n') return;
            if (isSpace(c)) {
                var target = ed.cursor;
                if (big) {
                    while (target < ed.len()) : (target = ed.nextBoundary(target)) {
                        const d = ed.charAt(target) orelse break;
                        if (!isSpace(d) or d == '\n') break;
                    }
                } else target = wordRightFrom(ed, ed.cursor);
                const eol = ed.lineEnd(ed.currentLine());
                ed.cursor = ed.prevBoundary(@min(@max(target, ed.nextBoundary(ed.cursor)), eol));
                continue;
            }
            if (atWordEnd(ed, big)) continue;
        }
        if (big) bigWordEnd(ed) else wordEnd(ed);
    }
}

/// The cursor is on the last char of a word (`e` would leave it).
fn atWordEnd(ed: *const Editor, big: bool) bool {
    const c = ed.charAt(ed.cursor) orelse return true;
    if (isSpace(c)) return false;
    const next = ed.charAt(ed.nextBoundary(ed.cursor)) orelse return true;
    if (big) return isSpace(next);
    return classOf(next) != classOf(c);
}

// ─── WORD (`W` `B` `E` `gE`) — whitespace is the only boundary ─────────

pub fn bigWordRight(ed: *Editor) void {
    const n = ed.len();
    var i = ed.cursor;
    while (i < n) {
        const c = ed.charAt(i) orelse break;
        if (isSpace(c)) break;
        i = ed.nextBoundary(i);
    }
    while (i < n) {
        const c = ed.charAt(i) orelse break;
        if (!isSpace(c)) break;
        i = ed.nextBoundary(i);
    }
    ed.cursor = i;
}

pub fn bigWordRightNoCrossLine(ed: *Editor) void {
    const eol = ed.lineEnd(ed.currentLine());
    bigWordRight(ed);
    if (ed.cursor > eol) ed.cursor = eol;
}

pub fn bigWordLeft(ed: *Editor) void {
    var i = ed.cursor;
    while (i > 0) {
        const c = ed.charBefore(i) orelse break;
        if (!isSpace(c)) break;
        i = ed.prevBoundary(i);
    }
    while (i > 0) {
        const c = ed.charBefore(i) orelse break;
        if (isSpace(c)) break;
        i = ed.prevBoundary(i);
    }
    ed.cursor = i;
}

pub fn bigWordEnd(ed: *Editor) void {
    const n = ed.len();
    if (ed.cursor >= n) return;
    var i = ed.nextBoundary(ed.cursor);
    while (i < n) {
        const c = ed.charAt(i) orelse break;
        if (!isSpace(c)) break;
        i = ed.nextBoundary(i);
    }
    while (i < n) {
        const nxt = ed.nextBoundary(i);
        const c = ed.charAt(nxt) orelse break;
        if (isSpace(c)) break;
        i = nxt;
    }
    ed.cursor = i;
}

pub fn bigWordEndBack(ed: *Editor) void {
    if (ed.cursor == 0) return;
    var i = ed.prevBoundary(ed.cursor);
    while (i > 0) {
        const c = ed.charAt(i) orelse break;
        if (isSpace(c)) break;
        i = ed.prevBoundary(i);
    }
    while (i > 0) {
        const c = ed.charAt(i) orelse break;
        if (!isSpace(c)) break;
        i = ed.prevBoundary(i);
    }
    ed.cursor = i;
}

// ─── line ───────────────────────────────────────────────────────────────

pub fn lineStart(ed: *Editor) void {
    ed.cursor = ed.lineStart(ed.currentLine());
}

pub fn lineFirstNonWs(ed: *Editor) void {
    ed.cursor = ed.firstNonWs(ed.currentLine());
}

/// `g_`: the last non-blank char (line start when blank).
pub fn lineLastNonWs(ed: *Editor) void {
    const line = ed.currentLine();
    const s = ed.lineStart(line);
    var e = ed.lineEnd(line);
    while (e > s) {
        const c = ed.charBefore(e) orelse break;
        if (!isSpace(c)) break;
        e = ed.prevBoundary(e);
    }
    ed.cursor = if (e == s) s else ed.prevBoundary(e);
}

/// End of line: ON the `\n` (or EOF).
pub fn lineEnd(ed: *Editor) void {
    ed.cursor = ed.lineEnd(ed.currentLine());
}

/// vim `$`: the last printable char, never the `\n`.
pub fn lineLastChar(ed: *Editor) void {
    const line = ed.currentLine();
    const s = ed.lineStart(line);
    const e = ed.lineEnd(line);
    ed.cursor = if (e == s) s else ed.prevBoundary(e);
}

pub fn downFirstNonWs(ed: *Editor) void {
    vertical(ed, 1);
    lineFirstNonWs(ed);
}

pub fn upFirstNonWs(ed: *Editor) void {
    vertical(ed, -1);
    lineFirstNonWs(ed);
}

// ─── paragraph / sentence ───────────────────────────────────────────────

/// `[(` / `[{` (`forward` false): the nearest `open` before the cursor
/// that no `close` between matches; `])` / `]}`: the nearest unmatched
/// `close` after it (`:help [(`). None: the cursor stays (vim beeps).
/// The char under the cursor is never its own answer.
pub fn toUnmatched(ed: *Editor, open: u21, forward: bool) void {
    const close = @import("select.zig").matchCloseFor(open);
    var depth: usize = 0;
    var i = ed.cursor;
    var steps: usize = 0;
    while (steps < 200_000) : (steps += 1) {
        if (forward) {
            if (i >= ed.len()) return;
            i = ed.nextBoundary(i);
            if (i >= ed.len()) return;
        } else {
            if (i == 0) return;
            i = ed.prevBoundary(i);
        }
        const c = ed.charAt(i) orelse return;
        const deeper = if (forward) open else close;
        const target = if (forward) close else open;
        if (c == deeper) {
            depth += 1;
        } else if (c == target) {
            if (depth == 0) {
                ed.cursor = i;
                return;
            }
            depth -= 1;
        }
    }
}

/// `}` / `{` (`:help }`): the next / previous EMPTY line — a line of
/// only blanks is not a paragraph boundary (vim's `startPS`; `vim -es`:
/// with line 3 = `"  "`, `2G}` → 6) — after at least one non-empty line
/// has been passed, the cursor's own line included: from the line just
/// above an empty one `}` lands on that empty line (`5G}` → 6, not the
/// next gap). With no boundary left, forward goes to the END of the
/// last line (`9G}` → 13:22), backward to the buffer start.
pub fn paragraph(ed: *Editor, forward: bool) void {
    const cur = ed.currentLine();
    const count = ed.lineCount();
    if (forward) {
        var passed_text = !lineIsEmpty(ed, cur);
        var row = cur + 1;
        while (row < count) : (row += 1) {
            if (lineIsEmpty(ed, row)) {
                if (passed_text) {
                    ed.cursor = ed.lineStart(row);
                    return;
                }
            } else passed_text = true;
        }
        ed.cursor = ed.lineEnd(count - 1);
    } else {
        if (cur == 0) {
            ed.cursor = 0;
            return;
        }
        var passed_text = !lineIsEmpty(ed, cur);
        var row = cur;
        while (row > 0) {
            row -= 1;
            if (lineIsEmpty(ed, row)) {
                if (passed_text) {
                    ed.cursor = ed.lineStart(row);
                    return;
                }
            } else passed_text = true;
        }
        ed.cursor = 0;
    }
}

fn lineIsEmpty(ed: *const Editor, row: usize) bool {
    return ed.lineStart(row) == ed.lineEnd(row);
}

/// Sentence boundary = `.` `!` `?` followed by whitespace, or a blank
/// line — the common-case approximation the Rust editor uses.
pub fn sentence(ed: *Editor, forward: bool) void {
    const t = ed.bytes();
    const n = t.len;
    if (forward) {
        var i = ed.cursor + 1;
        while (i < n) : (i += 1) {
            if (isTerminator(t[i]) and i + 1 < n and (t[i + 1] == ' ' or t[i + 1] == '\n' or t[i + 1] == '\t')) {
                var j = i + 1;
                while (j < n and (t[j] == ' ' or t[j] == '\t')) j += 1;
                ed.cursor = ed.snapBoundary(j);
                return;
            }
        }
        ed.cursor = n;
    } else {
        var i = ed.cursor -| 1;
        while (i > 0) : (i -= 1) {
            if (isTerminator(t[i]) and i + 1 < n and (t[i + 1] == ' ' or t[i + 1] == '\n' or t[i + 1] == '\t')) {
                var j = i + 1;
                while (j < n and (t[j] == ' ' or t[j] == '\t')) j += 1;
                if (j < ed.cursor) {
                    ed.cursor = ed.snapBoundary(j);
                    return;
                }
            }
        }
        ed.cursor = 0;
    }
}

fn isTerminator(b: u8) bool {
    return b == '.' or b == '!' or b == '?';
}

// ─── buffer / absolute ──────────────────────────────────────────────────

pub fn bufferStart(ed: *Editor) void {
    ed.cursor = 0;
}

/// `G`: the START of the last line — never past a trailing `\n`.
pub fn bufferEnd(ed: *Editor) void {
    ed.cursor = ed.lineStart(ed.lineCount() - 1);
}

/// 1-based line.
pub fn toLine(ed: *Editor, n: usize) void {
    const line = @min(n -| 1, ed.lineCount() - 1);
    ed.cursor = ed.lineStart(line);
}

/// `G` / `gg` / `{n}G` with `nostartofline`: line `n` (1-based; 0 = the
/// last), at the goal column — the one `j` / `k` would keep.
pub fn toLineKeepCol(ed: *Editor, n: usize) void {
    const last = ed.lineCount() - 1;
    const line = if (n == 0) last else @min(n - 1, last);
    const gc = ed.goalCol();
    ed.cursor = ed.byteAtVcol(line, gc);
}

/// 1-based column.
pub fn toCol(ed: *Editor, n: usize) void {
    ed.cursor = ed.byteAtCol(ed.currentLine(), n -| 1);
}

pub fn setCursorByte(ed: *Editor, b: usize) void {
    ed.setCursor(b);
    ed.goal_col = null;
}

/// `f` `F` `t` `T` `;` `,`. `inclusive` (operator-pending) bumps the
/// landing spot one cell forward so the range covers the target. A
/// count is the count-th match, all or nothing: `5fx` on a line with
/// four `x`s stays put (`:help f`), it never stops on the fourth.
pub fn findCharOnLine(ed: *Editor, ch: u21, forward: bool, before: bool, inclusive: bool, repeat: bool, count: u32) void {
    var at = ed.cursor;
    for (0..@max(count, 1)) |i| {
        // Past the first, a `t` / `T` steps over the char it stopped
        // short of, the way `;` does.
        at = findCharFrom(ed, at, ch, forward, before, repeat or i > 0) orelse return;
    }
    ed.cursor = if (inclusive and forward) ed.nextBoundary(at) else at;
    ed.goal_col = null;
}

fn findCharFrom(ed: *Editor, cur: usize, ch: u21, forward: bool, before: bool, repeat: bool) ?usize {
    const line = ed.lineOfByte(cur);
    const ls = ed.lineStart(line);
    const le = ed.lineEnd(line);
    if (forward) {
        var after = @min(ed.nextBoundary(cur), le);
        if (repeat and before) after = @min(ed.nextBoundary(after), le);
        var i = after;
        while (i < le) : (i = ed.nextBoundary(i)) {
            if (ed.charAt(i) == ch) return if (before) ed.prevBoundary(i) else i;
        }
    } else {
        var before_cur = @min(cur, le);
        if (repeat and before) before_cur = @max(ed.prevBoundary(before_cur), ls);
        var i = before_cur;
        while (i > ls) {
            i = ed.prevBoundary(i);
            if (ed.charAt(i) == ch) return if (before) ed.nextBoundary(i) else i;
        }
    }
    return null;
}

// ─── tests ──────────────────────────────────────────────────────────────

// ─── `%` and search matches ──────────────────────────────────────────

const bracket_pairs = [_][2]u8{ .{ '(', ')' }, .{ '[', ']' }, .{ '{', '}' } };

/// `%` (`:help %`): to the bracket paired with the one under the
/// cursor — or, off a bracket, with the first one after it on the line.
/// False (nothing moves) when there is no bracket or no partner; an
/// operator then fails.
pub fn bracketMatch(ed: *Editor) bool {
    const text = ed.bytes();
    var at = ed.cursor;
    const le = ed.lineEnd(ed.currentLine());
    while (at < le and bracketKind(text[at]) == null) at += 1;
    if (at >= le) return false;
    const kind = bracketKind(text[at]).?;
    const pr = bracket_pairs[kind.idx];
    const dest = (if (kind.open) matchForward(text, at, pr[0], pr[1]) else matchBackward(text, at, pr[0], pr[1])) orelse return false;
    ed.cursor = dest;
    return true;
}

fn bracketKind(c: u8) ?struct { idx: usize, open: bool } {
    for (bracket_pairs, 0..) |p, i| {
        if (c == p[0]) return .{ .idx = i, .open = true };
        if (c == p[1]) return .{ .idx = i, .open = false };
    }
    return null;
}

/// The `close` pairing the `open` at `open_byte`, nesting counted.
pub fn matchForward(text: []const u8, open_byte: usize, open: u8, close: u8) ?usize {
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

/// The `open` pairing the `close` at `close_byte`, nesting counted.
pub fn matchBackward(text: []const u8, close_byte: usize, open: u8, close: u8) ?usize {
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

/// `n` / `N` as a motion: to the start of the find match the app seeded
/// after (`forward`) or before the cursor (`Editor.find_after` /
/// `find_before`). False when there is none.
pub fn toFindMatch(ed: *Editor, forward: bool, count: u32) bool {
    const at = (if (forward) ed.find_after else ed.find_before) orelse return false;
    const starts = ed.find_starts.items;
    if (count <= 1 or starts.len == 0) {
        ed.cursor = ed.snapBoundary(@min(at, ed.len()));
        return true;
    }
    // `{count}n`: the `count`th match on from the cursor, wrapping
    // (Neovim: `0d5n` over three matches stops at the second).
    const len = starts.len;
    const step = (count - 1) % len;
    var i: usize = 0;
    if (forward) {
        i = 0;
        for (starts, 0..) |s, k| if (s > ed.cursor) {
            i = k;
            break;
        };
        i = (i + step) % len;
    } else {
        i = len - 1;
        var k = len;
        while (k > 0) {
            k -= 1;
            if (starts[k] < ed.cursor) {
                i = k;
                break;
            }
        }
        i = (i + len - step) % len;
    }
    ed.cursor = ed.snapBoundary(@min(starts[i], ed.len()));
    return true;
}

fn mk(text: []const u8, cursor: usize) !*Editor {
    const ed = try Editor.init(std.testing.allocator, text);
    ed.cursor = cursor;
    return ed;
}

test "word motions: w b e ge over punctuation and lines" {
    const ed = try mk("foo.bar baz\n  qux", 0);
    defer ed.deinit();
    wordRight(ed);
    try std.testing.expectEqual(@as(usize, 3), ed.cursor); // `.`
    wordRight(ed);
    try std.testing.expectEqual(@as(usize, 4), ed.cursor); // bar
    wordRight(ed);
    try std.testing.expectEqual(@as(usize, 8), ed.cursor); // baz
    wordRight(ed);
    try std.testing.expectEqual(@as(usize, 14), ed.cursor); // qux (crossed the line)
    wordLeft(ed);
    try std.testing.expectEqual(@as(usize, 8), ed.cursor);
    ed.cursor = 0;
    wordEnd(ed);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
    wordEnd(ed);
    try std.testing.expectEqual(@as(usize, 3), ed.cursor);
    ed.cursor = 8;
    wordEndBack(ed);
    try std.testing.expectEqual(@as(usize, 6), ed.cursor);
    ed.cursor = 8;
    wordRightNoCrossLine(ed);
    try std.testing.expectEqual(@as(usize, 11), ed.cursor);
}

test "WORD motions treat punctuation as part of the word" {
    const ed = try mk("foo.bar baz", 0);
    defer ed.deinit();
    bigWordRight(ed);
    try std.testing.expectEqual(@as(usize, 8), ed.cursor);
    bigWordLeft(ed);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    bigWordEnd(ed);
    try std.testing.expectEqual(@as(usize, 6), ed.cursor);
    ed.cursor = 9;
    bigWordEndBack(ed);
    try std.testing.expectEqual(@as(usize, 6), ed.cursor);
}

test "vertical keeps the goal column and clamps on the last line" {
    const ed = try mk("abcdef\nab\nabcd", 4);
    defer ed.deinit();
    vertical(ed, 1);
    try std.testing.expectEqual(@as(usize, 9), ed.cursor); // end of `ab`
    vertical(ed, 1);
    try std.testing.expectEqual(@as(usize, 14), ed.cursor); // col 4 of abcd
    vertical(ed, 1);
    try std.testing.expectEqual(@as(usize, 14), ed.cursor); // clamped
    vertical(ed, -1);
    vertical(ed, -1);
    try std.testing.expectEqual(@as(usize, 4), ed.cursor);
}

test "line motions: 0 ^ g_ $ end + -" {
    const ed = try mk("  ab  \nxy", 3);
    defer ed.deinit();
    lineStart(ed);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    lineFirstNonWs(ed);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
    lineLastNonWs(ed);
    try std.testing.expectEqual(@as(usize, 3), ed.cursor);
    lineLastChar(ed);
    try std.testing.expectEqual(@as(usize, 5), ed.cursor);
    lineEnd(ed);
    try std.testing.expectEqual(@as(usize, 6), ed.cursor);
    downFirstNonWs(ed);
    try std.testing.expectEqual(@as(usize, 7), ed.cursor);
    upFirstNonWs(ed);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
}

test "paragraph, buffer end, goto line/col, find char" {
    const ed = try mk("a\nb\n\nc\nd\n\ne\n", 0);
    defer ed.deinit();
    paragraph(ed, true);
    try std.testing.expectEqual(@as(usize, 4), ed.cursor);
    paragraph(ed, true);
    try std.testing.expectEqual(@as(usize, 9), ed.cursor);
    paragraph(ed, false);
    try std.testing.expectEqual(@as(usize, 4), ed.cursor);
    bufferEnd(ed);
    try std.testing.expectEqual(@as(usize, 10), ed.cursor); // the trailing newline opens no line
    toLine(ed, 2);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
    toLine(ed, 999);
    try std.testing.expectEqual(@as(usize, 10), ed.cursor);
    const ed2 = try mk("a-b-c-d", 0);
    defer ed2.deinit();
    findCharOnLine(ed2, '-', true, false, false, false, 1);
    try std.testing.expectEqual(@as(usize, 1), ed2.cursor);
    findCharOnLine(ed2, '-', true, true, false, true, 1); // `;` after a t: skips adjacent
    try std.testing.expectEqual(@as(usize, 2), ed2.cursor);
    findCharOnLine(ed2, 'a', false, false, false, false, 1);
    try std.testing.expectEqual(@as(usize, 0), ed2.cursor);
    toCol(ed2, 5);
    try std.testing.expectEqual(@as(usize, 4), ed2.cursor);
    sentence(ed2, true);
    try std.testing.expectEqual(@as(usize, 7), ed2.cursor);
}

test "findCharOnLine: a count is the count-th match or no move at all" {
    // Neovim on `axbxcxd xe` from column 0: `3fx` → 5, `4fx` → 8,
    // `5fx` stays on 0; `2tx` → 2; `d3fx` takes `axbxcx`.
    const ed = try mk("axbxcxd xe", 0);
    defer ed.deinit();
    findCharOnLine(ed, 'x', true, false, false, false, 3);
    try std.testing.expectEqual(@as(usize, 5), ed.cursor);
    ed.cursor = 0;
    findCharOnLine(ed, 'x', true, false, false, false, 4);
    try std.testing.expectEqual(@as(usize, 8), ed.cursor);
    ed.cursor = 0;
    findCharOnLine(ed, 'x', true, false, false, false, 5);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    findCharOnLine(ed, 'x', true, true, false, false, 2);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
    ed.cursor = 0;
    findCharOnLine(ed, 'x', true, false, true, false, 3);
    try std.testing.expectEqual(@as(usize, 6), ed.cursor);
    // Backward: `$2Fx` → 5.
    ed.cursor = 9;
    findCharOnLine(ed, 'x', false, false, false, false, 2);
    try std.testing.expectEqual(@as(usize, 5), ed.cursor);
}
