//! `Document` — the text and everything that belongs to the text: the
//! line index, the edit log, the undo history, the change list, the
//! file it came from and the language's editing settings. One document
//! may be shown by several `Editor` views at once (vim's one buffer,
//! N windows); it is refcounted by them and knows each one, so a
//! `splice` through any view moves every other view's cursor along.
//!
//! Every mutation goes through `spliceBy` or `setTextBy`, so the line
//! index is always current and the other views are always told.

const std = @import("std");
const detect = @import("highlight").detect;
// Extended grapheme clusters and their cell widths (uucode, through vaxis).
const graphemes = @import("../core/utf8.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const editor_mod = @import("editor.zig");
const Editor = editor_mod.Editor;
const Pos = editor_mod.Pos;
const undo = @import("undo.zig");
const Saved = @import("saved.zig").Saved;
const editorconfig = @import("editorconfig.zig");

/// A (row, byte column) position — what tree-sitter's `InputEdit` wants.
pub const Point = struct { row: u32, col: u32 };

/// One `splice`, in pre-edit byte coordinates plus the points on either
/// side of it. `seq` climbs by one per record, so a consumer that
/// remembers the last `seq` it applied can pull exactly the edits it
/// missed (`EditLog.since`).
pub const Splice = struct {
    start: usize,
    old_end: usize,
    new_end: usize,
    start_pt: Point,
    old_end_pt: Point,
    new_end_pt: Point,
    seq: u64,

    /// Where byte `p` of the pre-edit text sits afterwards: before the
    /// edit it stays, after it shifts by the length delta, inside the
    /// replaced range it lands on the edit's start (where vim leaves a
    /// cursor whose text went away).
    pub fn shift(self: Splice, p: usize) usize {
        if (p <= self.start) return p;
        if (p >= self.old_end) return p - self.old_end + self.new_end;
        return self.start;
    }

    /// Where the (row, byte column) point `p` of the pre-edit text sits
    /// afterwards — `shift` for a consumer that keeps rows and columns
    /// instead of bytes (a breakpoint, a diagnostic). Before the edit it
    /// stays; at or after its end it moves with the text — an insertion
    /// exactly at `p` pushes it along, as Neovim's extmarks and signs do
    /// (`O` above a breakpoint's line takes the breakpoint down with its
    /// line); inside the replaced range it lands on the edit's start.
    /// Only the edit's own last row shifts a column.
    pub fn shiftPoint(self: Splice, p: Point) Point {
        if (pointLess(p, self.start_pt)) return p;
        if (!pointLess(p, self.old_end_pt)) {
            const row: u32 = @intCast(@as(isize, @intCast(p.row)) + self.rowDelta());
            if (p.row != self.old_end_pt.row) return .{ .row = row, .col = p.col };
            // Saturating: a consumer may hold `maxInt(u32)` for "the end
            // of the line" (a script's whole-line diagnostic).
            return .{ .row = row, .col = (p.col - self.old_end_pt.col) +| self.new_end_pt.col };
        }
        return self.start_pt;
    }

    fn pointLess(a: Point, b: Point) bool {
        return a.row < b.row or (a.row == b.row and a.col < b.col);
    }

    /// Rows gained (or lost) by the edit.
    pub fn rowDelta(self: Splice) isize {
        return @as(isize, @intCast(self.new_end_pt.row)) - @as(isize, @intCast(self.old_end_pt.row));
    }
};

/// The incremental-parse contract, kept where the text changes. Every
/// `splice` appends a record; a wholesale replacement (`setText`, an
/// undo restore) has no record and instead bumps `lost_at`, telling a
/// consumer whose `seen` predates it to rebuild from scratch. The log
/// is trimmed by its slowest consumer (`trim`) and capped so a
/// consumer that never reads it cannot grow it without bound.
pub const EditLog = struct {
    items: std.ArrayList(Splice) = .empty,
    next_seq: u64 = 1,
    lost_at: u64 = 0,
    /// The seq of the last splice that stood for a wholesale replacement
    /// (a reload, an undo, a redo). The record itself is precise — the
    /// tree and the language server map across it — but a consumer whose
    /// positions belong to the text as it was TYPED (a snippet's tab
    /// stops, `:g`'s targets, a script's anchors) treats it as the end
    /// of what it can follow.
    replaced_at: u64 = 0,

    pub const cap = 4096;

    /// Records after `seen`, oldest first.
    pub fn since(self: *const EditLog, seen: u64) []const Splice {
        const items = self.items.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].seq <= seen) lo = mid + 1 else hi = mid;
        }
        return items[lo..];
    }

    /// True when the text changed in a way the records after `seen` do
    /// not describe.
    pub fn lostSince(self: *const EditLog, seen: u64) bool {
        return self.lost_at > seen;
    }

    /// True when the text was replaced wholesale after `seen` — whether
    /// the log described it (`replaced_at`) or lost it.
    pub fn replacedSince(self: *const EditLog, seen: u64) bool {
        return self.replaced_at > seen or self.lost_at > seen;
    }

    /// The seq a consumer is current at once it has applied `since(seen)`.
    pub fn head(self: *const EditLog) u64 {
        return self.next_seq - 1;
    }

    /// Drop records at or before `seq` (every consumer has seen them).
    pub fn trim(self: *EditLog, seq: u64) void {
        const items = self.items.items;
        var n: usize = 0;
        while (n < items.len and items[n].seq <= seq) n += 1;
        if (n == 0) return;
        std.mem.copyForwards(Splice, items[0 .. items.len - n], items[n..]);
        self.items.items.len -= n;
    }

    /// The records no longer describe the text: every consumer rebuilds.
    pub fn markLost(self: *EditLog) void {
        self.items.clearRetainingCapacity();
        self.lost_at = self.next_seq;
        self.next_seq += 1;
    }
};

/// What the file watcher last saw on disk for the document's file.
pub const DiskStamp = struct { mtime_ns: i128, size: u64 };

/// Whoever hands out documents (the app's `DocStore`) can ask to be told
/// when the last view lets go, so its index and whatever it keeps per
/// document (the parse tree) go with it. Without an owner the document
/// frees itself.
pub const Owner = struct {
    ctx: *anyopaque,
    drop: *const fn (ctx: *anyopaque, doc: *Document) void,
};

/// Cap for `change_list` — vim's `:changes` shows the last ~100.
pub const change_list_max = 100;

/// `(open, close)` comment tokens for a file extension; both empty for a
/// commentless file so a toggle is a no-op instead of a stray literal.
pub fn commentTokenFor(ext: ?[]const u8) [2][]const u8 {
    const e = ext orelse return .{ "", "" };
    const slash = [_][]const u8{ "zig", "rs", "ts", "tsx", "js", "jsx", "cjs", "mjs", "c", "cpp", "h", "hpp", "cs", "go", "java", "kt", "swift", "php", "scss", "less" };
    const hash = [_][]const u8{ "py", "rb", "sh", "bash", "zsh", "toml", "yaml", "yml", "ini", "conf", "make", "dockerfile", "nix", "hcl", "ex" };
    const dash = [_][]const u8{ "lua", "sql" };
    const angle = [_][]const u8{ "html", "htm", "xml", "vue", "svelte", "astro", "md", "markdown" };
    for (slash) |x| if (std.mem.eql(u8, e, x)) return .{ "// ", "" };
    for (hash) |x| if (std.mem.eql(u8, e, x)) return .{ "# ", "" };
    for (dash) |x| if (std.mem.eql(u8, e, x)) return .{ "-- ", "" };
    for (angle) |x| if (std.mem.eql(u8, e, x)) return .{ "<!-- ", " -->" };
    if (std.mem.eql(u8, e, "css")) return .{ "/* ", " */" };
    return .{ "", "" };
}

/// Who set a per-document preference: the config (it follows the
/// config), the file's `.editorconfig`, or `:setlocal` (both explicit).
pub const PrefSource = enum { config, editorconfig, local };

/// `Document.pref_source`, per preference. `tab_width` covers the
/// indent too (`tab_width`, `indent_unit`), which a config seeds from
/// the one `editor.tab_width`.
pub const PrefSources = struct {
    tab_width: PrefSource = .config,
    /// Only `.local` is ever read: a `:setlocal et` / `noet` that an
    /// `.editorconfig`'s `indent_style` must not undo on the next sync.
    use_tabs: PrefSource = .config,
    auto_indent: PrefSource = .config,
    trim_trailing_ws_on_save: PrefSource = .config,
    ensure_trailing_newline: PrefSource = .config,
};

pub const Document = struct {
    gpa: Allocator,
    text: std.ArrayList(u8) = .empty,
    /// Byte offset of every line's first char; `[0] == 0`, one entry per
    /// `\n` + 1. Maintained incrementally by `spliceBy`.
    line_starts: std.ArrayList(usize) = .empty,
    tab_width: usize = 4,
    /// `>>` / indent pad with one `\t` instead of `tab_width` spaces.
    use_tabs: bool = false,
    /// Carry the previous line's indent on Enter / `o`.
    auto_indent: bool = false,
    /// Insert the matching closer after `(` `[` `{` `"` `'` `` ` ``.
    auto_pair: bool = false,
    /// The language's line-comment token (`// `) and, for block styles
    /// (`<!-- ` … ` -->`), its closer. Static; empty = commentless file.
    comment_token: []const u8 = "",
    comment_token_close: []const u8 = "",
    /// `:changes` — where each mutation left the cursor, newest last.
    change_list: std.ArrayList(Pos) = .empty,
    /// Where typing last stopped — just past the last typed character,
    /// vim's `'^` — which `gi` returns to (`:help gi`).
    last_insert: ?Pos = null,
    history: undo.History,
    /// The view whose coalescing run of typed chars is open; another
    /// view's first char starts its own undo group.
    insert_run_owner: ?*const Editor = null,
    /// Every `spliceBy`, for incremental consumers (the highlighter's
    /// tree, the language server, a snippet session's tab stops).
    edits: EditLog = .{},

    // ─── the file ───

    /// Owned. Null for a scratch document.
    path: ?[]u8 = null,
    dirty: bool = false,
    /// The text as of the last load / save — `dirty` is a comparison —
    /// kept as what differs from the live text (`saved.zig`), not as a
    /// second copy of the file.
    saved: Saved = .{},
    /// `m<letter>` positions — a buffer's, in vim — as byte offsets:
    /// `spliceBy` moves them with the text (`:help mark-motions`), a
    /// mark inside a deleted range landing at the deletion's start.
    /// Byte-anchored here, at the one place every edit from every
    /// window passes, so an app-level splice keeps them right as surely
    /// as a keystroke does.
    marks: std.AutoHashMapUnmanaged(u8, usize) = .empty,
    /// The language key used for language-specific behaviour — what
    /// `highlight.detect` says (the file name, the extension, the
    /// shebang), else the bare extension of a file no grammar knows.
    /// Owned. The statusline chip shows it.
    language: ?[]u8 = null,
    /// Which rule named `language`; the chip's click says so.
    language_how: detect.How = .extension,
    read_only: bool = false,
    /// Rust mnml's `[editor] ensure_trailing_newline`: a file gets its
    /// terminating newline on save.
    ensure_trailing_newline: bool = true,
    /// `[editor] trim_trailing_ws_on_save` / `.editorconfig`
    /// `trim_trailing_whitespace`.
    trim_trailing_ws_on_save: bool = false,
    /// What a save writes between lines. The text is LF in memory
    /// whatever the file had.
    eol: editorconfig.Eol = .lf,
    /// The indent unit the handler types on Tab.
    indent_unit: usize = 4,
    /// A `.editorconfig` named the indent: a formatting request sends
    /// `indent_unit` / `use_tabs` rather than what the text looks like
    /// (`editor/indent.zig`).
    indent_pinned: bool = false,
    /// Where this document's copy of each `editor.*` preference came
    /// from. A config change (a reload, `:set`, a Settings row, the
    /// indent chip — `App.syncBufferPrefs`) copies the config's value
    /// into a pref at `.config` only: one the file's `.editorconfig`
    /// named is re-read from it, and one `:setlocal` set is left alone.
    pref_source: PrefSources = .{},
    /// The file's mtime + size when it was last read or written; the
    /// watcher compares against it. Null for a scratch document.
    disk: ?DiskStamp = null,
    /// The watcher found the file gone (deleted, or renamed away by
    /// another program): the statusline says `(deleted)` until a save
    /// writes it again or it reappears.
    deleted: bool = false,
    /// The edit-log seq the language server has been told about; null
    /// until a server has the file open.
    lsp_seen: ?u64 = null,
    /// The same seq for the Copilot language server (`app/copilot.zig`),
    /// kept apart from `lsp_seen`: the two servers see different sets of
    /// files — Copilot only ever sees the ones the privacy gate allows.
    copilot_seen: ?u64 = null,
    /// The edit-log seq this document's breakpoints were last moved
    /// across (`dap.followBreakpoints`); null until the first follow.
    bp_seen: ?u64 = null,
    /// The same for its diagnostics (`lsp.followDiagnostics`).
    diag_seen: ?u64 = null,

    // ─── views ───

    /// Every `Editor` showing this document. Stable pointers: editors are
    /// heap boxes. A splice through one is pushed to the others.
    views: std.ArrayListUnmanaged(*Editor) = .empty,
    /// Views plus any other holder (`retain`); `release` at zero drops.
    refs: u32 = 0,
    owner: ?Owner = null,

    pub fn create(gpa: Allocator, text: []const u8) Allocator.Error!*Document {
        const copy = try gpa.dupe(u8, text);
        errdefer gpa.free(copy);
        return createOwning(gpa, copy);
    }

    /// `create`, taking `text` (gpa-owned) as the document's text rather
    /// than copying it: a file read into memory is not held twice while
    /// it opens. On error the caller still owns `text`.
    pub fn createOwning(gpa: Allocator, text: []u8) Allocator.Error!*Document {
        const doc = try gpa.create(Document);
        errdefer gpa.destroy(doc);
        doc.* = .{ .gpa = gpa, .history = .init(gpa) };
        doc.text = .fromOwnedSlice(text);
        // The caller keeps `text` on error: only the index is ours to undo.
        errdefer doc.line_starts.deinit(gpa);
        // The history spells its states against the text.
        doc.history.live = &doc.text;
        try doc.rebuildLineIndex();
        return doc;
    }

    /// Frees the document's memory. Callers go through `release`.
    pub fn destroy(self: *Document) void {
        const gpa = self.gpa;
        self.text.deinit(gpa);
        self.line_starts.deinit(gpa);
        self.change_list.deinit(gpa);
        self.edits.items.deinit(gpa);
        self.history.deinit();
        if (self.path) |p| gpa.free(p);
        self.saved.deinit(gpa);
        self.marks.deinit(gpa);
        if (self.language) |l| gpa.free(l);
        self.views.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn retain(self: *Document) void {
        self.refs += 1;
    }

    /// One holder fewer; the last one out frees the document (through
    /// the owner when there is one).
    pub fn release(self: *Document) void {
        assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs > 0) return;
        if (self.owner) |o| o.drop(o.ctx, self) else self.destroy();
    }

    pub fn attachView(self: *Document, v: *Editor) Allocator.Error!void {
        try self.views.append(self.gpa, v);
        self.retain();
    }

    pub fn detachView(self: *Document, v: *Editor) void {
        if (std.mem.indexOfScalar(*Editor, self.views.items, v)) |i| _ = self.views.swapRemove(i);
        if (self.insert_run_owner == v) self.insert_run_owner = null;
        self.release();
    }

    /// How many `Editor`s show this document.
    pub fn viewCount(self: *const Document) usize {
        return self.views.items.len;
    }

    /// True when a view other than `me` shows the document — closing
    /// `me` loses nothing.
    pub fn hasOtherView(self: *const Document, me: *const Editor) bool {
        for (self.views.items) |v| if (v != me) return true;
        return false;
    }

    // ─── text access ────────────────────────────────────────────────

    pub fn bytes(self: *const Document) []const u8 {
        return self.text.items;
    }

    pub fn len(self: *const Document) usize {
        return self.text.items.len;
    }

    /// Replace the whole text (a file reload, a formatter's answer). The
    /// two texts are compared and what differs — everything between
    /// their common prefix and common suffix, widened to char boundaries
    /// — goes through `spliceBy` as ONE precise edit: the line index is
    /// patched, the highlighter's tree is told what moved instead of
    /// being thrown away, and the language server hears a range. The
    /// record is also stamped as a replacement (`EditLog.replacedSince`)
    /// for the consumers that must not map positions across one. Every
    /// view but `by` has its positions shifted along. Identical text
    /// changes nothing.
    pub fn setTextBy(self: *Document, text: []const u8, by: ?*const Editor) Allocator.Error!void {
        const old = self.text.items;
        const hull = diffHull(old, text);
        if (hull.start == old.len and hull.start == text.len) return;
        try self.replaceSpanBy(hull.start, old.len - hull.suffix, text[hull.start .. text.len - hull.suffix], by);
    }

    /// `spliceBy`, for a splice that stands for a wholesale replacement
    /// (a reload, an undo, a redo): stamped so, and no view's open run of
    /// typed chars survives it.
    pub fn replaceSpanBy(self: *Document, start: usize, end: usize, new: []const u8, by: ?*const Editor) Allocator.Error!void {
        try self.spliceBy(start, end, new, by);
        self.edits.replaced_at = self.edits.head();
        for (self.views.items) |v| if (v != by) {
            v.in_insert_run = false;
        };
    }

    /// Where two texts differ: the length of their common prefix and of
    /// their common suffix (never overlapping), each pulled back to a
    /// char boundary in BOTH texts so the stretch between is spliceable.
    pub const Hull = struct { start: usize, suffix: usize };

    pub fn diffHull(old: []const u8, new: []const u8) Hull {
        const n = @min(old.len, new.len);
        var p = std.mem.indexOfDiff(u8, old[0..n], new[0..n]) orelse n;
        while (p > 0 and (!boundaryIn(old, p) or !boundaryIn(new, p))) p -= 1;
        const room = n - p;
        var sfx: usize = 0;
        while (sfx < room and old[old.len - 1 - sfx] == new[new.len - 1 - sfx]) sfx += 1;
        while (sfx > 0 and (!boundaryIn(old, old.len - sfx) or !boundaryIn(new, new.len - sfx))) sfx -= 1;
        return .{ .start = p, .suffix = sfx };
    }

    fn boundaryIn(t: []const u8, b: usize) bool {
        return graphemes.isBoundary(t, b);
    }

    /// Mark `letter`'s (row, char col), or null when it is not set.
    pub fn markPos(self: *const Document, letter: u8) ?Pos {
        // `'.` / `` `. ``: where the last change was made (`:help '.`) —
        // the newest entry of the change list `g;` walks.
        if (letter == '.') {
            const items = self.change_list.items;
            return if (items.len == 0) null else items[items.len - 1];
        }
        const b = self.marks.get(letter) orelse return null;
        return self.rowColAt(@min(b, self.text.items.len));
    }

    /// Set (or move) mark `letter` to a (row, char col) — a session
    /// restore, `:k`; the vim `m` sets it at the cursor byte directly.
    pub fn setMarkPos(self: *Document, letter: u8, pos: Pos) Allocator.Error!void {
        const row = @min(pos.row, self.lineCount() - 1);
        try self.marks.put(self.gpa, letter, self.byteAtCol(row, pos.col));
    }

    /// THE mutation chokepoint. Replaces `[start, end)` with `new` and
    /// patches the line index in O(lines) without rescanning the text.
    /// Both ends should be char boundaries. Does not touch `by`'s cursor;
    /// every other view's positions are shifted along.
    ///
    /// A range that is out of the text or cuts a character (a stale
    /// selection whose bytes moved under it) is clamped outward to whole
    /// characters rather than trusted: splitting a UTF-8 sequence would
    /// leave the text invalid, so the edit covers the characters it
    /// touches.
    pub fn spliceBy(self: *Document, start_in: usize, end_in: usize, new: []const u8, by: ?*const Editor) Allocator.Error!void {
        const text_len = self.text.items.len;
        const end_c = @min(end_in, text_len);
        var start = self.snapBoundary(@min(start_in, end_c));
        var end = end_c;
        while (end < text_len and !self.isBoundary(end)) end += 1;
        if (start > end) start = end;
        assert(start <= end and end <= text_len);
        const gpa = self.gpa;
        const nl_new = std.mem.count(u8, new, "\n");
        try self.line_starts.ensureUnusedCapacity(gpa, nl_new);
        try self.edits.items.ensureUnusedCapacity(gpa, 1);
        const start_pt = self.pointAt(start);
        const old_end_pt = self.pointAt(end);
        // The history's two top states share bytes with the text; they
        // take what this edit is about to change before it does.
        try self.history.beforeSplice(start, end);
        try self.saved.beforeSplice(gpa, self.text.items, start, end, new.len);
        try self.text.replaceRange(gpa, start, end - start, new);

        const ls = &self.line_starts;
        // Line starts strictly inside `(start, end]` belonged to newlines
        // that are gone; everything after shifts by the length delta.
        const lo = firstGreater(ls.items, start);
        const hi = firstGreater(ls.items, end);
        const removed = hi - lo;
        if (nl_new > removed) {
            _ = try ls.addManyAt(gpa, lo, nl_new - removed);
        } else if (nl_new < removed) {
            const n = removed - nl_new;
            std.mem.copyForwards(usize, ls.items[lo..], ls.items[lo + n ..]);
            ls.items.len -= n;
        }
        var k = lo;
        for (new, 0..) |b, i| {
            if (b == '\n') {
                ls.items[k] = start + i + 1;
                k += 1;
            }
        }
        const delta: isize = @as(isize, @intCast(new.len)) - @as(isize, @intCast(end - start));
        for (ls.items[lo + nl_new ..]) |*e| e.* = @intCast(@as(isize, @intCast(e.*)) + delta);
        var marks = self.marks.valueIterator();
        while (marks.next()) |m| {
            if (m.* >= end) {
                m.* = m.* - end + start + new.len;
            } else if (m.* > start) {
                m.* = start;
            }
        }

        if (self.edits.items.items.len >= EditLog.cap) self.edits.markLost();
        const new_end = start + new.len;
        const rec: Splice = .{
            .start = start,
            .old_end = end,
            .new_end = new_end,
            .start_pt = start_pt,
            .old_end_pt = old_end_pt,
            .new_end_pt = self.pointAt(new_end),
            .seq = self.edits.next_seq,
        };
        self.edits.items.appendAssumeCapacity(rec);
        self.edits.next_seq += 1;
        for (self.views.items) |v| if (v != by) v.onForeignSplice(rec);
    }

    /// `(row, byte column)` of byte `b` — the shape tree-sitter positions
    /// take. Infallible: the line index is always current.
    pub fn pointAt(self: *const Document, b: usize) Point {
        const row = self.lineOfByte(@min(b, self.text.items.len));
        return .{ .row = @intCast(row), .col = @intCast(@min(b, self.text.items.len) - self.lineStart(row)) };
    }

    /// Full rescan — `create`, `setTextBy`, and the property test that
    /// checks `spliceBy` against it.
    pub fn rebuildLineIndex(self: *Document) Allocator.Error!void {
        self.line_starts.clearRetainingCapacity();
        try self.line_starts.append(self.gpa, 0);
        for (self.text.items, 0..) |b, i| {
            if (b == '\n') try self.line_starts.append(self.gpa, i + 1);
        }
    }

    fn firstGreater(items: []const usize, v: usize) usize {
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] <= v) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    // ─── char boundaries ────────────────────────────────────────────

    /// How far a cluster search looks around a position. Real clusters
    /// are a few dozen bytes; the cap keeps a pathological run linear.
    const cluster_window = 1024;

    /// A unit starts here: a char, or a byte that does not belong to a
    /// well-formed UTF-8 sequence (those step one at a time, see
    /// `core/utf8.zig`).
    pub fn isBoundary(self: *const Document, b: usize) bool {
        return graphemes.isBoundary(self.text.items, b);
    }

    /// The start of the character before `b` — the extended grapheme
    /// cluster, so an emoji family, a flag or `e` + a combining accent is
    /// one step, as it is one cell on screen. A line break is always a
    /// break of its own. `b` is taken to be a cluster boundary.
    pub fn prevBoundary(self: *const Document, b: usize) usize {
        if (b == 0) return 0;
        const t = self.text.items;
        var p = @min(b, t.len) - 1;
        while (p > 0 and !self.isBoundary(p)) p -= 1;
        // ASCII after ASCII (or at the start) always starts its cluster.
        if (t[p] == '\n' or (t[p] < 0x80 and (p == 0 or t[p - 1] < 0x80))) return p;
        // Else walk forward from a known cluster start close behind: a
        // line start, or the second of two ASCII bytes.
        const floor = p -| cluster_window;
        var s = p;
        while (s > floor) : (s -= 1) {
            if (t[s - 1] == '\n') break;
            if (t[s] < 0x80 and t[s - 1] < 0x80 and t[s - 1] != '\r') break;
        }
        s = self.snapBoundary(s);
        var it = graphemes.graphemeIterator(t[s..@min(b, t.len)]);
        var last: usize = p;
        while (it.next()) |g| {
            if (s + g.start >= b) break;
            last = s + g.start;
        }
        return if (last <= p and self.isBoundary(last)) last else p;
    }

    /// The end of the character at `b` — its extended grapheme cluster
    /// (see `prevBoundary`).
    pub fn nextBoundary(self: *const Document, b: usize) usize {
        const t = self.text.items;
        const n = t.len;
        if (b >= n) return n;
        var i = b + 1;
        while (i < n and !self.isBoundary(i)) i += 1;
        if (t[b] == '\n' or (t[b] < 0x80 and (i >= n or t[i] < 0x80))) return i;
        var lim = @min(n, b + cluster_window);
        if (std.mem.indexOfScalarPos(u8, t[0..lim], b, '\n')) |nl| lim = nl;
        var it = graphemes.graphemeIterator(t[b..lim]);
        const g = it.next() orelse return i;
        const end = b + g.len;
        return if (end >= i and self.isBoundary(end)) end else i;
    }

    /// Snap `b` down to the nearest boundary (and into range).
    pub fn snapBoundary(self: *const Document, b: usize) usize {
        var i = @min(b, self.text.items.len);
        while (i > 0 and !self.isBoundary(i)) i -= 1;
        return i;
    }

    pub fn charAt(self: *const Document, b: usize) ?u21 {
        const t = self.text.items;
        if (b >= t.len) return null;
        const n = std.unicode.utf8ByteSequenceLength(t[b]) catch return t[b];
        if (b + n > t.len) return t[b];
        return std.unicode.utf8Decode(t[b .. b + n]) catch t[b];
    }

    pub fn charBefore(self: *const Document, b: usize) ?u21 {
        if (b == 0) return null;
        return self.charAt(self.prevBoundary(b));
    }

    // ─── lines ──────────────────────────────────────────────────────

    /// Lines as every editor counts them: a trailing `\n` terminates the
    /// last line rather than opening an empty one (`"a\nb\n"` is 2).
    /// The index still holds the phantom start so a cursor at EOF has a
    /// line (`lineOfByte` may return `lineCount()`).
    pub fn lineCount(self: *const Document) usize {
        const nl = self.line_starts.items.len - 1;
        if (nl == 0) return 1;
        if (self.text.items[self.text.items.len - 1] == '\n') return nl;
        return nl + 1;
    }

    /// Byte offset of line `line`'s first char (clamped to the last line).
    pub fn lineStart(self: *const Document, line: usize) usize {
        const ls = self.line_starts.items;
        return ls[@min(line, ls.len - 1)];
    }

    /// Byte offset of line `line`'s `\n` (or EOF on the last line).
    pub fn lineEnd(self: *const Document, line: usize) usize {
        const ls = self.line_starts.items;
        const l = @min(line, ls.len - 1);
        if (l + 1 < ls.len) return ls[l + 1] - 1;
        return self.text.items.len;
    }

    pub fn lineOfByte(self: *const Document, b: usize) usize {
        const v = @min(b, self.text.items.len);
        return firstGreater(self.line_starts.items, v) - 1;
    }

    pub fn lineSlice(self: *const Document, line: usize) []const u8 {
        return self.text.items[self.lineStart(line)..self.lineEnd(line)];
    }

    pub fn lineIsBlank(self: *const Document, line: usize) bool {
        for (self.lineSlice(line)) |b| if (!std.ascii.isWhitespace(b)) return false;
        return true;
    }

    /// Byte of char column `col` on `line`, clamped to the line end.
    pub fn byteAtCol(self: *const Document, line: usize, col: usize) usize {
        const start = self.lineStart(line);
        const end = self.lineEnd(line);
        var b = start;
        var c: usize = 0;
        while (b < end and c < col) : (c += 1) b = self.nextBoundary(b);
        return b;
    }

    /// Char column of `b` within its line (`b` is clamped to the text).
    pub fn colAtByte(self: *const Document, b_in: usize) usize {
        const b = @min(b_in, self.text.items.len);
        const line = self.lineOfByte(b);
        var i = self.lineStart(line);
        var c: usize = 0;
        while (i < b) : (c += 1) i = self.nextBoundary(i);
        return c;
    }

    /// Cells the character at `b` takes when it starts at display column
    /// `vcol` — what the editor view paints: a tab runs to the next stop,
    /// a wide cluster (CJK, most emoji) is two, a zero-width one none.
    pub fn cellsAt(self: *const Document, b: usize, vcol: usize) usize {
        const t = self.text.items;
        if (b >= t.len or t[b] == '\n') return 1;
        if (t[b] == '\t') {
            const tw = @max(self.tab_width, 1);
            return tw - vcol % tw;
        }
        if (t[b] >= 0x20 and t[b] < 0x7f) return 1;
        return @min(graphemes.width(t[b..self.nextBoundary(b)], .unicode), 2);
    }

    /// The display column the character at `b` starts on (`b` clamped).
    pub fn vcolAtByte(self: *const Document, b_in: usize) usize {
        const b = @min(b_in, self.text.items.len);
        var i = self.lineStart(self.lineOfByte(b));
        var v: usize = 0;
        while (i < b) {
            v += self.cellsAt(i, v);
            i = self.nextBoundary(i);
        }
        return v;
    }

    /// The character whose cells cover display column `vcol` on `line`
    /// (a tab or a wide glyph under it), the line end when the line is
    /// narrower — where `j` / `k` land, as in Neovim and VS Code.
    pub fn byteAtVcol(self: *const Document, line: usize, vcol: usize) usize {
        const end = self.lineEnd(line);
        var b = self.lineStart(line);
        var v: usize = 0;
        while (b < end) {
            const w = self.cellsAt(b, v);
            if (v + w > vcol) return b;
            v += w;
            b = self.nextBoundary(b);
        }
        return b;
    }

    /// Display cells `line` takes.
    pub fn lineVcols(self: *const Document, line: usize) usize {
        return self.vcolAtByte(self.lineEnd(line));
    }

    pub fn rowColAt(self: *const Document, b: usize) Pos {
        return .{ .row = self.lineOfByte(b), .col = self.colAtByte(b) };
    }

    /// Byte offset of the first non-whitespace char on `line` (line end
    /// when blank).
    pub fn firstNonWs(self: *const Document, line: usize) usize {
        const start = self.lineStart(line);
        const end = self.lineEnd(line);
        var b = start;
        while (b < end) {
            const c = self.charAt(b) orelse break;
            if (!editor_mod.isSpace(c)) break;
            b = self.nextBoundary(b);
        }
        return b;
    }

    /// Leading `' '` / `'\t'` of `line`, optionally only up to `limit`.
    pub fn leadingIndent(self: *const Document, line: usize, limit: ?usize) []const u8 {
        const start = self.lineStart(line);
        var end = self.lineEnd(line);
        if (limit) |l| end = @min(end, l);
        var b = start;
        while (b < end and (self.text.items[b] == ' ' or self.text.items[b] == '\t')) b += 1;
        return self.text.items[start..b];
    }

    // ─── the file ───────────────────────────────────────────────────

    /// Name the file: the path, the language (the detector's key from
    /// the name, the extension or the shebang on the text's first line,
    /// else the extension) and the comment tokens that go with it.
    pub fn setPath(self: *Document, path: []const u8) Allocator.Error!void {
        const copy = try self.gpa.dupe(u8, path);
        if (self.path) |p| self.gpa.free(p);
        self.path = copy;
        if (self.language) |l| self.gpa.free(l);
        self.language = null;
        self.language_how = .extension;
        if (detect.detect(path, self.firstLine())) |d| {
            self.language = try self.gpa.dupe(u8, d.key);
            self.language_how = d.how;
        } else {
            const ext = std.fs.path.extension(path);
            if (ext.len > 1) self.language = try self.gpa.dupe(u8, ext[1..]);
        }
        const tok = commentTokenFor(self.language);
        self.comment_token = tok[0];
        self.comment_token_close = tok[1];
    }

    /// The text's first line (a shebang, if it has one), capped so a
    /// one-line megabyte is not scanned for a `#!`.
    pub fn firstLine(self: *const Document) []const u8 {
        const text = self.text.items;
        const cap = @min(text.len, 256);
        const nl = std.mem.indexOfScalar(u8, text[0..cap], '\n') orelse cap;
        return text[0..nl];
    }

    /// Record the current text as the on-disk text.
    pub fn markSaved(self: *Document) Allocator.Error!void {
        self.saved.reset(self.gpa);
        self.dirty = false;
    }

    /// `dirty` is whether the text differs from the saved text: the
    /// stretches the two do not share, compared.
    pub fn recomputeDirty(self: *Document) void {
        self.dirty = self.saved.differs(self.gpa, self.text.items);
    }

    /// Bytes the saved state holds (none while the text is as saved).
    pub fn savedBytes(self: *const Document) usize {
        return self.saved.bytes();
    }

    /// True when `path` names this document's file.
    pub fn isAt(self: *const Document, path: []const u8) bool {
        const p = self.path orelse return false;
        return std.mem.eql(u8, p, path);
    }
};

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "a document is shared by its views and dropped with the last one" {
    const gpa = testing.allocator;
    const doc = try Document.create(gpa, "ab\ncd");
    doc.retain();
    const a = try Editor.initOn(gpa, doc);
    const b = try Editor.initOn(gpa, doc);
    try testing.expectEqual(@as(usize, 2), doc.viewCount());
    try testing.expectEqual(@as(u32, 3), doc.refs);
    a.deinit();
    try testing.expectEqual(@as(usize, 1), doc.viewCount());
    try testing.expectEqualStrings("ab\ncd", b.bytes());
    b.deinit();
    try testing.expectEqual(@as(u32, 1), doc.refs);
    doc.release();
}

test "dirty is a comparison with the saved text, kept as what differs — not as a second copy" {
    const gpa = testing.allocator;
    const big = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(big);
    @memset(big, 'a');
    const doc = try Document.create(gpa, big);
    doc.retain();
    defer doc.release();
    doc.recomputeDirty();
    try testing.expect(!doc.dirty);
    try testing.expectEqual(@as(usize, 0), doc.savedBytes());
    // Type in the middle: dirty, and the saved state holds a few bytes.
    try doc.spliceBy(5000, 5000, "xyz", null);
    doc.recomputeDirty();
    try testing.expect(doc.dirty);
    try testing.expect(doc.savedBytes() < 16);
    // An edit at the far end too: still a few bytes, not the file between.
    try doc.spliceBy(doc.len(), doc.len(), "tail", null);
    try testing.expect(doc.savedBytes() < 16);
    try doc.spliceBy(doc.len() - 4, doc.len(), "", null);
    // Take it back out: the same text as saved is clean again.
    try doc.spliceBy(5000, 5003, "", null);
    doc.recomputeDirty();
    try testing.expect(!doc.dirty);
    // A same-length change is still a change.
    try doc.spliceBy(10, 11, "b", null);
    doc.recomputeDirty();
    try testing.expect(doc.dirty);
    // Saving makes the text as it stands the saved text.
    try doc.markSaved();
    try testing.expect(!doc.dirty);
    try testing.expectEqual(@as(usize, 0), doc.savedBytes());
    try doc.spliceBy(10, 11, "a", null);
    doc.recomputeDirty();
    try testing.expect(doc.dirty);
    // A wholesale replacement by the saved text is clean too.
    const back = try gpa.dupe(u8, doc.bytes());
    defer gpa.free(back);
    back[10] = 'b';
    try doc.setTextBy(back, null);
    doc.recomputeDirty();
    try testing.expect(!doc.dirty);
}

test "Splice.shift: before stays, after moves by the delta, inside lands on the start" {
    const sp: Splice = .{ .start = 4, .old_end = 6, .new_end = 9, .start_pt = .{ .row = 0, .col = 4 }, .old_end_pt = .{ .row = 0, .col = 6 }, .new_end_pt = .{ .row = 0, .col = 9 }, .seq = 1 };
    try testing.expectEqual(@as(usize, 2), sp.shift(2));
    try testing.expectEqual(@as(usize, 4), sp.shift(4));
    try testing.expectEqual(@as(usize, 4), sp.shift(5));
    try testing.expectEqual(@as(usize, 9), sp.shift(6));
    try testing.expectEqual(@as(usize, 13), sp.shift(10));
}

test "Splice.shiftPoint: rows follow an edit above, an insertion at the point pushes it, a deleted span collapses to its start" {
    const at = struct {
        fn sp(start: Point, old_end: Point, new_end: Point) Splice {
            return .{ .start = 0, .old_end = 0, .new_end = 0, .start_pt = start, .old_end_pt = old_end, .new_end_pt = new_end, .seq = 1 };
        }
    }.sp;
    // `O` on row 3: "new\n" in at (3,0) — row 3's text is row 4 now.
    const open_above = at(.{ .row = 3, .col = 0 }, .{ .row = 3, .col = 0 }, .{ .row = 4, .col = 0 });
    try std.testing.expectEqual(Point{ .row = 4, .col = 0 }, open_above.shiftPoint(.{ .row = 3, .col = 0 }));
    try std.testing.expectEqual(Point{ .row = 2, .col = 5 }, open_above.shiftPoint(.{ .row = 2, .col = 5 }));
    try std.testing.expectEqual(Point{ .row = 8, .col = 2 }, open_above.shiftPoint(.{ .row = 7, .col = 2 }));
    // `dd` on row 1: (1,0)..(2,0) goes; row 1 holds what was row 2.
    const dd = at(.{ .row = 1, .col = 0 }, .{ .row = 2, .col = 0 }, .{ .row = 1, .col = 0 });
    try std.testing.expectEqual(Point{ .row = 1, .col = 0 }, dd.shiftPoint(.{ .row = 1, .col = 0 }));
    try std.testing.expectEqual(Point{ .row = 1, .col = 4 }, dd.shiftPoint(.{ .row = 2, .col = 4 }));
    try std.testing.expectEqual(Point{ .row = 4, .col = 0 }, dd.shiftPoint(.{ .row = 5, .col = 0 }));
    // Three chars typed at (0,2): a column after them on row 0 moves by three.
    const typed = at(.{ .row = 0, .col = 2 }, .{ .row = 0, .col = 2 }, .{ .row = 0, .col = 5 });
    try std.testing.expectEqual(Point{ .row = 0, .col = 9 }, typed.shiftPoint(.{ .row = 0, .col = 6 }));
    try std.testing.expectEqual(Point{ .row = 0, .col = 1 }, typed.shiftPoint(.{ .row = 0, .col = 1 }));
    // "The end of the line" as `maxInt(u32)` stays there, never overflows.
    const eol = std.math.maxInt(u32);
    try std.testing.expectEqual(Point{ .row = 0, .col = eol }, typed.shiftPoint(.{ .row = 0, .col = eol }));
}

test "spliceBy: a range that cuts a character or runs past the end is clamped to whole characters" {
    const gpa = std.testing.allocator;
    const d = try Document.create(gpa, "Ω≈ç!");
    d.retain();
    defer d.release();
    // 1..3 starts inside Ω (2 bytes) and ends inside ≈ (3 bytes).
    try d.spliceBy(1, 3, "x", null);
    try std.testing.expectEqualStrings("xç!", d.text.items);
    try d.spliceBy(3, 99, "", null);
    try std.testing.expectEqualStrings("xç", d.text.items);
    try d.spliceBy(50, 60, "?", null);
    try std.testing.expectEqualStrings("xç?", d.text.items);
}
