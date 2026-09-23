//! Selection ops and text objects. A selection is `anchor` + `cursor`;
//! text objects set both.

const std = @import("std");
const editor = @import("editor.zig");
const edit_op = @import("edit_op.zig");
const Editor = editor.Editor;
const EditOutcome = edit_op.EditOutcome;
const classOf = editor.classOf;
const isSpace = editor.isSpace;

pub fn selectStart(ed: *Editor) void {
    ed.anchor = ed.cursor;
    for (ed.extra_anchors.items, ed.extra_cursors.items) |*a, c| a.* = c;
}

pub fn selectClear(ed: *Editor) void {
    ed.rememberSelection();
    ed.anchor = null;
    for (ed.extra_anchors.items) |*a| a.* = null;
}

pub fn selectAll(ed: *Editor) void {
    ed.anchor = 0;
    ed.cursor = ed.len();
}

/// vim `V`: anchor at line start, cursor stays.
pub fn selectLine(ed: *Editor) void {
    ed.anchor = ed.lineStart(ed.currentLine());
}

/// VS Code `Ctrl+L`: the whole line including its `\n`; repeated calls
/// extend one line at a time.
pub fn selectLineToEnd(ed: *Editor) void {
    const line = ed.currentLine();
    const ls = ed.lineStart(line);
    const keep = if (ed.anchor) |a| a <= ls else false;
    if (!keep) ed.anchor = ls;
    const end = ed.lineEnd(line);
    ed.cursor = if (end < ed.len()) end + 1 else end;
}

pub fn wordBoundsAt(ed: *const Editor, b: usize) [2]usize {
    const cls = if (ed.charAt(b)) |c| classOf(c) else if (ed.charBefore(b)) |c| classOf(c) else .space;
    var lo = b;
    while (lo > 0) {
        const c = ed.charBefore(lo) orelse break;
        if (classOf(c) != cls) break;
        lo = ed.prevBoundary(lo);
    }
    var hi = b;
    while (hi < ed.len()) {
        const c = ed.charAt(hi) orelse break;
        if (classOf(c) != cls) break;
        hi = ed.nextBoundary(hi);
    }
    return .{ lo, hi };
}

pub fn bigWordBoundsAt(ed: *const Editor, b: usize) [2]usize {
    const center = if (ed.charAt(b)) |c| isSpace(c) else if (ed.charBefore(b)) |c| isSpace(c) else true;
    var lo = b;
    while (lo > 0) {
        const c = ed.charBefore(lo) orelse break;
        if (isSpace(c) != center) break;
        lo = ed.prevBoundary(lo);
    }
    var hi = b;
    while (hi < ed.len()) {
        const c = ed.charAt(hi) orelse break;
        if (isSpace(c) != center) break;
        hi = ed.nextBoundary(hi);
    }
    return .{ lo, hi };
}

/// `iw` (and the modeless "select word").
pub fn innerWord(ed: *Editor) void {
    const b = wordBoundsAt(ed, ed.cursor);
    ed.anchor = b[0];
    ed.cursor = b[1];
}

pub fn innerBigWord(ed: *Editor) void {
    const b = bigWordBoundsAt(ed, ed.cursor);
    ed.anchor = b[0];
    ed.cursor = b[1];
}

/// `aw`: the word plus trailing blanks, or leading blanks when at EOL.
pub fn aroundWord(ed: *Editor, big: bool) void {
    const b = if (big) bigWordBoundsAt(ed, ed.cursor) else wordBoundsAt(ed, ed.cursor);
    const t = ed.bytes();
    var hi = b[1];
    var extended = false;
    while (hi < t.len and (t[hi] == ' ' or t[hi] == '\t')) : (hi += 1) extended = true;
    var lo = b[0];
    if (!extended) {
        while (lo > 0 and (t[lo - 1] == ' ' or t[lo - 1] == '\t')) lo -= 1;
    }
    ed.anchor = lo;
    ed.cursor = hi;
}

/// The pair of `q` on the cursor's line that contains the cursor, or —
/// with the cursor before any quote — the first pair after it (`:help
/// i"`: "when the cursor is not inside a quoted string, the first one
/// after it on the line is used"). Pairs are counted from the line
/// start; backslash-escaped quotes do not count.
pub fn enclosingQuotePairOnLine(ed: *const Editor, q: u21) ?[2]usize {
    const line = ed.currentLine();
    const ls = ed.lineStart(line);
    const le = ed.lineEnd(line);
    var open: ?usize = null;
    var i = ls;
    while (i < le) : (i = ed.nextBoundary(i)) {
        if (ed.charAt(i) != q) continue;
        if (i > ls and ed.bytes()[i - 1] == '\\') continue;
        if (open) |o| {
            if (ed.cursor <= i) return .{ o, i };
            open = null;
        } else open = i;
    }
    return null;
}

/// The `q` pair an `i"` / `a"` acts on, as Neovim's `current_quote`
/// finds it (an operator, or a Visual mode with nothing selected yet):
///
/// - the cursor ON a quote: pairs are counted from the line start, and
///   the pair holding the cursor is the one — the quote may open or
///   close it;
/// - anywhere else: the nearest quote before the cursor opens the
///   string and the next one after that closes it, however the quotes
///   before it paired up (`a "b" c "d"` with the cursor on `c` acts on
///   `" c "`); with no quote before the cursor, the first pair after it
///   on the line (`:help i"`).
///
/// A backslash escapes a quote everywhere but in the start-of-line
/// count, where Neovim does not look for one. Byte offsets of the two
/// quote chars; null when the line holds no such pair. The quote chars
/// are ASCII, so the walk is over bytes.
pub fn quoteObjectPair(ed: *const Editor, q: u21) ?[2]usize {
    if (q >= 0x80) return enclosingQuotePairOnLine(ed, q);
    const qc: u8 = @intCast(q);
    const ls = ed.lineStart(ed.currentLine());
    const t = ed.bytes()[ls..ed.lineEnd(ed.currentLine())];
    const cur = ed.cursor - ls;
    if (cur < t.len and t[cur] == qc) {
        var from: usize = 0;
        while (true) {
            const o = nextQuote(t, from, qc, false) orelse return null;
            if (o > cur) return null;
            const c = nextQuote(t, o + 1, qc, true) orelse return null;
            if (cur <= c) return .{ ls + o, ls + c };
            from = c + 1;
        }
    }
    const before = prevQuote(t, cur, qc);
    const o = if (t.len > 0 and t[before] == qc) before else (nextQuote(t, 0, qc, false) orelse return null);
    const c = nextQuote(t, o + 1, qc, true) orelse return null;
    return .{ ls + o, ls + c };
}

/// Neovim's `find_next_quote`: the first `qc` at or after `from`; with
/// `escaped`, a backslash takes the char after it out of the running.
fn nextQuote(t: []const u8, from: usize, qc: u8, escaped: bool) ?usize {
    var i = from;
    while (i < t.len) : (i += 1) {
        if (escaped and t[i] == '\\') {
            i += 1;
            if (i >= t.len) return null;
        } else if (t[i] == qc) return i;
    }
    return null;
}

/// Neovim's `find_prev_quote`: walks back from `cur` and stops on the
/// first `qc` that an even run of backslashes precedes — the caller
/// checks the byte it stopped on, since the walk ends at 0 either way.
fn prevQuote(t: []const u8, cur: usize, qc: u8) usize {
    var i = @min(cur, t.len);
    while (i > 0) {
        i -= 1;
        var n: usize = 0;
        while (i - n > 0 and t[i - n - 1] == '\\') n += 1;
        if (n & 1 == 1) {
            i -= n;
        } else if (t[i] == qc) return i;
    }
    return i;
}

pub fn quote(ed: *Editor, q: u21, around: bool) void {
    const p = quoteObjectPair(ed, q) orelse return;
    const ql = editor.charLen(q);
    if (around) {
        // `a"` takes the white space after the closing quote, or — when
        // there is none — the white space before the opening one.
        const le = ed.lineEnd(ed.currentLine());
        const ls = ed.lineStart(ed.currentLine());
        const t = ed.bytes();
        var lo = p[0];
        var hi = p[1] + ql;
        if (hi < le and isWhite(t[hi])) {
            while (hi < le and isWhite(t[hi])) hi += 1;
        } else {
            while (lo > ls and isWhite(t[lo - 1])) lo -= 1;
        }
        ed.anchor = lo;
        ed.cursor = hi;
    } else {
        ed.anchor = p[0] + ql;
        ed.cursor = p[1];
    }
}

pub fn matchCloseFor(open: u21) u21 {
    return switch (open) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '<' => '>',
        else => open,
    };
}

/// Smallest `open … close` pair around the cursor, depth-aware. Capped
/// at 50k chars per side so a malformed file cannot hang.
pub fn enclosingBracketPair(ed: *const Editor, open: u21, close: u21) ?[2]usize {
    const budget = bracket_budget;
    var depth: usize = 0;
    var i = ed.cursor;
    var steps: usize = 0;
    // A cursor sitting ON the opener counts as inside it.
    const open_byte = if (ed.charAt(i) == open) i else blk: {
        while (true) {
            if (i == 0) return null;
            i = ed.prevBoundary(i);
            const c = ed.charAt(i) orelse return null;
            if (c == close) {
                depth += 1;
            } else if (c == open) {
                if (depth == 0) break :blk i;
                depth -= 1;
            }
            steps += 1;
            if (steps > budget) return null;
        }
    };
    return closerOf(ed, open_byte, open, close);
}

const bracket_budget = 50_000;

/// The `close` that matches the `open` at `open_byte`, depth-aware.
fn closerOf(ed: *const Editor, open_byte: usize, open: u21, close: u21) ?[2]usize {
    var depth: usize = 0;
    var j = ed.nextBoundary(open_byte);
    var steps: usize = 0;
    while (true) {
        if (j >= ed.len()) return null;
        const c = ed.charAt(j) orelse return null;
        if (c == open) {
            depth += 1;
        } else if (c == close) {
            if (depth == 0) return .{ open_byte, j };
            depth -= 1;
        }
        j = ed.nextBoundary(j);
        steps += 1;
        if (steps > bracket_budget) return null;
    }
}

/// With the cursor in no `open … close` pair, the next `open` after it
/// and its match — Neovim's `i(` "If the cursor is not inside a ()
/// block, then find the next "("" (`:help i(`). The search is not held
/// to the cursor's line, and a `close` met on the way cancels the next
/// `open`, as its `findmatchlimit` counts them: in `x ) (a)` from the
/// `x` there is nothing to find.
pub fn nextBracketPair(ed: *const Editor, open: u21, close: u21) ?[2]usize {
    var depth: usize = 0;
    var i = ed.nextBoundary(ed.cursor);
    var steps: usize = 0;
    while (i < ed.len()) : (i = ed.nextBoundary(i)) {
        const c = ed.charAt(i) orelse return null;
        if (c == close) {
            depth += 1;
        } else if (c == open) {
            if (depth == 0) return closerOf(ed, i, open, close);
            depth -= 1;
        }
        steps += 1;
        if (steps > bracket_budget) return null;
    }
    return null;
}

pub fn bracket(ed: *Editor, open: u21, around: bool) void {
    const close = matchCloseFor(open);
    const p = enclosingBracketPair(ed, open, close) orelse nextBracketPair(ed, open, close) orelse return;
    if (around) {
        ed.anchor = p[0];
        ed.cursor = p[1] + editor.charLen(close);
    } else {
        ed.anchor = p[0] + editor.charLen(open);
        ed.cursor = p[1];
    }
}

/// Byte range of the paragraph under the cursor, from its first line's
/// start to its last line's end — the last `\n` excluded, so the range
/// names lines the way a Visual `V` does and an operator widens it
/// (`normalize_linewise_selection`) to take the terminators. `around`
/// (`:help ap`) adds the blank lines after the paragraph; when none
/// follow — the paragraph ends the file — the blank lines before it
/// instead. On a blank line, `ip` is the run of blank lines and `ap`
/// that run plus the paragraph after it.
pub fn paragraphBounds(ed: *const Editor, around: bool) [2]usize {
    const n = ed.lineCount();
    const cur = ed.currentLine();
    var start = cur;
    var end = cur;
    if (ed.lineIsBlank(cur)) {
        while (start > 0 and ed.lineIsBlank(start - 1)) start -= 1;
        while (end + 1 < n and ed.lineIsBlank(end + 1)) end += 1;
        if (around) {
            while (end + 1 < n and !ed.lineIsBlank(end + 1)) end += 1;
        }
        return .{ ed.lineStart(start), ed.lineEnd(end) };
    }
    while (start > 0 and !ed.lineIsBlank(start - 1)) start -= 1;
    while (end + 1 < n and !ed.lineIsBlank(end + 1)) end += 1;
    if (around) {
        if (end + 1 < n) {
            while (end + 1 < n and ed.lineIsBlank(end + 1)) end += 1;
        } else {
            while (start > 0 and ed.lineIsBlank(start - 1)) start -= 1;
        }
    }
    return .{ ed.lineStart(start), ed.lineEnd(end) };
}

/// `is` / `as` (`:help is`): the sentence under the cursor. A sentence
/// runs from the start of the paragraph, or the first non-blank after a
/// terminator (`.` `!` `?` followed by white space or a line end), to
/// the terminator inclusive — or to the paragraph's end when none
/// follows, so a paragraph with no full stop is one sentence and `dis`
/// takes it whole. `as` adds the white space after the sentence, or
/// the white space before it when none follows.
pub fn sentenceBounds(ed: *const Editor, around: bool) [2]usize {
    const t = ed.bytes();
    const para = paragraphBounds(ed, false);
    const ps = para[0];
    const pe = @min(para[1], t.len);
    const cur = @min(ed.cursor, pe);
    // Start: after the last terminator+space run before the cursor.
    var start = ps;
    var i = ps;
    while (i < cur) : (i += 1) {
        if (isTerminator(t[i]) and i + 1 <= pe and (i + 1 == pe or isWhite(t[i + 1]))) {
            var j = i + 1;
            while (j < pe and isWhite(t[j])) j += 1;
            if (j <= cur) start = j;
        }
    }
    // End: the first terminator+space at or after the cursor.
    var end = pe;
    var k = cur;
    while (k < pe) : (k += 1) {
        if (isTerminator(t[k]) and (k + 1 == pe or isWhite(t[k + 1]))) {
            end = k + 1;
            break;
        }
    }
    // A sentence that runs to the paragraph's end takes its line break
    // too (`vim -es`: `dis` on `alpha bravo\ncharlie\n\ndelta` from line
    // 1 leaves `\ndelta`).
    if (end == pe and pe < t.len and t[pe] == '\n') end = pe + 1;
    if (!around) return .{ start, end };
    var e2 = end;
    while (e2 < pe and isWhite(t[e2])) e2 += 1;
    if (e2 > end) return .{ start, e2 };
    var s2 = start;
    while (s2 > ps and isWhite(t[s2 - 1])) s2 -= 1;
    return .{ s2, end };
}

fn isTerminator(b: u8) bool {
    return b == '.' or b == '!' or b == '?';
}

fn isWhite(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n';
}

pub fn sentence(ed: *Editor, around: bool) void {
    const b = sentenceBounds(ed, around);
    ed.anchor = b[0];
    ed.cursor = b[1];
}

pub fn paragraph(ed: *Editor, around: bool) void {
    const b = paragraphBounds(ed, around);
    ed.anchor = b[0];
    ed.cursor = b[1];
}

/// `if` / `af` / `ic` / `ac`: the innermost function or class around the
/// cursor, by the syntax tree the app installed. No provider (a file
/// with no grammar) leaves the selection alone.
pub fn object(ed: *Editor, kind: editor.ObjectKind, around: bool) void {
    const p = ed.objects orelse return;
    const r = p.lookup(p.ctx, ed, kind, ed.cursor, around) orelse return;
    ed.anchor = r[0];
    ed.cursor = r[1];
}

/// Byte range of the argument under the cursor inside the innermost
/// `(...)`: the contents split at top-level commas (depth-balanced over
/// `()[]{}`, quote-aware), trimmed. `around` swallows the trailing comma
/// and the blanks after it — or, on the last argument, the comma and
/// blanks before it.
pub fn argumentBounds(ed: *const Editor, around: bool) ?[2]usize {
    const pair = enclosingBracketPair(ed, '(', ')') orelse return null;
    const t = ed.bytes();
    const body_start = ed.nextBoundary(pair[0]);
    const body_end = pair[1];
    var args: [64][2]usize = undefined;
    var n: usize = 0;
    var depth: usize = 0;
    var in_str: ?u8 = null;
    var arg_start = body_start;
    var i = body_start;
    while (i < body_end) : (i += 1) {
        const b = t[i];
        if (in_str) |q| {
            if (b == q and (i == 0 or t[i - 1] != '\\')) in_str = null;
            continue;
        }
        switch (b) {
            '"', '\'', '`' => in_str = b,
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            ',' => if (depth == 0) {
                if (n == args.len) return null;
                args[n] = .{ arg_start, i };
                n += 1;
                arg_start = i + 1;
            },
            else => {},
        }
    }
    if (n == args.len) return null;
    args[n] = .{ arg_start, body_end };
    n += 1;
    const cur = ed.cursor;
    var idx: ?usize = null;
    for (args[0..n], 0..) |a, k| if (cur >= a[0] and cur <= a[1]) {
        idx = k;
        break;
    };
    const k = idx orelse return null;
    const a = args[k];
    var lo = a[0];
    var hi = a[1];
    while (lo < hi and isBlank(t[lo])) lo += 1;
    while (hi > lo and isBlank(t[hi - 1])) hi -= 1;
    if (!around) return .{ lo, hi };
    // Prefer the trailing comma; the last argument takes the leading one.
    if (k + 1 < n and a[1] < body_end and t[a[1]] == ',') {
        var e = a[1] + 1;
        while (e < body_end and (t[e] == ' ' or t[e] == '\t')) e += 1;
        return .{ lo, e };
    }
    var s = lo;
    while (s > body_start and (t[s - 1] == ' ' or t[s - 1] == '\t')) s -= 1;
    if (s > body_start and t[s - 1] == ',') s -= 1;
    return .{ s, hi };
}

fn isBlank(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r';
}

/// `ia` / `aa`.
pub fn argument(ed: *Editor, around: bool) void {
    const r = argumentBounds(ed, around) orelse return;
    ed.anchor = r[0];
    ed.cursor = r[1];
}

/// `<name …>` … `</name>` around the cursor. Returns the byte ranges of
/// the opening tag and the closing tag: `{ open_start, open_end,
/// close_start, close_end }`. Self-closing and `<!…>` tags are skipped;
/// same-name nesting is honoured.
pub fn enclosingTagPair(ed: *const Editor) ?[4]usize {
    const t = ed.bytes();
    // A cursor ON a `<` counts as inside that tag, so the first search
    // window includes the cursor byte.
    var search_from = @min(ed.cursor + 1, t.len);
    // Walk opening tags backward from the cursor; the first one whose
    // matching closer lies past the cursor wins.
    while (true) {
        const lt = std.mem.lastIndexOfScalar(u8, t[0..search_from], '<') orelse return null;
        search_from = lt;
        const gt = std.mem.indexOfScalarPos(u8, t, lt, '>') orelse continue;
        const inner = t[lt + 1 .. gt];
        if (inner.len == 0 or inner[0] == '/' or inner[0] == '!' or inner[0] == '?') continue;
        if (inner[inner.len - 1] == '/') continue;
        const name = tagName(inner);
        if (name.len == 0) continue;
        if (findClose(t, gt + 1, name)) |close| {
            if (ed.cursor < close[1]) return .{ lt, gt + 1, close[0], close[1] };
        }
    }
}

fn tagName(inner: []const u8) []const u8 {
    var i: usize = 0;
    while (i < inner.len and !std.ascii.isWhitespace(inner[i]) and inner[i] != '/') i += 1;
    return inner[0..i];
}

/// `[start, end)` of the `</name>` matching an opener that ended at
/// `from`, counting same-name openers in between.
fn findClose(t: []const u8, from: usize, name: []const u8) ?[2]usize {
    var depth: usize = 0;
    var i = from;
    while (std.mem.indexOfScalarPos(u8, t, i, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, t, lt, '>') orelse return null;
        const inner = t[lt + 1 .. gt];
        i = gt + 1;
        if (inner.len == 0) continue;
        if (inner[0] == '/') {
            if (std.mem.eql(u8, tagName(inner[1..]), name)) {
                if (depth == 0) return .{ lt, gt + 1 };
                depth -= 1;
            }
        } else if (inner[inner.len - 1] != '/' and inner[0] != '!' and inner[0] != '?') {
            if (std.mem.eql(u8, tagName(inner), name)) depth += 1;
        }
    }
    return null;
}

pub fn tag(ed: *Editor, around: bool) void {
    const p = enclosingTagPair(ed) orelse return;
    if (around) {
        ed.anchor = p[0];
        ed.cursor = p[3];
    } else {
        ed.anchor = p[1];
        ed.cursor = p[2];
    }
}

/// `gv`: the remembered range back, in the shape it was made (`:help
/// gv`). A linewise range closed one past its last line's `\n`, so the
/// cursor steps back onto that line; a block range sets the block
/// anchor rather than the charwise one.
pub fn restoreLastSelection(ed: *Editor, shape: edit_op.SelectionShape) void {
    const s = ed.last_selection orelse return;
    const a = ed.snapBoundary(s[0]);
    var c = ed.snapBoundary(s[1]);
    switch (shape) {
        .charwise => {},
        .linewise => if (c > a and c == ed.lineStart(ed.lineOfByte(c))) {
            c = ed.prevBoundary(c);
        },
        .block => {
            ed.block_anchor = a;
            ed.block_eol = false;
        },
    }
    ed.anchor = a;
    ed.cursor = c;
    ed.goal_col = null;
}

pub fn swapAnchorCursor(ed: *Editor) void {
    const a = ed.anchor orelse return;
    ed.anchor = ed.cursor;
    ed.cursor = a;
    ed.goal_col = null;
}

pub fn moveCursorToSelectionStart(ed: *Editor) void {
    const a = ed.anchor orelse return;
    ed.cursor = @min(a, ed.cursor);
    ed.goal_col = null;
}

/// Widen the high end by one char, never across a `\n`: vim's charwise
/// visual is inclusive.
/// `gn` / `gN` (`:help gn`): the match the app seeded as nearest the
/// cursor becomes the selection — anchor on its first byte, the cursor
/// past its end (an operator's exclusive range) or ON its last char
/// (Visual). `extend` keeps a live anchor (`v…gn` grows the selection).
/// No match: the list is abandoned, so `dgn` / `cgn` / their `.` do
/// nothing rather than act at the cursor.
pub fn selectFindMatch(ed: *Editor, forward: bool, inclusive: bool, extend: bool, out: *EditOutcome) void {
    const r = (if (forward) ed.find_next else ed.find_prev) orelse {
        out.aborted = true;
        return;
    };
    const n = ed.len();
    const start = @min(r[0], n);
    const end = @min(@max(r[1], start), n);
    const last = if (inclusive and end > start) ed.prevBoundary(end) else end;
    if (!(extend and ed.anchor != null)) ed.anchor = start;
    ed.cursor = if (extend and ed.anchor != null and !forward) start else last;
}

pub fn makeSelectionInclusive(ed: *Editor) void {
    if (ed.anchor) |a| {
        const w = widenInclusive(ed, a, ed.cursor);
        ed.anchor = w[0];
        ed.cursor = w[1];
    }
    for (ed.extra_anchors.items, ed.extra_cursors.items) |*a, *c| {
        const av = a.* orelse continue;
        const w = widenInclusive(ed, av, c.*);
        a.* = w[0];
        c.* = w[1];
    }
}

fn widenInclusive(ed: *const Editor, anchor: usize, cursor: usize) [2]usize {
    const hi = @max(anchor, cursor);
    if (hi >= ed.len() or ed.bytes()[hi] == '\n') return .{ anchor, cursor };
    const next = ed.nextBoundary(hi);
    return if (cursor >= anchor) .{ anchor, next } else .{ next, cursor };
}

/// Widen to full lines: anchor at the first line's start, cursor one past
/// the last line's `\n` (or at its end when it is the buffer's last line).
pub fn normalizeLinewiseSelection(ed: *Editor) void {
    const a = ed.anchor orelse return;
    const lo = @min(a, ed.cursor);
    const hi = @max(a, ed.cursor);
    const lo_line = ed.lineOfByte(lo);
    // A cursor sitting exactly on a line start after a downward `V j`
    // still belongs to that line.
    const hi_line = ed.lineOfByte(hi);
    const end = ed.lineEnd(hi_line);
    ed.anchor = ed.lineStart(lo_line);
    ed.cursor = if (end < ed.len()) end + 1 else end;
    ed.goal_col = null;
}

/// `V…c` / `V…S`: anchor at the first line's start, cursor at the last
/// line's end with its `\n` left out, so a replace keeps one empty
/// line where the lines were — the shape `cc` builds (`:help v_c`).
pub fn normalizeLinewiseSelectionInner(ed: *Editor) void {
    const a = ed.anchor orelse return;
    const lo_line = ed.lineOfByte(@min(a, ed.cursor));
    const hi_line = ed.lineOfByte(@max(a, ed.cursor));
    ed.anchor = ed.lineStart(lo_line);
    ed.cursor = ed.lineEnd(hi_line);
    ed.goal_col = null;
}

pub fn continueInsertRun(ed: *Editor) void {
    ed.in_insert_run = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

fn sel(ed: *const Editor) []const u8 {
    return ed.selectedText();
}

test "iw aw iW on a line with punctuation" {
    const ed = try Editor.init(std.testing.allocator, "foo.bar baz  qux");
    defer ed.deinit();
    ed.cursor = 5;
    innerWord(ed);
    try std.testing.expectEqualStrings("bar", sel(ed));
    ed.cursor = 5;
    aroundWord(ed, false);
    try std.testing.expectEqualStrings("bar ", sel(ed));
    ed.cursor = 1;
    innerBigWord(ed);
    try std.testing.expectEqualStrings("foo.bar", sel(ed));
    ed.cursor = 14;
    aroundWord(ed, false);
    try std.testing.expectEqualStrings("  qux", sel(ed));
}

test "quotes and brackets: inner / around, nested" {
    const ed = try Editor.init(std.testing.allocator, "f(a, (b, \"c d\"), e)");
    defer ed.deinit();
    ed.cursor = 10; // inside "c d"
    quote(ed, '"', false);
    try std.testing.expectEqualStrings("c d", sel(ed));
    // `a"` with nothing blank after the string takes the blank before.
    quote(ed, '"', true);
    try std.testing.expectEqualStrings(" \"c d\"", sel(ed));
    ed.cursor = 10;
    ed.anchor = null;
    bracket(ed, '(', false);
    try std.testing.expectEqualStrings("b, \"c d\"", sel(ed));
    ed.cursor = 2;
    ed.anchor = null;
    bracket(ed, '(', true);
    try std.testing.expectEqualStrings("(a, (b, \"c d\"), e)", sel(ed));
    // Before the first `(` the object is the pair after the cursor.
    ed.cursor = 0;
    ed.anchor = null;
    bracket(ed, '(', true);
    try std.testing.expectEqualStrings("(a, (b, \"c d\"), e)", sel(ed));
}

/// What `i<c>` / `a<c>` selects from `cursor` in `text`; null when it
/// finds nothing.
fn objectAt(text: []const u8, cursor: usize, c: u21, around: bool) !?[]u8 {
    const ed = try Editor.init(std.testing.allocator, text);
    defer ed.deinit();
    ed.cursor = cursor;
    switch (c) {
        '"', '\'', '`' => quote(ed, c, around),
        else => bracket(ed, c, around),
    }
    if (ed.anchor == null) return null;
    return try std.testing.allocator.dupe(u8, sel(ed));
}

fn expectObject(text: []const u8, cursor: usize, c: u21, around: bool, want: ?[]const u8) !void {
    const got = try objectAt(text, cursor, c, around);
    defer if (got) |g| std.testing.allocator.free(g);
    if (want) |w| {
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings(w, got.?);
    } else try std.testing.expect(got == null);
}

test "bracket objects look forward from outside a pair, as Neovim's do" {
    // Each line is Neovim 0.12.5 --clean on the same text and column
    // (the key it was probed with, and what it left, in the comment).
    // `ci(` on `foo bar(baz) qux` from the f → `foo bar(X) qux`.
    try expectObject("foo bar(baz) qux", 0, '(', false, "baz");
    // `7|da[` on `a [1] b [2] c` → `a [1] b  c`: the pair after the b.
    try expectObject("a [1] b [2] c", 6, '[', true, "[2]");
    // `ci(` on `go (a (b) c) end` → `go (X) end`: the first ( found.
    try expectObject("go (a (b) c) end", 0, '(', false, "a (b) c");
    // `6|ci(` on `f(x) y (z)` → `f(x) y (X)`: a closed pair behind.
    try expectObject("f(x) y (z)", 5, '(', false, "z");
    // Not held to the line: `ci(` on line 1 of `foo\n(bar)` → `(X)`.
    try expectObject("foo\n(bar)", 0, '(', false, "bar");
    // `di<` / `da{` the same.
    try expectObject("x <a> y", 0, '<', false, "a");
    try expectObject("x {a} y", 0, '{', true, "{a}");
    // An empty pair is still an object: `ci(` on `x ()` → `x (X)`.
    try expectObject("x ()", 0, '(', false, "");
    // Inside a pair, the pair around the cursor wins over one after it.
    try expectObject("(a) (b)", 1, '(', false, "a");
    // Nothing to find: past the last pair, a stray ) that cancels the
    // next (, an opener with no closer, no brackets at all — each one
    // Neovim leaves alone.
    try expectObject("x (a) y", 6, '(', false, null);
    try expectObject("x ) (a) y", 0, '(', false, null);
    try expectObject("x (", 0, '(', false, null);
    try expectObject("x (a", 0, '(', false, null);
    try expectObject("foo bar baz", 0, '(', false, null);
}

test "quote objects pick the string Neovim's do, and a\" takes the white space it does" {
    // Neovim 0.12.5 --clean, same text and column (1-based in the note).
    // `di"` on `x = "foo" y` from the x → `x = "" y`: the first after.
    try expectObject("x = \"foo\" y", 0, '"', false, "foo");
    // `da"` on `x "q" y` → `x y`: the space after the string goes too.
    try expectObject("x \"q\" y", 0, '"', true, "\"q\" ");
    // `$da"` on `x "q"` → `x`: nothing after, so the space before.
    try expectObject("x \"q\"", 4, '"', true, " \"q\"");
    // `da"` on `x  "q"  y` → `x  y`: every blank after, none before.
    try expectObject("x  \"q\"  y", 0, '"', true, "\"q\"  ");
    // `$da"` on `a "b" "c"` → `a "b"`: on a quote, pairs count from
    // the line start, and this one closes the second string.
    try expectObject("a \"b\" \"c\"", 8, '"', true, " \"c\"");
    // `6|di"` / `7|di"` on `a "b" c "d"` → `a "b""d"`: off a quote, the
    // nearest quote behind the cursor opens the string.
    try expectObject("a \"b\" c \"d\"", 5, '"', false, " c ");
    try expectObject("a \"b\" c \"d\"", 6, '"', false, " c ");
    // `11|da"` on `f(a, (b, "c d"), e)` → `f(a, (b,), e)`.
    try expectObject("f(a, (b, \"c d\"), e)", 10, '"', true, " \"c d\"");
    // `ci\`` on `x \`cmd\` y` → `x \`X\` y`; a single quote the same.
    try expectObject("x `cmd` y", 0, '`', false, "cmd");
    try expectObject("x 'q' y", 0, '\'', true, "'q' ");
    // An escaped quote does not close the string.
    try expectObject("s = \"a\\\"b\" end", 0, '"', false, "a\\\"b");
    // No quote on the line — or an opener alone — is nothing.
    try expectObject("foo bar", 0, '"', false, null);
    try expectObject("x \"open", 0, '"', false, null);
}

test "paragraphs and tags" {
    const ed = try Editor.init(std.testing.allocator, "p1a\np1b\n\n\np2\n");
    defer ed.deinit();
    ed.cursor = 5;
    paragraph(ed, false);
    try std.testing.expectEqualStrings("p1a\np1b", sel(ed));
    paragraph(ed, true);
    try std.testing.expectEqualStrings("p1a\np1b\n\n", sel(ed));
    // The last paragraph has no blank line after it: `ap` takes the ones
    // before it. On a blank line `ap` is the blanks plus the paragraph.
    ed.cursor = 10;
    paragraph(ed, true);
    try std.testing.expectEqualStrings("\n\np2", sel(ed));
    ed.cursor = 8;
    paragraph(ed, false);
    try std.testing.expectEqualStrings("\n", sel(ed));
    paragraph(ed, true);
    try std.testing.expectEqualStrings("\n\np2", sel(ed));
    const ed2 = try Editor.init(std.testing.allocator, "<div><p class=x>hi <b>there</b></p><br/></div>");
    defer ed2.deinit();
    ed2.cursor = 17;
    tag(ed2, false);
    try std.testing.expectEqualStrings("hi <b>there</b>", sel(ed2));
    tag(ed2, true);
    try std.testing.expectEqualStrings("<p class=x>hi <b>there</b></p>", sel(ed2));
    ed2.cursor = 23;
    ed2.anchor = null;
    tag(ed2, false);
    try std.testing.expectEqualStrings("there", sel(ed2));
}

test "line-to-end, inclusive, linewise normalize, swap, gv" {
    const ed = try Editor.init(std.testing.allocator, "ab\ncd\nef");
    defer ed.deinit();
    ed.cursor = 1;
    selectLineToEnd(ed);
    try std.testing.expectEqualStrings("ab\n", sel(ed));
    selectLineToEnd(ed);
    try std.testing.expectEqualStrings("ab\ncd\n", sel(ed));
    selectClear(ed);
    try std.testing.expect(ed.anchor == null);
    restoreLastSelection(ed, .charwise);
    try std.testing.expectEqualStrings("ab\ncd\n", sel(ed));
    // Linewise: the cursor comes back on the last selected line, not on
    // the line after it; block: the block anchor is set.
    restoreLastSelection(ed, .linewise);
    try std.testing.expectEqual(@as(usize, 1), ed.lineOfByte(ed.cursor));
    restoreLastSelection(ed, .block);
    try std.testing.expectEqual(@as(?usize, 0), ed.block_anchor);
    ed.block_anchor = null;
    ed.anchor = 3;
    ed.cursor = 4;
    makeSelectionInclusive(ed);
    try std.testing.expectEqualStrings("cd", sel(ed));
    makeSelectionInclusive(ed); // never past the newline
    try std.testing.expectEqualStrings("cd", sel(ed));
    ed.anchor = 7;
    ed.cursor = 1;
    normalizeLinewiseSelection(ed);
    try std.testing.expectEqualStrings("ab\ncd\nef", sel(ed));
    swapAnchorCursor(ed);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    moveCursorToSelectionStart(ed);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
}

test "argument object: inner trims, around takes the trailing comma, the last arg takes the leading one" {
    const ed = try Editor.init(std.testing.allocator, "let r = call(foo, bar, baz);\n");
    defer ed.deinit();
    const text = ed.bytes();
    ed.cursor = std.mem.indexOf(u8, text, "bar").?;
    try std.testing.expectEqualSlices(usize, &.{ 18, 21 }, &argumentBounds(ed, false).?);
    try std.testing.expectEqualSlices(usize, &.{ 18, 23 }, &argumentBounds(ed, true).?);
    ed.cursor = std.mem.indexOf(u8, text, "baz").?;
    try std.testing.expectEqualSlices(usize, &.{ 21, 26 }, &argumentBounds(ed, true).?);
    ed.cursor = 0;
    try std.testing.expect(argumentBounds(ed, false) == null);
}

test "function / class objects go through the installed provider; none installed is a no-op" {
    const ed = try Editor.init(std.testing.allocator, "fn a() { x }");
    defer ed.deinit();
    ed.cursor = 9;
    object(ed, .function, false);
    try std.testing.expect(ed.anchor == null);
    const Fake = struct {
        fn lookup(_: *anyopaque, _: *const Editor, kind: editor.ObjectKind, _: usize, around: bool) ?[2]usize {
            if (kind != .function) return null;
            return if (around) .{ 0, 12 } else .{ 8, 11 };
        }
    };
    var dummy: u8 = 0;
    ed.objects = .{ .ctx = &dummy, .lookup = &Fake.lookup };
    object(ed, .function, false);
    try std.testing.expectEqual(@as(?usize, 8), ed.anchor);
    try std.testing.expectEqual(@as(usize, 11), ed.cursor);
    object(ed, .class, true);
    try std.testing.expectEqual(@as(?usize, 8), ed.anchor); // unchanged: no class
}
