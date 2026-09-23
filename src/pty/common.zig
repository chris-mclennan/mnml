//! What both pty backends hand the pane: the reader's wakeup and how the
//! child ended. `session_posix.zig` and `session_windows.zig` re-export
//! these so `pty.session.Exit` names one type whichever backend is in.
//! Both also take their thread-shared locks from here.

const std = @import("std");
const vt = @import("ghostty-vt");

/// `terminal.scrollback_lines`' default: what a build log needs to keep
/// its first error. The library's own default is 10 KB — about 500 lines.
pub const default_scrollback_lines: usize = 10_000;

/// The `Terminal` every session runs, whichever backend. Scrollback is
/// bounded by lines, not bytes (ghostty's `scrollback-limit-lines`), so
/// the number the user sets is the number they get.
pub fn terminalOptions(cols: u16, rows: u16, scrollback_lines: usize) vt.Terminal.Options {
    return .{
        .cols = cols,
        .rows = rows,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = scrollback_lines,
        // Mode 2027 on, as ghostty's `grapheme-width-method = unicode`
        // sets it and as mnml's own canvas asks its host for: 👍🏽 and 🇺🇸
        // are one two-cell cluster, a ZWJ family keeps its joiners, ❤️
        // takes VS16's width — so the child, the pane's grid and the
        // host agree on where every later cell of the row is.
        .default_modes = .{ .grapheme_cluster = true },
    };
}

/// Called from the reader thread: once when the ring goes from empty to
/// readable (see `Ring.commit`), and once when the child's output ends.
/// The UI side answers by calling `Session.pump`. The call is made under
/// the session's notify lock, and `Session.deinit` disarms it under that
/// same lock before letting go — so `ctx` only has to outlive the
/// *session*, not the detached reader. The callback must therefore never
/// block on something the UI thread provides (a full event queue drained
/// only by the UI thread would deadlock a `deinit` waiting for the lock).
pub const Notify = struct {
    ctx: ?*anyopaque = null,
    fn_ptr: ?*const fn (?*anyopaque) void = null,

    pub const none: Notify = .{};

    pub fn call(self: Notify) void {
        if (self.fn_ptr) |f| f(self.ctx);
    }
};

pub const Exit = union(enum) {
    /// Normal exit with this status code.
    code: u8,
    /// Killed by this signal. On Windows: an exit code above 255 — the
    /// NTSTATUS-shaped ones (`0xC0000005` access violation, `0xC000013A`
    /// ctrl-C) — which is the closest thing the platform has to a death
    /// by signal.
    signal: u32,

    pub fn ok(self: Exit) bool {
        return self == .code and self.code == 0;
    }
};

/// The text a child's clipboard write carries (OSC 52, or the first
/// text representation of an OSC 5522 one); null for a clear or a write
/// with no text in it.
pub fn clipboardText(w: vt.clipboard.Write) ?[]const u8 {
    for (w.contents) |c| if (vt.clipboard.isTextMime(c.mime)) return c.data;
    return null;
}

/// A test-and-set lock for the short critical sections the backends
/// share with their threads (the notify callback, the outbox). A
/// spinlock because the other side is a raw thread with no `Io` to
/// park on, and every section is a handful of instructions or a
/// bounded memcpy.
pub const SpinLock = struct {
    held: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.held.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *SpinLock) void {
        self.held.store(false, .release);
    }
};
