//! Yank and put. Linewise payloads always end in `\n`; `paste_after`
//! on the buffer's last line re-shapes the payload so no phantom line
//! appears.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor = @import("editor.zig");
const Editor = editor.Editor;
const Clipboard = editor.Clipboard;
const EditOutcome = @import("edit_op.zig").EditOutcome;
const delete = @import("delete.zig");

pub fn setRegisterHint(clip: *Clipboard, reg: ?u21) void {
    clip.setPendingRegister(reg);
}

/// `yy`.
pub fn yankLine(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    try yankLinesCount(ed, 1, clip, out);
}

/// `<n>yy` / `y<n>j`: `n` lines from the cursor, linewise.
pub fn yankLinesCount(ed: *Editor, n: u32, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    if (n == 0) return;
    const first = ed.currentLine();
    const last = @min(first + n - 1, ed.lineCount() - 1);
    const start = ed.lineStart(first);
    const last_end = ed.lineEnd(last);
    const end = if (last_end < ed.len()) last_end + 1 else last_end;
    const body = ed.bytes()[start..end];
    if (body.len > 0 and body[body.len - 1] == '\n') {
        try clip.setYank(body, true);
    } else {
        const s = try std.mem.concat(ed.gpa, u8, &.{ body, "\n" });
        defer ed.gpa.free(s);
        try clip.setYank(s, true);
    }
    out.clipboard_set = clip.lastWritten();
    out.clipboard_linewise = true;
    out.yanked_range = .{ start, end };
}

pub fn yankSelection(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    const sel = ed.selection() orelse return;
    try clip.setYank(ed.bytes()[sel[0]..sel[1]], false);
    out.clipboard_set = clip.lastWritten();
    out.yanked_range = sel;
    ed.rememberSelection();
}

/// V-mode yank: marks the register linewise so `p` opens a new line.
pub fn yankSelectionLinewise(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    const sel = ed.selection() orelse return;
    const body = ed.bytes()[sel[0]..sel[1]];
    if (body.len > 0 and body[body.len - 1] == '\n') {
        try clip.setYank(body, true);
    } else {
        const s = try std.mem.concat(ed.gpa, u8, &.{ body, "\n" });
        defer ed.gpa.free(s);
        try clip.setYank(s, true);
    }
    out.clipboard_set = clip.lastWritten();
    out.clipboard_linewise = true;
    out.yanked_range = sel;
    ed.rememberSelection();
}

const Where = enum { after, before };
const Land = enum { start, end };

fn put(ed: *Editor, clip: *Clipboard, where: Where, land: Land, out: *EditOutcome) Allocator.Error!void {
    const s = clip.text();
    if (s.len == 0) return;
    try ed.checkpoint();
    if (clip.isLinewise()) {
        const line = ed.currentLine();
        if (where == .after) {
            const eol = ed.lineEnd(line);
            const at_eof = eol >= ed.len();
            const insert_at = if (at_eof) eol else eol + 1;
            if (at_eof and ed.len() > 0) {
                // No `\n` to put after: open a line with `\n` + payload
                // minus its own terminator.
                const trimmed = if (s[s.len - 1] == '\n') s[0 .. s.len - 1] else s;
                const payload = try std.mem.concat(ed.gpa, u8, &.{ "\n", trimmed });
                defer ed.gpa.free(payload);
                try ed.splice(insert_at, insert_at, payload);
                ed.cursor = if (land == .start) insert_at + 1 else insert_at + payload.len;
            } else {
                try ed.splice(insert_at, insert_at, s);
                ed.cursor = if (land == .start) insert_at else insert_at + s.len;
            }
        } else {
            const bol = ed.lineStart(line);
            try ed.splice(bol, bol, s);
            ed.cursor = if (land == .start) bol else bol + s.len;
        }
    } else {
        const at = if (where == .after) @min(ed.nextBoundary(ed.cursor), ed.len()) else ed.cursor;
        try ed.splice(at, at, s);
        ed.cursor = at + s.len;
    }
    ed.anchor = null;
    out.buffer_changed = true;
}

/// `p`.
pub fn pasteAfter(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    try put(ed, clip, .after, .start, out);
}

/// `P`.
pub fn pasteBefore(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    // Charwise `P` lands after the text like Rust mnml; linewise at the
    // line start.
    try put(ed, clip, .before, .start, out);
}

/// `gp`.
pub fn pasteAfterEnd(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    try put(ed, clip, .after, .end, out);
}

/// `gP`.
pub fn pasteBeforeEnd(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    try put(ed, clip, .before, .end, out);
}

/// Modeless paste: replaces the selection, inserts at the cursor.
pub fn paste(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    const s = clip.text();
    if (s.len == 0) return;
    if (!try delete.deleteSelectionIfAny(ed, out)) try ed.checkpoint();
    try ed.splice(ed.cursor, ed.cursor, s);
    ed.cursor += s.len;
    ed.anchor = null;
    out.buffer_changed = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

test "yy then p opens a line below; P above; on the last line no phantom line" {
    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();
    var ed = try Editor.init(std.testing.allocator, "a\nb");
    defer ed.deinit();
    var out: EditOutcome = .{};
    try yankLine(&ed, &clip, &out);
    try std.testing.expectEqualStrings("a\n", out.clipboard_set.?);
    try std.testing.expectEqual([2]usize{ 0, 2 }, out.yanked_range.?);
    try pasteAfter(&ed, &clip, &out);
    try std.testing.expectEqualStrings("a\na\nb", ed.text.items);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
    ed.cursor = 4; // on `b`, the last line
    try pasteAfter(&ed, &clip, &out);
    try std.testing.expectEqualStrings("a\na\nb\na", ed.text.items);
    try std.testing.expectEqual(@as(usize, 6), ed.cursor);
    try pasteBefore(&ed, &clip, &out);
    try std.testing.expectEqualStrings("a\na\nb\na\na", ed.text.items);
    try std.testing.expectEqual(@as(usize, 6), ed.cursor);
}

test "charwise yank/put and modeless paste over a selection" {
    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();
    var ed = try Editor.init(std.testing.allocator, "hello");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.anchor = 0;
    ed.cursor = 2;
    try yankSelection(&ed, &clip, &out);
    try std.testing.expectEqualStrings("he", out.clipboard_set.?);
    ed.anchor = null;
    ed.cursor = 4;
    try pasteAfter(&ed, &clip, &out);
    try std.testing.expectEqualStrings("hellohe", ed.text.items);
    try std.testing.expectEqual(@as(usize, 7), ed.cursor);
    ed.anchor = 0;
    ed.cursor = 5;
    try paste(&ed, &clip, &out);
    try std.testing.expectEqualStrings("hehe", ed.text.items);
    try yankLinesCount(&ed, 3, &clip, &out);
    try std.testing.expectEqualStrings("hehe\n", clip.text());
}
