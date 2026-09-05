//! Selection ops and text objects. A selection is `anchor` + `cursor`;
//! text objects set both.

const std = @import("std");
const editor = @import("editor.zig");
const Editor = editor.Editor;
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

/// The Nth pair of `q` on the cursor's line that contains the cursor.
/// Backslash-escaped quotes do not count.
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
            if (ed.cursor >= o and ed.cursor <= i) return .{ o, i };
            open = null;
        } else open = i;
    }
    return null;
}

pub fn quote(ed: *Editor, q: u21, around: bool) void {
    const p = enclosingQuotePairOnLine(ed, q) orelse return;
    const ql = editor.charLen(q);
    if (around) {
        ed.anchor = p[0];
        ed.cursor = p[1] + ql;
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
    const budget = 50_000;
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
    depth = 0;
    var j = ed.nextBoundary(open_byte);
    steps = 0;
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
        if (steps > budget) return null;
    }
}

pub fn bracket(ed: *Editor, open: u21, around: bool) void {
    const close = matchCloseFor(open);
    const p = enclosingBracketPair(ed, open, close) orelse return;
    if (around) {
        ed.anchor = p[0];
        ed.cursor = p[1] + editor.charLen(close);
    } else {
        ed.anchor = p[0] + editor.charLen(open);
        ed.cursor = p[1];
    }
}

/// Byte range of the paragraph under the cursor; `around` pulls in the
/// trailing blank lines (and their terminator).
pub fn paragraphBounds(ed: *const Editor, around: bool) [2]usize {
    const n = ed.lineCount();
    const cur = ed.currentLine();
    var start = cur;
    if (ed.lineIsBlank(cur)) {
        while (start > 0 and ed.lineIsBlank(start - 1)) start -= 1;
        var end = cur;
        while (end + 1 < n and ed.lineIsBlank(end + 1)) end += 1;
        return .{ ed.lineStart(start), ed.lineEnd(end) };
    }
    while (start > 0 and !ed.lineIsBlank(start - 1)) start -= 1;
    var end = cur;
    while (end + 1 < n and !ed.lineIsBlank(end + 1)) end += 1;
    if (around) {
        while (end + 1 < n and ed.lineIsBlank(end + 1)) end += 1;
    }
    const lo = ed.lineStart(start);
    var hi = ed.lineEnd(end);
    if (around and hi < ed.len() and ed.lineIsBlank(end)) hi += 1;
    return .{ lo, hi };
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

pub fn restoreLastSelection(ed: *Editor) void {
    const s = ed.last_selection orelse return;
    ed.anchor = ed.snapBoundary(s[0]);
    ed.cursor = ed.snapBoundary(s[1]);
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
    var ed = try Editor.init(std.testing.allocator, "foo.bar baz  qux");
    defer ed.deinit();
    ed.cursor = 5;
    innerWord(&ed);
    try std.testing.expectEqualStrings("bar", sel(&ed));
    ed.cursor = 5;
    aroundWord(&ed, false);
    try std.testing.expectEqualStrings("bar ", sel(&ed));
    ed.cursor = 1;
    innerBigWord(&ed);
    try std.testing.expectEqualStrings("foo.bar", sel(&ed));
    ed.cursor = 14;
    aroundWord(&ed, false);
    try std.testing.expectEqualStrings("  qux", sel(&ed));
}

test "quotes and brackets: inner / around, nested" {
    var ed = try Editor.init(std.testing.allocator, "f(a, (b, \"c d\"), e)");
    defer ed.deinit();
    ed.cursor = 10; // inside "c d"
    quote(&ed, '"', false);
    try std.testing.expectEqualStrings("c d", sel(&ed));
    quote(&ed, '"', true);
    try std.testing.expectEqualStrings("\"c d\"", sel(&ed));
    ed.cursor = 10;
    ed.anchor = null;
    bracket(&ed, '(', false);
    try std.testing.expectEqualStrings("b, \"c d\"", sel(&ed));
    ed.cursor = 2;
    ed.anchor = null;
    bracket(&ed, '(', true);
    try std.testing.expectEqualStrings("(a, (b, \"c d\"), e)", sel(&ed));
    ed.cursor = 0;
    ed.anchor = null;
    bracket(&ed, '(', true);
    try std.testing.expect(ed.anchor == null);
}

test "paragraphs and tags" {
    var ed = try Editor.init(std.testing.allocator, "p1a\np1b\n\n\np2\n");
    defer ed.deinit();
    ed.cursor = 5;
    paragraph(&ed, false);
    try std.testing.expectEqualStrings("p1a\np1b", sel(&ed));
    paragraph(&ed, true);
    try std.testing.expectEqualStrings("p1a\np1b\n\n\n", sel(&ed));
    var ed2 = try Editor.init(std.testing.allocator, "<div><p class=x>hi <b>there</b></p><br/></div>");
    defer ed2.deinit();
    ed2.cursor = 17;
    tag(&ed2, false);
    try std.testing.expectEqualStrings("hi <b>there</b>", sel(&ed2));
    tag(&ed2, true);
    try std.testing.expectEqualStrings("<p class=x>hi <b>there</b></p>", sel(&ed2));
    ed2.cursor = 23;
    ed2.anchor = null;
    tag(&ed2, false);
    try std.testing.expectEqualStrings("there", sel(&ed2));
}

test "line-to-end, inclusive, linewise normalize, swap, gv" {
    var ed = try Editor.init(std.testing.allocator, "ab\ncd\nef");
    defer ed.deinit();
    ed.cursor = 1;
    selectLineToEnd(&ed);
    try std.testing.expectEqualStrings("ab\n", sel(&ed));
    selectLineToEnd(&ed);
    try std.testing.expectEqualStrings("ab\ncd\n", sel(&ed));
    selectClear(&ed);
    try std.testing.expect(ed.anchor == null);
    restoreLastSelection(&ed);
    try std.testing.expectEqualStrings("ab\ncd\n", sel(&ed));
    ed.anchor = 3;
    ed.cursor = 4;
    makeSelectionInclusive(&ed);
    try std.testing.expectEqualStrings("cd", sel(&ed));
    makeSelectionInclusive(&ed); // never past the newline
    try std.testing.expectEqualStrings("cd", sel(&ed));
    ed.anchor = 7;
    ed.cursor = 1;
    normalizeLinewiseSelection(&ed);
    try std.testing.expectEqualStrings("ab\ncd\nef", sel(&ed));
    swapAnchorCursor(&ed);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    moveCursorToSelectionStart(&ed);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
}

test "argument object: inner trims, around takes the trailing comma, the last arg takes the leading one" {
    var ed = try Editor.init(std.testing.allocator, "let r = call(foo, bar, baz);\n");
    defer ed.deinit();
    const text = ed.bytes();
    ed.cursor = std.mem.indexOf(u8, text, "bar").?;
    try std.testing.expectEqualSlices(usize, &.{ 18, 21 }, &argumentBounds(&ed, false).?);
    try std.testing.expectEqualSlices(usize, &.{ 18, 23 }, &argumentBounds(&ed, true).?);
    ed.cursor = std.mem.indexOf(u8, text, "baz").?;
    try std.testing.expectEqualSlices(usize, &.{ 21, 26 }, &argumentBounds(&ed, true).?);
    ed.cursor = 0;
    try std.testing.expect(argumentBounds(&ed, false) == null);
}

test "function / class objects go through the installed provider; none installed is a no-op" {
    var ed = try Editor.init(std.testing.allocator, "fn a() { x }");
    defer ed.deinit();
    ed.cursor = 9;
    object(&ed, .function, false);
    try std.testing.expect(ed.anchor == null);
    const Fake = struct {
        fn lookup(_: *anyopaque, _: *const Editor, kind: editor.ObjectKind, _: usize, around: bool) ?[2]usize {
            if (kind != .function) return null;
            return if (around) .{ 0, 12 } else .{ 8, 11 };
        }
    };
    var dummy: u8 = 0;
    ed.objects = .{ .ctx = &dummy, .lookup = &Fake.lookup };
    object(&ed, .function, false);
    try std.testing.expectEqual(@as(?usize, 8), ed.anchor);
    try std.testing.expectEqual(@as(usize, 11), ed.cursor);
    object(&ed, .class, true);
    try std.testing.expectEqual(@as(?usize, 8), ed.anchor); // unchanged: no class
}
