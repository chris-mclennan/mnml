//! `DocStore` — the app's open documents. A file is one `Document`
//! however many windows show it (vim's one buffer, N windows); each
//! window is a `Buffer` holding its own `Editor` view. The store owns
//! what belongs to a document but not to the editor layer: its syntax
//! state (the tree-sitter tree and the highlight spans), so a reparse
//! runs once per document, not once per window.
//!
//! Lifetime is the views': `adopt` registers a document the first
//! `Buffer` created, and the document's last `release` calls back into
//! `drop`, which frees the syntax state and the document together. The
//! store is a heap box so that callback pointer stays good when the
//! `App` that holds it moves.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor_mod = @import("../editor/editor.zig");
const Document = editor_mod.Document;
const syntax = @import("syntax.zig");
const conflict_cache = @import("conflict_cache.zig");

pub const DocStore = struct {
    gpa: Allocator,
    entries: std.ArrayListUnmanaged(*Entry) = .empty,

    /// A document and the app-level state kept per document.
    pub const Entry = struct {
        doc: *Document,
        syntax: syntax.Syntax,
        /// The document's merge-conflict regions, per text generation.
        conflicts: conflict_cache.Cache = .{},
        /// Set when the document opened over `editor.lsp_max_bytes` and
        /// was given no language server — what the statusline chip
        /// reports and why the toast fired. Cleared by
        /// `editor.lsp_this_file`, which also sets `lsp_forced`.
        lsp_limit: ?LspLimit = null,
        /// This document gets a server whatever the ceiling says.
        lsp_forced: bool = false,
    };

    /// The size a document was refused a server at, and the limit that
    /// refused it.
    pub const LspLimit = struct { size_bytes: usize, limit_bytes: u64 };

    pub fn create(gpa: Allocator) Allocator.Error!*DocStore {
        const self = try gpa.create(DocStore);
        self.* = .{ .gpa = gpa };
        return self;
    }

    /// Every view is gone by now (the pane store is torn down first); a
    /// document still here is a leak in the caller, freed anyway.
    pub fn destroy(self: *DocStore) void {
        const gpa = self.gpa;
        for (self.entries.items) |e| {
            e.syntax.deinit();
            e.conflicts.deinit(gpa);
            e.doc.destroy();
            gpa.destroy(e);
        }
        self.entries.deinit(gpa);
        gpa.destroy(self);
    }

    /// Take ownership of `doc` (a fresh one, made by `Buffer.init` /
    /// `Buffer.load`): from here its last release frees it through the
    /// store. Returns the entry so the caller can share its syntax state.
    pub fn adopt(self: *DocStore, doc: *Document) Allocator.Error!*Entry {
        std.debug.assert(doc.owner == null);
        const e = try self.gpa.create(Entry);
        errdefer self.gpa.destroy(e);
        e.* = .{ .doc = doc, .syntax = syntax.Syntax.init(self.gpa) };
        try self.entries.append(self.gpa, e);
        doc.owner = .{ .ctx = self, .drop = &dropCb };
        return e;
    }

    /// The entry for `doc`, which must be adopted.
    pub fn entryOf(self: *DocStore, doc: *const Document) ?*Entry {
        for (self.entries.items) |e| if (e.doc == doc) return e;
        return null;
    }

    /// The open document at `path`, if any.
    pub fn find(self: *DocStore, path: []const u8) ?*Entry {
        for (self.entries.items) |e| if (e.doc.isAt(path)) return e;
        return null;
    }

    pub fn count(self: *const DocStore) usize {
        return self.entries.items.len;
    }

    fn dropCb(ctx: *anyopaque, doc: *Document) void {
        const self: *DocStore = @ptrCast(@alignCast(ctx));
        self.drop(doc);
    }

    /// The last view let go: the syntax state and the document go.
    fn drop(self: *DocStore, doc: *Document) void {
        for (self.entries.items, 0..) |e, i| {
            if (e.doc != doc) continue;
            _ = self.entries.swapRemove(i);
            e.syntax.deinit();
            e.conflicts.deinit(self.gpa);
            e.doc.destroy();
            self.gpa.destroy(e);
            return;
        }
        // Not adopted after all: free it plainly.
        doc.destroy();
    }
};

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Buffer = @import("../editor/buffer.zig").Buffer;

test "doc store: two windows on one path share the document; the last close drops it" {
    const gpa = testing.allocator;
    const store = try DocStore.create(gpa);
    defer store.destroy();
    var a = try Buffer.init(gpa, "one\ntwo\n", .vim, .{});
    try a.setPath("/ws/a.txt");
    const entry = try store.adopt(a.doc);
    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expect(store.find("/ws/a.txt") == entry);
    // The split's window: same document, its own cursor.
    var b = try Buffer.initOn(gpa, entry.doc, .vim, .{});
    try testing.expect(a.doc == b.doc);
    try testing.expectEqual(@as(usize, 2), a.doc.viewCount());
    try testing.expect(a.doc.hasOtherView(a.editor));
    b.editor.setCursor(4);
    try testing.expectEqual(@as(usize, 0), a.editor.cursor);
    // Closing one keeps the document for the other.
    a.deinit();
    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expectEqual(@as(usize, 1), b.doc.viewCount());
    try testing.expect(!b.doc.hasOtherView(b.editor));
    try testing.expectEqualStrings("one\ntwo\n", b.editor.bytes());
    // The last one drops it through the store.
    b.deinit();
    try testing.expectEqual(@as(usize, 0), store.count());
    try testing.expect(store.find("/ws/a.txt") == null);
}

test "doc store: dirty and save are the document's — an edit through one window dirties both, a save from the other cleans both" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const path = try std.fs.path.join(gpa, &.{ pbuf[0..n], "shared.txt" });
    defer gpa.free(path);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "shared.txt", .data = "one\ntwo\n" });
    const store = try DocStore.create(gpa);
    defer store.destroy();
    var a = try Buffer.load(gpa, testing.io, path, .vim, .{});
    _ = try store.adopt(a.doc);
    var b = try Buffer.initOn(gpa, a.doc, .vim, .{});
    defer b.deinit();
    var clip = @import("../editor/clipboard.zig").Clipboard.init(gpa);
    defer clip.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // B sits on "two"; A inserts a line above it: B's cursor follows the text.
    b.editor.setCursor(4);
    _ = try a.applyOps(&.{.{ .replace_range = .{ .start = 0, .end = 0, .text = "zero\n" } }}, &clip, 10, arena.allocator());
    try testing.expect(a.doc.dirty);
    try testing.expect(b.doc.dirty);
    try testing.expectEqual(@as(usize, 9), b.editor.cursor);
    try testing.expectEqualStrings("zero\none\ntwo\n", b.editor.bytes());
    // Save from B: one write, both windows clean, one undo history.
    try b.save(testing.io);
    try testing.expect(!a.doc.dirty);
    try testing.expect(!b.doc.dirty);
    const on_disk = try tmp.dir.readFileAlloc(testing.io, "shared.txt", gpa, .limited(1 << 20));
    defer gpa.free(on_disk);
    try testing.expectEqualStrings("zero\none\ntwo\n", on_disk);
    // Undo from B takes back A's edit: the text, and B's cursor lands on it.
    _ = try b.applyOps(&.{.undo}, &clip, 10, arena.allocator());
    try testing.expectEqualStrings("one\ntwo\n", a.editor.bytes());
    try testing.expectEqual(@as(usize, 0), b.editor.cursor);
    try testing.expect(a.doc.dirty);
    a.deinit();
    try testing.expectEqual(@as(usize, 1), store.count());
}
