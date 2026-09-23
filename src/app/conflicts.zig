//! Conflict resolution in the real editor (docs/research/git-vs-lazygit.md
//! §4.1). A conflicted file opens as any buffer does; this module reads
//! its `<<<<<<<` / `=======` / `>>>>>>>` blocks (`parse.parseConflicts`)
//! every frame the text holds a marker and hands the editor view:
//!
//! * a **tint** on each region's lines — ours on the green ground,
//!   theirs on the blue, the base (diff3) on `bg2` — laid over the
//!   syntax spans so the code keeps its colours (`tintSpans`);
//! * a **header row** above each region (a virtual line, counted in
//!   the scroll): `⚠ conflict N/M` and the chips `Ours · Theirs · Both ·
//!   Edit · Split · AI resolve`, every chip a `.script_hit{ pane,
//!   hitId(region, action) }` the click routes here (`click`);
//!
//! and takes the keys: vim `co` / `ct` / `cb` (a `c` inside a region
//! waits one key; anything but `o t b` replays as the operator) and
//! standard `alt+1` / `alt+2` / `alt+3` — both only while the cursor is
//! inside a region, so `cw` and the tab chords keep their meaning
//! elsewhere; `]x` / `[x` (vim) and `f8` / `shift+f8` jump between
//! regions across the buffer. A pick replaces the whole block, markers
//! included, through one `replace_range` edit op (undoable). Saving a
//! file that was conflicted and holds no marker any more `git add`s it
//! (`afterSave`): the toast says so and the status row leaves the
//! Conflicts section. `Split` opens the diff pane on ours (`:2:`)
//! against theirs (`:3:`) beside the editor; `AI resolve` sends base,
//! ours and theirs through the git AI route and offers the answer as
//! the region's replacement through `ai.apply`'s preview.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Key = app_mod.Key;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const parse = @import("../git/parse.zig");
const client = @import("../git/client.zig");
const git = @import("git.zig");
const ai_app = @import("ai.zig");
const editor_view = @import("../ui/editor_view.zig");
const diff_view = @import("../ui/diff_view.zig");
const Theme = @import("../ui/theme.zig");
const vaxis = @import("vaxis");
const engine = @import("highlight").engine;

pub const Region = parse.ConflictRegion;

/// What a header chip does; `hitId` folds the region in.
pub const Action = enum(u8) {
    ours,
    theirs,
    both,
    edit,
    split,
    ai,

    pub fn label(a: Action) []const u8 {
        return switch (a) {
            .ours => "Ours",
            .theirs => "Theirs",
            .both => "Both",
            .edit => "Edit",
            .split => "Split",
            .ai => "AI resolve",
        };
    }
};

/// Chip ids: `hit_base + region * 8 + action`. Below the code lenses'
/// range and above the `{{VAR}}` spans'; the dispatcher asks
/// `actionOf` before either.
pub const hit_base: u32 = 0x434F_0000;
const action_count: u32 = @typeInfo(Action).@"enum".fields.len;

pub fn hitId(region: usize, a: Action) u32 {
    return hit_base + @as(u32, @intCast(region)) * 8 + @intFromEnum(a);
}

pub const Hit = struct { region: usize, action: Action };

pub fn actionOf(id: u32) ?Hit {
    if (id < hit_base or id >= hit_base + 0x0100_0000) return null;
    const off = id - hit_base;
    if (off % 8 >= action_count) return null;
    return .{ .region = off / 8, .action = @enumFromInt(off % 8) };
}

// ─── regions ────────────────────────────────────────────────────────────

/// Bring the document's cached regions up to the text as it is. An
/// edit-log consumer: the frame calls this before it trims the log.
pub fn sync(app: *App, e: *const EditorPane) Allocator.Error!void {
    if (app.docs.entryOf(e.buf.doc)) |entry| try entry.conflicts.sync(app.gpa, e.buf.doc);
}

/// Whether the buffer has a conflict marker at all (`parse.
/// hasConflictMarker`'s answer, from the cache).
pub fn hasMarker(app: *App, e: *const EditorPane) Allocator.Error!bool {
    const entry = app.docs.entryOf(e.buf.doc) orelse return parse.hasConflictMarker(e.buf.editor.bytes());
    try entry.conflicts.sync(app.gpa, e.buf.doc);
    return entry.conflicts.has_marker;
}

/// The buffer's regions, or none when it holds no marker. Worked out
/// once per text generation (`conflict_cache.zig`), not per call.
pub fn regionsOf(app: *App, arena: Allocator, e: *const EditorPane) Allocator.Error![]Region {
    const entry = app.docs.entryOf(e.buf.doc) orelse {
        const text = e.buf.editor.bytes();
        if (!parse.hasConflictMarker(text)) return &.{};
        return parse.parseConflicts(arena, text);
    };
    try entry.conflicts.sync(app.gpa, e.buf.doc);
    return arena.dupe(Region, entry.conflicts.regions);
}

/// The region the cursor is in, if any.
pub fn regionAtCursor(regions: []const Region, e: *const EditorPane) ?usize {
    const line: u32 = @intCast(e.buf.editor.currentLine());
    for (regions, 0..) |r, i| if (r.holds(line)) return i;
    return null;
}

/// The buffer's byte range of lines `lo..=hi` — through the newline of
/// `hi` when there is one.
fn lineBytes(e: *const EditorPane, lo: u32, hi: u32) [2]usize {
    const ed = e.buf.editor;
    const n = ed.lineCount();
    if (lo >= n) return .{ ed.len(), ed.len() };
    const start = ed.lineStart(lo);
    const end = if (hi + 1 < n) ed.lineStart(hi + 1) else ed.len();
    return .{ start, @max(start, end) };
}

/// The text of `region`'s side.
fn sideText(e: *const EditorPane, r: Region, side: enum { ours, theirs, base }) []const u8 {
    const ed = e.buf.editor;
    const lines: [2]u32 = switch (side) {
        .ours => .{ r.start + 1, (r.base orelse r.mid) -| 1 },
        .theirs => .{ r.mid + 1, r.end -| 1 },
        .base => .{ if (r.base) |b| b + 1 else r.mid, r.mid -| 1 },
    };
    if (lines[1] < lines[0]) return "";
    const b = lineBytes(e, lines[0], lines[1]);
    return ed.bytes()[b[0]..b[1]];
}

// ─── the paint ──────────────────────────────────────────────────────────

/// The syntax spans with the regions' grounds laid in: every base span
/// inside a region keeps its foreground and takes the side's `bg`; the
/// bytes no span covers get one of their own. The marker lines take the
/// muted colour, bold.
pub fn tintSpans(app: *App, arena: Allocator, e: *const EditorPane, base: []const editor_view.Span, theme: *const Theme) Allocator.Error![]const editor_view.Span {
    const regions = try regionsOf(app, arena, e);
    if (regions.len == 0) return base;
    const p = theme.palette;
    const ours_bg = diff_view.blendOver(p.green, p.bg, 40, p.bg2);
    const theirs_bg = diff_view.blendOver(p.blue, p.bg, 40, p.bg2);
    var over: std.ArrayListUnmanaged(editor_view.Span) = .empty;
    var marker = theme.muted;
    marker.bold = true;
    marker.dim = false;
    for (regions) |r| {
        try tintLines(arena, &over, e, base, r.start, r.start, marker, true);
        try tintLines(arena, &over, e, base, r.start + 1, (r.base orelse r.mid) -| 1, .{ .bg = ours_bg }, false);
        if (r.base) |b| {
            try tintLines(arena, &over, e, base, b, b, marker, true);
            try tintLines(arena, &over, e, base, b + 1, r.mid -| 1, .{ .bg = p.bg2 }, false);
        }
        try tintLines(arena, &over, e, base, r.mid, r.mid, marker, true);
        try tintLines(arena, &over, e, base, r.mid + 1, r.end -| 1, .{ .bg = theirs_bg }, false);
        try tintLines(arena, &over, e, base, r.end, r.end, marker, true);
    }
    return engine.layerSpans(editor_view.Span, arena, base, over.items);
}

/// Spans for lines `lo..=hi`: `ground`'s bg over each base span's
/// foreground (or the whole style when `replace`), fillers between.
fn tintLines(arena: Allocator, out: *std.ArrayListUnmanaged(editor_view.Span), e: *const EditorPane, base: []const editor_view.Span, lo: u32, hi: u32, ground: vaxis.Style, replace: bool) Allocator.Error!void {
    if (hi < lo) return;
    const b = lineBytes(e, lo, hi);
    if (b[1] <= b[0]) return;
    var cur = b[0];
    for (base) |sp| {
        if (sp.end <= b[0]) continue;
        if (sp.start >= b[1]) break;
        const s = @max(sp.start, b[0]);
        const en = @min(sp.end, b[1]);
        if (s > cur) try out.append(arena, .{ .start = cur, .end = s, .style = ground });
        var style = if (replace) ground else sp.style;
        if (!replace) style.bg = ground.bg;
        if (en > s) try out.append(arena, .{ .start = s, .end = en, .style = style });
        cur = @max(cur, en);
    }
    if (cur < b[1]) try out.append(arena, .{ .start = cur, .end = b[1], .style = ground });
}

/// The header rows: one above each region's `<<<<<<<` line.
pub fn virtualLinesFor(app: *App, arena: Allocator, e: *const EditorPane, theme: *const Theme, ascii: bool) Allocator.Error![]editor_view.VirtualLine {
    const regions = try regionsOf(app, arena, e);
    if (regions.len == 0) return &.{};
    const p = theme.palette;
    var out: std.ArrayListUnmanaged(editor_view.VirtualLine) = .empty;
    for (regions, 0..) |r, i| {
        var segs: std.ArrayListUnmanaged(editor_view.VirtualSeg) = .empty;
        const warn: []const u8 = if (ascii) "!" else "\u{26A0}";
        try segs.append(arena, .{ .text = try std.fmt.allocPrint(arena, "{s} conflict {d}/{d}", .{ warn, i + 1, regions.len }), .style = .{ .fg = p.yellow, .bold = true } });
        const chips = [_]struct { a: Action, fg: vaxis.Color }{
            .{ .a = .ours, .fg = p.green },
            .{ .a = .theirs, .fg = p.blue },
            .{ .a = .both, .fg = p.purple },
            .{ .a = .edit, .fg = p.fg },
            .{ .a = .split, .fg = p.cyan },
            .{ .a = .ai, .fg = p.orange },
        };
        for (chips) |c| try segs.append(arena, .{ .text = c.a.label(), .style = .{ .fg = c.fg, .bold = true }, .hit = hitId(i, c.a) });
        const keys: []const u8 = if (app.input_style == .vim) "co ct cb \u{B7} ]x [x" else "alt+1 alt+2 alt+3 \u{B7} f8";
        try segs.append(arena, .{ .text = if (ascii) (if (app.input_style == .vim) "co ct cb . ]x [x" else "alt+1 alt+2 alt+3 . f8") else keys, .style = theme.muted });
        try out.append(arena, .{ .line = r.start, .segments = try segs.toOwnedSlice(arena) });
    }
    return out.items;
}

/// Two sorted virtual-line lists into one (the code lenses and the
/// conflict headers).
pub fn mergeVirtualLines(arena: Allocator, a: []const editor_view.VirtualLine, b: []const editor_view.VirtualLine) Allocator.Error![]const editor_view.VirtualLine {
    if (b.len == 0) return a;
    if (a.len == 0) return b;
    const out = try arena.alloc(editor_view.VirtualLine, a.len + b.len);
    var i: usize = 0;
    var j: usize = 0;
    var k: usize = 0;
    while (i < a.len or j < b.len) : (k += 1) {
        if (j >= b.len or (i < a.len and a[i].line <= b[j].line)) {
            out[k] = a[i];
            i += 1;
        } else {
            out[k] = b[j];
            j += 1;
        }
    }
    return out;
}

// ─── resolving ──────────────────────────────────────────────────────────

/// Replace region `idx` with the side picked (`edit` only moves the
/// cursor into it). The cursor lands on the region's first line.
pub fn resolve(app: *App, pane: PaneId, e: *EditorPane, idx: usize, action: Action) CommandError!void {
    const arena = app.frame.allocator();
    const regions = try regionsOf(app, arena, e);
    if (idx >= regions.len) return app.diag.fail(arena, "conflict {d}: gone", .{idx + 1});
    const r = regions[idx];
    const ed = e.buf.editor;
    switch (action) {
        .edit => {
            ed.placeCursor(@min(r.start + 1, ed.lineCount() -| 1), 0);
            app.toast("edit the block by hand — a save with no marker left stages the file", .{});
            return;
        },
        .split => return openSplit(app, e),
        .ai => return askAi(app, pane, e, idx),
        .ours, .theirs, .both => {},
    }
    const ours = sideText(e, r, .ours);
    const theirs = sideText(e, r, .theirs);
    const text: []const u8 = switch (action) {
        .ours => ours,
        .theirs => theirs,
        .both => try std.mem.concat(arena, u8, &.{ ours, theirs }),
        else => unreachable,
    };
    const range = lineBytes(e, r.start, r.end);
    const owned = try arena.dupe(u8, text);
    _ = try app.applyOps(e, &.{.{ .replace_range = .{ .start = range[0], .end = range[1], .text = owned } }});
    ed.placeCursor(@min(r.start, ed.lineCount() -| 1), 0);
    const left = (try regionsOf(app, arena, e)).len;
    if (left == 0) {
        app.toast("conflict {d}: {s} — none left, save stages {s}", .{ idx + 1, action.label(), std.fs.path.basename(e.buf.doc.path orelse "") });
    } else app.toast("conflict {d}: {s} — {d} left", .{ idx + 1, action.label(), left });
}

/// `]x` / `[x`, `f8` / `shift+f8`: the next / previous region's marker
/// line from the cursor, wrapping.
pub fn jump(app: *App, forward: bool) CommandError!void {
    const arena = app.frame.allocator();
    const e = try app.requireEditor();
    const regions = try regionsOf(app, arena, e);
    if (regions.len == 0) return app.diag.fail(arena, "no conflict markers in this buffer", .{});
    const ed = e.buf.editor;
    const line: u32 = @intCast(ed.currentLine());
    var chosen: ?usize = null;
    if (forward) {
        for (regions, 0..) |r, i| if (r.start > line) {
            chosen = i;
            break;
        };
        if (chosen == null) chosen = 0;
    } else {
        var i = regions.len;
        while (i > 0) : (i -= 1) if (regions[i - 1].start < line) {
            chosen = i - 1;
            break;
        };
        if (chosen == null) chosen = regions.len - 1;
    }
    const r = regions[chosen.?];
    ed.placeCursor(r.start, 0);
    e.view.scroll_line = @intCast(r.start -| app.pane_rows / 3);
    app.toast("conflict {d}/{d}", .{ chosen.? + 1, regions.len });
    app.needs_render = true;
}

/// The `git.conflict_*` commands on the active editor's cursor region.
pub fn pick(app: *App, action: Action) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    const e = try app.requireEditor();
    const regions = try regionsOf(app, app.frame.allocator(), e);
    const idx = regionAtCursor(regions, e) orelse return app.diag.fail(app.frame.allocator(), "the cursor is not inside a conflict block ( ]x jumps to one)", .{});
    try resolve(app, id, e, idx, action);
}

/// A header chip clicked.
pub fn click(app: *App, pane: PaneId, id: u32) Allocator.Error!void {
    const h = actionOf(id) orelse return;
    const e = app.panes.editor(pane) orelse return;
    git.runToast(app, resolve(app, pane, e, h.region, h.action));
}

// ─── keys ───────────────────────────────────────────────────────────────

pub const KeyOutcome = enum { pass, consumed, replay_c };

/// The editor's keys ahead of the input handler, only while the buffer
/// has regions and the cursor sits in one. Vim: `c` waits for `o` / `t`
/// / `b`; any other second key means the operator — `replay_c` asks
/// the dispatcher to feed the `c` first. Standard: `alt+1..3`.
pub fn interceptKey(app: *App, pane: PaneId, e: *EditorPane, k: Key) Allocator.Error!KeyOutcome {
    const st = &app.git;
    if (!try hasMarker(app, e)) {
        st.conflict_c_pending = false;
        return .pass;
    }
    const regions = try regionsOf(app, app.frame.allocator(), e);
    const idx = regionAtCursor(regions, e);
    if (st.conflict_c_pending) {
        st.conflict_c_pending = false;
        const c = k.typed() orelse return .replay_c;
        const action: ?Action = switch (c) {
            'o' => .ours,
            't' => .theirs,
            'b' => .both,
            else => null,
        };
        if (action == null or idx == null) return .replay_c;
        git.runToast(app, resolve(app, pane, e, idx.?, action.?));
        return .consumed;
    }
    if (idx == null) return .pass;
    if (app.input_style == .vim) {
        const modal = e.buf.input.mode() == .normal and !e.buf.input.isOpPending();
        if (modal and k.code == .char and k.code.char == 'c' and k.mods.eql(.{})) {
            st.conflict_c_pending = true;
            return .consumed;
        }
        return .pass;
    }
    if (k.mods.alt and !k.mods.ctrl and !k.mods.super and k.code == .char) {
        const action: ?Action = switch (k.code.char) {
            '1' => .ours,
            '2' => .theirs,
            '3' => .both,
            else => null,
        };
        if (action) |a| {
            git.runToast(app, resolve(app, pane, e, idx.?, a));
            return .consumed;
        }
    }
    return .pass;
}

// ─── the file ───────────────────────────────────────────────────────────

/// The repo-relative path of the pane's file when the status lists it
/// as conflicted.
fn conflictedRel(app: *App, e: *const EditorPane) ?struct { repo: *client.Repo, rel: []const u8 } {
    const st = &app.git;
    const repo = st.activeRepo() orelse return null;
    const status = st.status orelse return null;
    if (st.status_repo != repo.id) return null;
    const abs = e.buf.doc.path orelse return null;
    const rel = git.relToRepo(repo, abs);
    for (status.entries) |en| if (en.group == .conflicted and std.mem.eql(u8, en.path, rel)) return .{ .repo = repo, .rel = rel };
    return null;
}

/// After a save: a conflicted file with no marker left is `git add`ed.
pub fn afterSave(app: *App, e: *EditorPane) CommandError!void {
    const hit = conflictedRel(app, e) orelse return;
    if (try hasMarker(app, e)) return;
    app.toast("resolved {s}: marked with git add", .{hit.rel});
    try git.submitOp(app, hit.repo, .{ .stage = try app.gpa.dupe(u8, hit.rel) });
}

/// The status pane's row for a conflicted file: the editor on it, the
/// cursor on the first region.
pub fn openConflicted(app: *App, rel: []const u8) CommandError!void {
    const repo = try git.requireRepo(app);
    const arena = app.frame.allocator();
    const abs = try std.fs.path.join(arena, &.{ repo.path, rel });
    const id = app.openPath(abs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "open {s}: {s}", .{ rel, @errorName(err) }),
    };
    const e = app.panes.editor(id) orelse return;
    const regions = try regionsOf(app, arena, e);
    if (regions.len == 0) return app.toast("{s}: no conflict markers (already resolved? save to stage it)", .{rel});
    e.buf.editor.placeCursor(regions[0].start, 0);
    e.view.scroll_line = @intCast(regions[0].start -| app.pane_rows / 3);
    app.toast("{s}: {d} conflict block{s}", .{ rel, regions.len, if (regions.len == 1) "" else "s" });
}

/// `Split`: the diff pane on ours against theirs for the pane's file,
/// in the Split view.
pub fn openSplit(app: *App, e: *const EditorPane) CommandError!void {
    const repo = try git.requireRepo(app);
    const abs = e.buf.doc.path orelse return app.diag.fail(app.frame.allocator(), "no file", .{});
    const rel = git.relToRepo(repo, abs);
    const id = try git.openDiff(app, repo, .conflict, rel, null, null);
    const pane = app.panes.get(id) orelse return;
    switch (pane.*) {
        .diff => |*dp| try git.setDiffMode(app, dp, .split),
        else => {},
    }
}

/// `AI resolve`: ask the worker for the three stages; `aiContextReady`
/// builds the prompt when they land.
pub fn askAi(app: *App, pane: PaneId, e: *const EditorPane, region: usize) CommandError!void {
    const st = &app.git;
    const repo = try git.requireRepo(app);
    const abs = e.buf.doc.path orelse return app.diag.fail(app.frame.allocator(), "no file", .{});
    if (@import("../ai/suggest.zig").isSecretBearing(abs))
        return app.diag.fail(app.frame.allocator(), "AI resolve: {s} not sent — it looks like it holds secrets", .{git.relToRepo(repo, abs)});
    switch (ai_app.route(app, if (st.ai_product == .claude) .claude else .codex)) {
        .off => return app.diag.fail(app.frame.allocator(), "AI is routed off", .{}),
        .api, .cli => {},
    }
    st.conflict_ai = .{ .pane = pane, .region = @intCast(region) };
    try git.submit(app, repo, .{ .conflict_text = try app.gpa.dupe(u8, git.relToRepo(repo, abs)) });
    app.toast("AI: reading the three sides of {s}…", .{git.relToRepo(repo, abs)});
}

const ai_side_cap: usize = 12_000;

fn capped(s: []const u8) []const u8 {
    return s[0..@min(s.len, ai_side_cap)];
}

/// The stages landed: the prompt names the block's ours / theirs from
/// the buffer and the whole-file base / ours / theirs from git, asks for
/// the merged block in one code fence, and the answer is offered as
/// the region's replacement (`ai.apply` → the apply preview).
pub fn aiContextReady(app: *App, path: []const u8, base: []const u8, ours: []const u8, theirs: []const u8) Allocator.Error!void {
    const st = &app.git;
    const w = st.conflict_ai orelse return;
    st.conflict_ai = null;
    const e = app.panes.editor(w.pane) orelse return;
    const arena = app.frame.allocator();
    const regions = try regionsOf(app, arena, e);
    if (w.region >= regions.len) {
        app.toast("AI resolve: the block is gone", .{});
        return;
    }
    const r = regions[w.region];
    const range = lineBytes(e, r.start, r.end);
    const block = e.buf.editor.bytes()[range[0]..range[1]];
    const prompt = try std.fmt.allocPrint(arena,
        \\Resolve this merge conflict block from `{s}`. Output ONLY the resolved text of the block (what replaces everything from `<<<<<<<` through `>>>>>>>`), in one ```` ``` ```` code fence, with no markers, no preamble and no explanation. Keep the surrounding code's style; combine both sides when both are wanted.
        \\
        \\The conflict block:
        \\```
        \\{s}```
        \\
        \\{s}{s}{s}Ours (the whole file, `:2:`):
        \\```
        \\{s}```
        \\
        \\Theirs (the whole file, `:3:`):
        \\```
        \\{s}```
    , .{ path, block, if (base.len > 0) "The common base (the whole file, `:1:`):\n```\n" else "", capped(base), if (base.len > 0) "```\n\n" else "", capped(ours), capped(theirs) });
    const title = try std.fmt.allocPrint(arena, "ai: resolve conflict {d} of {s}", .{ w.region + 1, std.fs.path.basename(path) });
    _ = ai_app.askProduct(app, st.ai_product, title, prompt, .git, .take(w.pane, e.buf.doc, range[0], range[1])) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        git.runToast(app, err);
        return;
    };
    app.toast("AI: resolving conflict {d} — `a` in the answer pane applies it after a preview", .{w.region + 1});
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "hit ids fold the region and the action, and nothing else decodes" {
    try testing.expectEqual(Hit{ .region = 3, .action = .both }, actionOf(hitId(3, .both)).?);
    try testing.expectEqual(Hit{ .region = 0, .action = .ai }, actionOf(hitId(0, .ai)).?);
    try testing.expect(actionOf(hit_base + 6) == null);
    try testing.expect(actionOf(0x4C45_0000) == null);
    try testing.expect(actionOf(7) == null);
}

test "mergeVirtualLines keeps both lists in line order" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const x = [_]editor_view.VirtualLine{ .{ .line = 1, .segments = &.{} }, .{ .line = 9, .segments = &.{} } };
    const y = [_]editor_view.VirtualLine{.{ .line = 4, .segments = &.{} }};
    const m = try mergeVirtualLines(a.allocator(), &x, &y);
    try testing.expectEqual(@as(usize, 3), m.len);
    try testing.expectEqual(@as(u32, 1), m[0].line);
    try testing.expectEqual(@as(u32, 4), m[1].line);
    try testing.expectEqual(@as(u32, 9), m[2].line);
    try testing.expectEqual(@as(usize, 2), (try mergeVirtualLines(a.allocator(), &x, &.{})).len);
}
