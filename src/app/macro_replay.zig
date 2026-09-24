//! `@a` / `@@` / `Q` / `{count}@a` (`:help @`): a register's keys, each
//! through the whole key dispatch as if typed — a `/foo⏎` in it
//! searches, a `:s…⏎` runs, an app command's key runs it.
//!
//! A replay is a stack of frames, one per register being played, fed
//! from one loop rather than by recursion: a register that ends by
//! calling itself (`qcI-<Esc>j@cq`) replaces its finished frame, so it
//! runs to the end of the file in constant stack. A key that fails the
//! way vim beeps (`App.key_failed` — a motion that cannot move, a search
//! with no match) drops every frame: the rest of the register and every
//! pending repeat (`:help q`), which is what makes a recursive macro and
//! `999@a` stop when the work runs out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = @import("../core/key.zig").Key;
const buffer_mod = @import("../editor/buffer.zig");
const dispatch = @import("dispatch.zig");

/// Frames a replay may hold at once — nesting that is not a tail call
/// (`@b` in the middle of `a`, which itself calls `@a`…).
pub const max_frames = 100;
/// Keys one replay may feed in all: a register that calls itself and
/// never fails would otherwise never end (vim hangs until Ctrl-C).
pub const max_keys = 1_000_000;

const Frame = struct { keys: []Key, at: usize = 0, left: u32 };

pub const Run = struct {
    frames: std.ArrayListUnmanaged(Frame) = .empty,
    /// The `key_depth` the loop feeds at: a `@x` met at this depth is
    /// the register's own key and becomes a frame; one met deeper (a
    /// `:norm @a` inside the replay) starts a replay of its own.
    depth: u16,

    fn deinit(r: *Run, gpa: Allocator) void {
        for (r.frames.items) |f| gpa.free(f.keys);
        r.frames.deinit(gpa);
    }

    /// Drop the frames that have nothing left to feed.
    fn popDone(r: *Run, gpa: Allocator) void {
        while (r.frames.items.len > 0) {
            const top = &r.frames.items[r.frames.items.len - 1];
            if (top.at < top.keys.len) return;
            if (top.left > 1) {
                top.left -= 1;
                top.at = 0;
                return;
            }
            gpa.free(top.keys);
            r.frames.items.len -= 1;
        }
    }
};

/// `@reg` typed in pane `pane_id`, `count` times (`recorded`: the last
/// recorded register, the statusline chip's replay).
pub fn run(app: *App, pane_id: PaneId, reg_in: u8, count: u32, recorded: bool) Allocator.Error!void {
    const clip = &app.clipboard;
    const reg = if (recorded) (clip.last_recorded orelse return) else if (reg_in == '@') (clip.last_macro orelse return) else reg_in;
    const spec = clip.macro(reg) orelse return;
    clip.last_macro = reg;
    // The register may be rewritten by what it replays (`"ay$`): the
    // keys are parsed into a copy.
    const keys = try buffer_mod.parseKeys(app.gpa, spec);
    if (app.macro_run) |r| if (r.depth == app.key_depth) {
        // The running register's own `@x`: a frame on its stack. A
        // finished one under it goes first — a tail call.
        errdefer app.gpa.free(keys);
        r.popDone(app.gpa);
        if (r.frames.items.len >= max_frames) {
            app.gpa.free(keys);
            app.key_failed = true;
            return;
        }
        try r.frames.append(app.gpa, .{ .keys = keys, .left = @max(count, 1) });
        return;
    };
    var r: Run = .{ .depth = app.key_depth + 1 };
    defer r.deinit(app.gpa);
    r.frames.append(app.gpa, .{ .keys = keys, .left = @max(count, 1) }) catch |err| {
        app.gpa.free(keys);
        return err;
    };
    const outer = app.macro_run;
    app.macro_run = &r;
    defer app.macro_run = outer;
    var fed: usize = 0;
    while (true) {
        r.popDone(app.gpa);
        if (r.frames.items.len == 0) return;
        // A replay ends with the pane it was typed into.
        if (app.panes.editor(pane_id) == null) return;
        if (fed >= max_keys) return;
        fed += 1;
        const top = &r.frames.items[r.frames.items.len - 1];
        const k_in = top.keys[top.at];
        top.at += 1;
        // A register yanked with `yy` ends in a newline: Enter, as vim
        // executes it.
        const k: Key = if (k_in.code == .char and k_in.code.char == '\n') Key.named(.enter) else k_in;
        app.key_failed = false;
        try dispatch.keyUnrecorded(app, k);
        if (app.key_failed) return;
    }
}
