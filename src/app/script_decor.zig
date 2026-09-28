//! What a script paints INTO an editor without changing its text, and
//! the diagnostics it publishes (D10, `docs/research/lua-platform-design`
//! step 1). Four decorations — virtual text, a gutter sign, a role over
//! a byte range, a whole-row ground — plus a diagnostics sink that ends
//! up in the same store a language server fills.
//!
//! Three rules hold the design together:
//!
//!   * **Data, never a callback.** A decoration is a row in `items`
//!     that the frame reads. Lua is never entered from the paint loop,
//!     so the 20 ms budget cannot be spent there.
//!   * **Anchored to the text, not to a line number.** Every item keeps
//!     a byte (`Item.byte`) which `sync` moves across every splice the
//!     document logged, with right gravity — an insertion at the anchor
//!     pushes it along, so a line inserted ABOVE a decorated line takes
//!     it with the text. A splice that replaces the anchor's byte kills
//!     the item (deleting a decorated line drops its decoration), and a
//!     wholesale replacement the log cannot describe — an undo, a
//!     reload — puts the dead ones back where they were, so an undo
//!     restores what the edit removed.
//!   * **A namespace is the unit of ownership.** `mnml.decor.clear(ns)`
//!     touches only that namespace; `script.reload` drops every one of
//!     them with the Lua state.
//!
//! D1: the item list and the diagnostic sets are gpa-owned (they
//! outlive the frame); what a paint accessor answers is frame-arena.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const alloc = @import("../core/alloc.zig");
const document = @import("../editor/document.zig");
const Splice = document.Splice;
const editor_view = @import("../ui/editor_view.zig");
const script_view = @import("../ui/script_view.zig");
const Theme = @import("../ui/theme.zig");
const types = @import("../lsp/types.zig");
const lsp = @import("lsp.zig");
const Style = @import("vaxis").Style;

/// How many decorations one workspace's scripts may hold at once. A
/// script that leaks them hits this and gets an error naming it rather
/// than eating the heap.
pub const max_items: usize = 10_000;

pub const Kind = enum { virtual_text, gutter, highlight, line };

/// Where `virtual_text` paints: after the line's last cell, or as a
/// virtual row above or below it.
pub const At = enum { eol, above, below };

/// One piece of virtual text, in the script pane's segment shape —
/// roles only, resolved against the theme at paint time.
pub const Seg = struct {
    text: []u8,
    fg: ?[]u8 = null,
    bg: ?[]u8 = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,

    fn free(self: Seg, gpa: Allocator) void {
        gpa.free(self.text);
        if (self.fg) |f| gpa.free(f);
        if (self.bg) |b| gpa.free(b);
    }

    fn style(self: Seg, theme: *const Theme) Style {
        return script_view.resolve(theme, .{
            .fg = self.fg,
            .bg = self.bg,
            .bold = self.bold,
            .italic = self.italic,
            .underline = self.underline,
        });
    }
};

/// One decoration. `byte` is the anchor — a line's first byte for the
/// line-shaped kinds, the range's start for a highlight.
pub const Item = struct {
    ns: u32,
    pane: PaneId,
    kind: Kind,
    byte: usize,
    /// `highlight` only: the anchor of the range's end.
    end_byte: usize = 0,
    /// The text the anchor named went away; the item paints nothing
    /// until a wholesale restore brings it back.
    dead: bool = false,
    segments: []Seg = &.{},
    at: At = .eol,
    glyph: []u8 = &.{},
    /// A theme role name (`"accent"`); an unknown one paints plain.
    role: []u8 = &.{},
    priority: u8 = editor_view.mark_priority.script,

    fn free(self: Item, gpa: Allocator) void {
        for (self.segments) |s| s.free(gpa);
        gpa.free(self.segments);
        gpa.free(self.glyph);
        gpa.free(self.role);
    }
};

/// Per pane: which document its items are anchored in, and how far the
/// anchors have been moved along its edit log.
pub const PaneTrack = struct {
    /// Compared, never dereferenced: a pane that opened another file
    /// drops the decorations that were about the old one.
    doc: ?*const anyopaque = null,
    seen: u64 = 0,
};

/// One `(namespace, path)` diagnostic set — replaced wholesale by the
/// next `mnml.diagnostics.set` for the same pair.
pub const DiagSet = struct {
    ns: u32,
    path: []u8,
    arena: alloc.SnapshotArena,
    items: []types.Diagnostic = &.{},

    fn destroy(self: *DiagSet, gpa: Allocator) void {
        self.arena.deinit();
        gpa.free(self.path);
    }
};

/// One namespace slot. The id a script holds is the index, so a slot
/// is never removed — a reload of one state frees its names and marks
/// them dead, and every other state's handles keep meaning what they
/// meant.
pub const Ns = struct {
    name: []u8,
    /// The Lua state that made it (`Lua.id`).
    owner: u16,
    live: bool = true,
};

pub const State = struct {
    /// Namespace slots by id; `namespace(owner, name)` is stable for a
    /// name until that state reloads.
    names: std.ArrayListUnmanaged(Ns) = .empty,
    items: std.ArrayListUnmanaged(Item) = .empty,
    tracks: std.AutoHashMapUnmanaged(PaneId, PaneTrack) = .empty,
    diags: std.ArrayListUnmanaged(DiagSet) = .empty,

    pub fn deinit(self: *State, gpa: Allocator) void {
        for (self.names.items) |n| if (n.live) gpa.free(n.name);
        self.names.deinit(gpa);
        for (self.items.items) |it| it.free(gpa);
        self.items.deinit(gpa);
        self.tracks.deinit(gpa);
        for (self.diags.items) |*d| d.destroy(gpa);
        self.diags.deinit(gpa);
    }
};

// ─── namespaces ─────────────────────────────────────────────────────────

/// The id of `owner`'s `name`, made on first use. Two scripts asking
/// for "blame" get two namespaces — the name is theirs, not shared.
pub fn namespace(app: *App, owner: u16, name: []const u8) Allocator.Error!u32 {
    const st = &app.script_decor;
    for (st.names.items, 0..) |n, i| if (n.live and n.owner == owner and std.mem.eql(u8, n.name, name)) return @intCast(i);
    const owned = try app.gpa.dupe(u8, name);
    errdefer app.gpa.free(owned);
    try st.names.append(app.gpa, .{ .name = owned, .owner = owner });
    return @intCast(st.names.items.len - 1);
}

pub fn namespaceName(app: *App, ns: u32) []const u8 {
    const st = &app.script_decor;
    if (ns >= st.names.items.len or !st.names.items[ns].live) return "";
    return st.names.items[ns].name;
}

pub fn namespaceOwner(app: *App, ns: u32) ?u16 {
    const st = &app.script_decor;
    if (ns >= st.names.items.len or !st.names.items[ns].live) return null;
    return st.names.items[ns].owner;
}

pub fn isNamespace(app: *App, ns: u32) bool {
    return ns < app.script_decor.names.items.len and app.script_decor.names.items[ns].live;
}

/// How many decorations each of `state`'s live namespaces holds —
/// `script.doctor`'s column. On `arena`.
pub fn liveCounts(app: *App, arena: Allocator, state: u16) Allocator.Error![]NsCount {
    const st = &app.script_decor;
    var out: std.ArrayListUnmanaged(NsCount) = .empty;
    for (st.names.items, 0..) |n, i| {
        if (!n.live or n.owner != state) continue;
        var count: usize = 0;
        for (st.items.items) |it| if (it.ns == i) {
            count += 1;
        };
        var diags: usize = 0;
        for (st.diags.items) |d| if (d.ns == i) {
            diags += d.items.len;
        };
        try out.append(arena, .{ .name = n.name, .items = count, .diagnostics = diags });
    }
    return out.toOwnedSlice(arena);
}

pub const NsCount = struct { name: []const u8, items: usize, diagnostics: usize };

// ─── anchoring ──────────────────────────────────────────────────────────

/// Where byte `p` goes across `sp`, with right gravity — an insertion
/// AT the anchor pushes it along, so text put in front of a decorated
/// line moves the decoration down with its own text. Null when the
/// splice replaced the byte the anchor named.
fn advance(p: usize, sp: Splice) ?usize {
    if (p < sp.start) return p;
    if (p >= sp.old_end) return p - sp.old_end + sp.new_end;
    return null;
}

/// Move every item of `pane` onto the current text. Cheap when the
/// document has not changed since the last call.
pub fn syncPane(app: *App, pane: PaneId) Allocator.Error!void {
    const st = &app.script_decor;
    const gop = try st.tracks.getOrPut(app.gpa, pane);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const tr = gop.value_ptr;
    const e = app.panes.editor(pane) orelse return;
    const doc = e.buf.doc;
    const ptr: *const anyopaque = doc;
    if (tr.doc != null and tr.doc.? != ptr) {
        // The pane shows another file now: its decorations were about
        // the old one.
        dropPane(app, pane);
        tr.* = .{ .doc = ptr, .seen = doc.edits.head() };
        return;
    }
    tr.doc = ptr;
    const head = doc.edits.head();
    if (tr.seen == head) return;
    if (doc.edits.replacedSince(tr.seen)) {
        // An undo, a reload: the log cannot say what moved, so every
        // item goes back to the byte it was last seen at, clamped into
        // the text — which is exactly where an undo puts it back.
        const len = doc.len();
        for (st.items.items) |*it| {
            if (it.pane != pane) continue;
            it.dead = false;
            it.byte = doc.snapBoundary(@min(it.byte, len));
            it.end_byte = doc.snapBoundary(@min(it.end_byte, len));
        }
        tr.seen = head;
        return;
    }
    for (doc.edits.since(tr.seen)) |sp| {
        for (st.items.items) |*it| {
            if (it.pane != pane or it.dead) continue;
            const moved = advance(it.byte, sp) orelse {
                it.dead = true;
                continue;
            };
            it.byte = moved;
            if (it.kind == .highlight) {
                it.end_byte = advance(it.end_byte, sp) orelse moved;
            }
        }
    }
    tr.seen = head;
}

/// The lowest edit-log seq any pane's decorations are still waiting to
/// be moved across, for `doc`. The frame trims a document's edit log to
/// its slowest consumer, and the decorations are one: without this the
/// records would be dropped before `syncPane` ever saw them, and every
/// anchor would sit still while the text moved under it.
pub fn minSeen(app: *App, doc: *const anyopaque) ?u64 {
    const st = &app.script_decor;
    if (st.items.items.len == 0) return null;
    var lowest: ?u64 = null;
    var it = st.tracks.iterator();
    while (it.next()) |entry| {
        const tr = entry.value_ptr;
        if (tr.doc == null or tr.doc.? != doc) continue;
        var holds = false;
        for (st.items.items) |item| if (item.pane == entry.key_ptr.*) {
            holds = true;
        };
        if (!holds) continue;
        lowest = @min(lowest orelse std.math.maxInt(u64), tr.seen);
    }
    return lowest;
}

/// Every pane that holds decorations, moved onto its current text.
pub fn sync(app: *App) Allocator.Error!void {
    const st = &app.script_decor;
    if (st.items.items.len == 0) return;
    var done: [8]PaneId = undefined;
    var n: usize = 0;
    for (st.items.items) |it| {
        var seen = false;
        for (done[0..n]) |p| if (p == it.pane) {
            seen = true;
        };
        if (seen) continue;
        if (n < done.len) {
            done[n] = it.pane;
            n += 1;
        }
        try syncPane(app, it.pane);
    }
}

// ─── setting ────────────────────────────────────────────────────────────

pub const SetError = error{ TooMany, NotAnEditor, OutOfMemory };

/// The byte a 1-based `line` anchors at: its first byte, clamped to the
/// last line.
fn anchorOfLine(e: *EditorPane, line: u32) usize {
    const ed = e.buf.editor;
    const l = @min(@as(usize, line) -| 1, ed.lineCount() - 1);
    return ed.lineStart(l);
}

fn editorOf(app: *App, pane: PaneId) SetError!*EditorPane {
    return app.panes.editor(pane) orelse error.NotAnEditor;
}

fn push(app: *App, item: Item) SetError!void {
    const st = &app.script_decor;
    // The item's strings stay the CALLER's: every `add*` below wraps this
    // call in an `errdefer` that frees exactly what it adopted. Freeing
    // here too was a double free on the budget path — the DebugAllocator
    // caught it on Linux and not on macOS.
    if (st.items.items.len >= max_items) return error.TooMany;
    try st.items.append(app.gpa, item);
    app.needs_render = true;
}

/// `mnml.decor.virtual_text` — `segments` are adopted (gpa-owned).
pub fn addVirtualText(app: *App, ns: u32, pane: PaneId, line: u32, segments: []Seg, at: At) SetError!void {
    errdefer {
        for (segments) |s| s.free(app.gpa);
        app.gpa.free(segments);
    }
    const e = try editorOf(app, pane);
    try syncPane(app, pane);
    try push(app, .{ .ns = ns, .pane = pane, .kind = .virtual_text, .byte = anchorOfLine(e, line), .segments = segments, .at = at });
}

/// `mnml.decor.gutter` — `glyph` and `role` are adopted.
pub fn addGutter(app: *App, ns: u32, pane: PaneId, line: u32, glyph: []u8, role: []u8, priority: u8) SetError!void {
    errdefer {
        app.gpa.free(glyph);
        app.gpa.free(role);
    }
    const e = try editorOf(app, pane);
    try syncPane(app, pane);
    try push(app, .{ .ns = ns, .pane = pane, .kind = .gutter, .byte = anchorOfLine(e, line), .glyph = glyph, .role = role, .priority = priority });
}

/// `mnml.decor.highlight` — bytes are 0-based, `end` exclusive.
pub fn addHighlight(app: *App, ns: u32, pane: PaneId, start: usize, end: usize, role: []u8) SetError!void {
    errdefer app.gpa.free(role);
    const e = try editorOf(app, pane);
    try syncPane(app, pane);
    const ed = e.buf.editor;
    const len = ed.len();
    const s = ed.doc.snapBoundary(@min(start, len));
    const en = ed.doc.snapBoundary(@min(end, len));
    try push(app, .{ .ns = ns, .pane = pane, .kind = .highlight, .byte = s, .end_byte = @max(s, en), .role = role });
}

/// `mnml.decor.line` — a whole-row ground.
pub fn addLine(app: *App, ns: u32, pane: PaneId, line: u32, role: []u8) SetError!void {
    errdefer app.gpa.free(role);
    const e = try editorOf(app, pane);
    try syncPane(app, pane);
    try push(app, .{ .ns = ns, .pane = pane, .kind = .line, .byte = anchorOfLine(e, line), .role = role });
}

/// `mnml.decor.clear(ns, pane?)`: everything the namespace holds, or
/// only what it holds in one pane. Returns how many went.
pub fn clear(app: *App, ns: u32, pane: ?PaneId) usize {
    const st = &app.script_decor;
    var i: usize = 0;
    var n: usize = 0;
    while (i < st.items.items.len) {
        const it = st.items.items[i];
        if (it.ns == ns and (pane == null or it.pane == pane.?)) {
            it.free(app.gpa);
            _ = st.items.orderedRemove(i);
            n += 1;
            continue;
        }
        i += 1;
    }
    if (n > 0) app.needs_render = true;
    return n;
}

/// A pane closed (or opened another file): its decorations go.
pub fn dropPane(app: *App, pane: PaneId) void {
    const st = &app.script_decor;
    var i: usize = 0;
    while (i < st.items.items.len) {
        if (st.items.items[i].pane == pane) {
            st.items.items[i].free(app.gpa);
            _ = st.items.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

pub fn forgetPane(app: *App, pane: PaneId) void {
    dropPane(app, pane);
    _ = app.script_decor.tracks.remove(pane);
}

/// `script.reload`: every namespace, every decoration and every
/// diagnostic a script published goes.
pub fn reset(app: *App) Allocator.Error!void {
    const st = &app.script_decor;
    const gpa = app.gpa;
    for (st.items.items) |it| it.free(gpa);
    st.items.clearRetainingCapacity();
    st.tracks.clearRetainingCapacity();
    for (st.names.items) |n| if (n.live) gpa.free(n.name);
    st.names.clearRetainingCapacity();
    // The sink's paths are still in the LSP store: republish each as empty.
    while (st.diags.items.len > 0) {
        var set = st.diags.pop().?;
        const path = try gpa.dupe(u8, set.path);
        defer gpa.free(path);
        set.destroy(gpa);
        try republish(app, path);
    }
    app.needs_render = true;
}

/// One state's namespaces go — its decorations and its diagnostics
/// with them; every other script's stay on screen. The slots stay so
/// the handles another state holds keep their meaning.
pub fn resetState(app: *App, state: u16) Allocator.Error!void {
    const st = &app.script_decor;
    const gpa = app.gpa;
    var mine: std.ArrayListUnmanaged(u32) = .empty;
    defer mine.deinit(gpa);
    for (st.names.items, 0..) |*n, i| if (n.live and n.owner == state) {
        try mine.append(gpa, @intCast(i));
    };
    if (mine.items.len == 0) return;
    for (mine.items) |ns| {
        var i: usize = 0;
        while (i < st.items.items.len) {
            if (st.items.items[i].ns == ns) {
                st.items.items[i].free(gpa);
                _ = st.items.orderedRemove(i);
            } else i += 1;
        }
    }
    for (mine.items) |ns| {
        var i: usize = 0;
        while (i < st.diags.items.len) {
            if (st.diags.items[i].ns == ns) {
                var set = st.diags.orderedRemove(i);
                const path = try gpa.dupe(u8, set.path);
                defer gpa.free(path);
                set.destroy(gpa);
                try republish(app, path);
            } else i += 1;
        }
    }
    for (mine.items) |ns| {
        gpa.free(st.names.items[ns].name);
        st.names.items[ns] = .{ .name = &.{}, .owner = state, .live = false };
    }
    app.needs_render = true;
}

// ─── the paint data (frame arena) ───────────────────────────────────────

fn lineOf(e: *EditorPane, byte: usize) u32 {
    return @intCast(e.buf.editor.lineOfByte(@min(byte, e.buf.editor.len())));
}

/// A script's `at = "eol"` texts for `pane`, sorted by byte — the frame
/// merges them with the language server's hints. The renderer clips
/// them at the pane's right edge like every other virtual text.
pub fn virtualTextFor(app: *App, arena: Allocator, pane: PaneId, e: *EditorPane, theme: *const Theme) Allocator.Error![]editor_view.VirtualText {
    const st = &app.script_decor;
    if (st.items.items.len == 0) return &.{};
    try syncPane(app, pane);
    var out: std.ArrayListUnmanaged(editor_view.VirtualText) = .empty;
    for (st.items.items) |it| {
        if (it.pane != pane or it.dead or it.kind != .virtual_text or it.at != .eol) continue;
        const end = e.buf.editor.lineEnd(lineOf(e, it.byte));
        for (it.segments) |s| try out.append(arena, .{ .byte = end, .text = s.text, .style = s.style(theme) });
    }
    std.mem.sort(editor_view.VirtualText, out.items, {}, struct {
        fn lt(_: void, a: editor_view.VirtualText, b: editor_view.VirtualText) bool {
            return a.byte < b.byte;
        }
    }.lt);
    return out.items;
}

/// A script's `above` / `below` rows for `pane`, sorted by line.
pub fn virtualLinesFor(app: *App, arena: Allocator, pane: PaneId, e: *EditorPane, theme: *const Theme) Allocator.Error![]editor_view.VirtualLine {
    const st = &app.script_decor;
    if (st.items.items.len == 0) return &.{};
    try syncPane(app, pane);
    var out: std.ArrayListUnmanaged(editor_view.VirtualLine) = .empty;
    for (st.items.items) |it| {
        if (it.pane != pane or it.dead or it.kind != .virtual_text or it.at == .eol) continue;
        const segs = try arena.alloc(editor_view.VirtualSeg, it.segments.len);
        for (it.segments, 0..) |s, i| segs[i] = .{ .text = s.text, .style = s.style(theme) };
        try out.append(arena, .{ .line = lineOf(e, it.byte), .segments = segs, .below = it.at == .below });
    }
    std.mem.sort(editor_view.VirtualLine, out.items, {}, struct {
        fn lt(_: void, a: editor_view.VirtualLine, b: editor_view.VirtualLine) bool {
            return a.line < b.line;
        }
    }.lt);
    return out.items;
}

/// A script's gutter signs for `pane`, each with its priority.
pub fn gutterMarksFor(app: *App, arena: Allocator, pane: PaneId, e: *EditorPane, theme: *const Theme) Allocator.Error![]editor_view.GutterMark {
    const st = &app.script_decor;
    if (st.items.items.len == 0) return &.{};
    try syncPane(app, pane);
    var out: std.ArrayListUnmanaged(editor_view.GutterMark) = .empty;
    for (st.items.items) |it| {
        if (it.pane != pane or it.dead or it.kind != .gutter) continue;
        const style = script_view.roleStyle(theme, it.role) orelse theme.fg;
        try out.append(arena, .{ .line = lineOf(e, it.byte), .kind = .sign, .glyph = it.glyph, .style = style, .priority = it.priority });
    }
    return out.items;
}

/// A script's highlights for `pane` as spans, sorted and clipped to the
/// text — the frame layers them over the syntax spans.
pub fn highlightsFor(app: *App, arena: Allocator, pane: PaneId, e: *EditorPane, theme: *const Theme) Allocator.Error![]editor_view.Span {
    const st = &app.script_decor;
    if (st.items.items.len == 0) return &.{};
    try syncPane(app, pane);
    const len = e.buf.editor.len();
    var out: std.ArrayListUnmanaged(editor_view.Span) = .empty;
    for (st.items.items) |it| {
        if (it.pane != pane or it.dead or it.kind != .highlight) continue;
        const s = @min(it.byte, len);
        const en = @min(it.end_byte, len);
        if (en <= s) continue;
        try out.append(arena, .{ .start = s, .end = en, .style = script_view.roleStyle(theme, it.role) orelse theme.fg });
    }
    std.mem.sort(editor_view.Span, out.items, {}, struct {
        fn lt(_: void, a: editor_view.Span, b: editor_view.Span) bool {
            return a.start < b.start;
        }
    }.lt);
    // `layerSpans` wants a non-overlapping `over` list: a later
    // highlight that starts inside an earlier one is trimmed to what
    // is left of it.
    var kept: std.ArrayListUnmanaged(editor_view.Span) = .empty;
    var last_end: usize = 0;
    for (out.items) |sp_in| {
        var sp = sp_in;
        if (sp.start < last_end) sp.start = last_end;
        if (sp.end <= sp.start) continue;
        try kept.append(arena, sp);
        last_end = sp.end;
    }
    return kept.items;
}

/// A script's whole-row grounds for `pane`, sorted by line.
pub fn lineGroundsFor(app: *App, arena: Allocator, pane: PaneId, e: *EditorPane, theme: *const Theme) Allocator.Error![]editor_view.LineGround {
    const st = &app.script_decor;
    if (st.items.items.len == 0) return &.{};
    try syncPane(app, pane);
    var out: std.ArrayListUnmanaged(editor_view.LineGround) = .empty;
    for (st.items.items) |it| {
        if (it.pane != pane or it.dead or it.kind != .line) continue;
        const role = script_view.roleStyle(theme, it.role) orelse theme.cursor_line;
        var style = theme.bg;
        style.bg = if (role.bg != .default) role.bg else role.fg;
        try out.append(arena, .{ .line = lineOf(e, it.byte), .style = style });
    }
    std.mem.sort(editor_view.LineGround, out.items, {}, struct {
        fn lt(_: void, a: editor_view.LineGround, b: editor_view.LineGround) bool {
            return a.line < b.line;
        }
    }.lt);
    return out.items;
}

// ─── the diagnostics sink ───────────────────────────────────────────────

fn findSet(st: *State, ns: u32, path: []const u8) ?*DiagSet {
    for (st.diags.items) |*d| if (d.ns == ns and std.mem.eql(u8, d.path, path)) return d;
    return null;
}

/// Every namespace's diagnostics for `path`, merged into the LSP
/// store's script-sink source — so the gutter, the squiggle, the
/// statusline count, the DIAGNOSTICS panel, `]d` and hover all show
/// them beside a server's.
fn republish(app: *App, path: []const u8) Allocator.Error!void {
    const st = &app.script_decor;
    const arena = app.frame.allocator();
    var all: std.ArrayListUnmanaged(types.Diagnostic) = .empty;
    for (st.diags.items) |d| {
        if (!std.mem.eql(u8, d.path, path)) continue;
        try all.appendSlice(arena, d.items);
    }
    try lsp.applyLuaDiagnostics(app, path, all.items);
}

/// `mnml.diagnostics.set(ns, path, list)` — `path` is absolute, `list`
/// borrowed for the call. The pair's previous list is replaced; every
/// other namespace's for the same file stays.
pub fn setDiagnostics(app: *App, ns: u32, path: []const u8, list: []const types.Diagnostic) Allocator.Error!void {
    const st = &app.script_decor;
    const gpa = app.gpa;
    const set = findSet(st, ns, path) orelse blk: {
        const owned = try gpa.dupe(u8, path);
        errdefer gpa.free(owned);
        try st.diags.append(gpa, .{ .ns = ns, .path = owned, .arena = alloc.SnapshotArena.init(gpa) });
        break :blk &st.diags.items[st.diags.items.len - 1];
    };
    set.arena.reset();
    set.items = &.{};
    const a = set.arena.allocator();
    const items = try a.alloc(types.Diagnostic, list.len);
    for (list, 0..) |d_in, i| {
        var d = d_in;
        d.message = try a.dupe(u8, d.message);
        if (d.source) |s| d.source = try a.dupe(u8, s);
        if (d.code) |c| d.code = try a.dupe(u8, c);
        items[i] = d;
    }
    set.items = items;
    try republish(app, path);
}

/// `mnml.diagnostics.clear(ns, path?)`.
pub fn clearDiagnostics(app: *App, ns: u32, path: ?[]const u8) Allocator.Error!void {
    const st = &app.script_decor;
    const gpa = app.gpa;
    var i: usize = 0;
    // The paths that lose a set have to be republished afterwards.
    var touched: std.ArrayListUnmanaged([]const u8) = .empty;
    const arena = app.frame.allocator();
    while (i < st.diags.items.len) {
        const d = st.diags.items[i];
        if (d.ns == ns and (path == null or std.mem.eql(u8, d.path, path.?))) {
            try touched.append(arena, try arena.dupe(u8, d.path));
            var set = st.diags.orderedRemove(i);
            set.destroy(gpa);
            continue;
        }
        i += 1;
    }
    for (touched.items) |p| try republish(app, p);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "decor anchoring: a line inserted above moves it, deleting its line kills it, an undo brings it back" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    const pane = try app.openScratch();
    const e = app.panes.editor(pane).?;
    try app.splice(e, 0, 0, "one\ntwo\nthree\n");
    const ns = try namespace(&app, 0, "blame");
    try addGutter(&app, ns, pane, 2, try testing.allocator.dupe(u8, "▎"), try testing.allocator.dupe(u8, "accent"), 50);
    const st = &app.script_decor;
    try testing.expectEqual(@as(usize, 1), st.items.items.len);
    try testing.expectEqual(@as(u32, 1), lineOf(e, st.items.items[0].byte));
    // A line inserted above: the decoration follows its own text down.
    try app.splice(e, 0, 0, "zero\n");
    try syncPane(&app, pane);
    try testing.expect(!st.items.items[0].dead);
    try testing.expectEqual(@as(u32, 2), lineOf(e, st.items.items[0].byte));
    // Its line deleted: it goes.
    const start = e.buf.editor.lineStart(2);
    const end = e.buf.editor.lineStart(3);
    try app.splice(e, start, end, "");
    try syncPane(&app, pane);
    try testing.expect(st.items.items[0].dead);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try gutterMarksFor(&app, arena.allocator(), pane, e, &app.theme)).len);
    // An undo restores the text — and the decoration with it.
    _ = try app.applyOps(e, &.{.undo});
    try syncPane(&app, pane);
    try testing.expect(!st.items.items[0].dead);
    try testing.expectEqual(@as(u32, 2), lineOf(e, st.items.items[0].byte));
}

test "a namespace clears only its own, and a reload drops every one" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    const pane = try app.openScratch();
    const e = app.panes.editor(pane).?;
    try app.splice(e, 0, 0, "a\nb\nc\n");
    const a = try namespace(&app, 0, "a");
    const b = try namespace(&app, 0, "b");
    try testing.expectEqual(a, try namespace(&app, 0, "a"));
    try addLine(&app, a, pane, 1, try testing.allocator.dupe(u8, "cursor_line"));
    try addLine(&app, b, pane, 2, try testing.allocator.dupe(u8, "match"));
    try testing.expectEqual(@as(usize, 2), app.script_decor.items.items.len);
    try testing.expectEqual(@as(usize, 1), clear(&app, a, null));
    try testing.expectEqual(@as(usize, 1), app.script_decor.items.items.len);
    // What is left is the OTHER namespace's, on its own line.
    try testing.expectEqual(b, app.script_decor.items.items[0].ns);
    try testing.expectEqual(@as(u32, 1), lineOf(e, app.script_decor.items.items[0].byte));
    try reset(&app);
    try testing.expectEqual(@as(usize, 0), app.script_decor.items.items.len);
    try testing.expectEqual(@as(usize, 0), app.script_decor.names.items.len);
}

test "a highlight follows the text and stops at the buffer's end" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();
    const pane = try app.openScratch();
    const e = app.panes.editor(pane).?;
    try app.splice(e, 0, 0, "hello world");
    const ns = try namespace(&app, 0, "h");
    try addHighlight(&app, ns, pane, 6, 11, try testing.allocator.dupe(u8, "match"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var spans = try highlightsFor(&app, arena.allocator(), pane, e, &app.theme);
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqual(@as(usize, 6), spans[0].start);
    // Text inserted in front shifts both ends.
    try app.splice(e, 0, 0, "say ");
    spans = try highlightsFor(&app, arena.allocator(), pane, e, &app.theme);
    try testing.expectEqual(@as(usize, 10), spans[0].start);
    try testing.expectEqual(@as(usize, 15), spans[0].end);
}
