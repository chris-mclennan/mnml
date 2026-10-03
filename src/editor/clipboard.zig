//! Registers. The unnamed register plus vim's named (`a`–`z`, append via
//! `A`–`Z`), yank (`0`), delete-history (`1`–`9`), small-delete (`-`)
//! and blackhole (`_`) registers. A pending register name set by `set_register_hint` routes
//! exactly one following write or read, then clears — vim's `"a` sticks
//! for one op.
//!
//! Every stored string is gpa-owned by the clipboard. `text()` and
//! `lastWritten()` hand out borrowed slices valid until the next write.
//!
//! `"+` and `"*` are the OS clipboard (`src/core/clipboard_os.zig`). A
//! write to either goes to the sink AND to the unnamed register, so the
//! yank is never lost when the push fails. A read asks the sink first —
//! a tool pair (pbpaste, wl-paste, …) answers; OSC 52 cannot, so the
//! read falls back to the unnamed register and a paste is never silently
//! empty. Text that came from the OS is linewise when it ends in `\n`,
//! vim's rule for the system selection. Until `attach` installs a sink
//! the clipboard is in-process only, which is what every test, the
//! headless loop and a `.test` run get.
//!
//! Macros are registers (`:help q`): `qa…q` writes the keys, in the
//! `parseKeys` notation (`I- <esc>`), into the named register `a` as
//! charwise text, so `:reg a` shows it, `"ap` pastes it to edit, `"ay$`
//! puts it back and `@a` parses whatever the register holds. `'@'` is
//! the anonymous register `qq` / `@@` use; it is never listed. `Buffer`
//! keeps the in-flight recording and reaches the registers through the
//! `*Clipboard` every `feedKey` already takes.
//! // changed: D4 placed macro registers on `Buffer`; that made them
//! per-file, which vim users notice the first time `@a` says nothing.
//! A separate key store came next, invisible to `:reg` and `"ap`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const clipboard_os = @import("../core/clipboard_os.zig");

pub const Entry = struct {
    text: []u8,
    linewise: bool,
    /// A Visual-block yank or delete (`:help blockwise-register`): the
    /// rows are `\n`-joined and a put lays them out as a column.
    block: bool = false,
};

pub const Clipboard = struct {
    gpa: Allocator,
    unnamed: ?Entry = null,
    named: std.AutoHashMapUnmanaged(u8, Entry) = .empty,
    pending_register: ?u21 = null,
    /// Linewise-ness of the register the last `text()` read from — the
    /// paste ops consult it after reading.
    effective_linewise: bool = false,
    /// Blockwise-ness of the same read.
    effective_block: bool = false,
    /// Set for the length of a `setYankBlock` / `pushDeleteBlock`: every
    /// entry the write makes is blockwise.
    writing_block: bool = false,
    /// The text of the last write, whichever register took it. Null after
    /// a blackhole write.
    last_written: ?[]const u8 = null,
    /// Where `"+` / `"*` go. `.none` until `attach` — in-process only.
    os: clipboard_os.Sink = .none,
    io: ?std.Io = null,
    /// What `attach` was given; `selectMode` re-runs the chain over them
    /// when `editor.clipboard` changes at runtime.
    live: ?*std.Io.Writer = null,
    tool: ?clipboard_os.Tool = null,
    /// The last text read back from the OS, gpa-owned — what `text()`
    /// handed out for a `"+` / `"*` read. Freed on the next such read.
    os_text: ?[]u8 = null,
    /// The register `@@` repeats: the last one executed (`:help @@`).
    last_macro: ?u8 = null,
    /// The register `Q` repeats: the last one recorded (`:help Q`).
    last_recorded: ?u8 = null,

    pub fn init(gpa: Allocator) Clipboard {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Clipboard) void {
        if (self.unnamed) |e| self.gpa.free(e.text);
        var it = self.named.valueIterator();
        while (it.next()) |e| self.gpa.free(e.text);
        self.named.deinit(self.gpa);
        if (self.os_text) |t| self.gpa.free(t);
    }

    /// Install what the session has — the terminal's buffered writer and
    /// the probed tool — then pick the sink for `mode`.
    pub fn attach(self: *Clipboard, io: std.Io, live: ?*std.Io.Writer, tool: ?clipboard_os.Tool, mode: clipboard_os.Mode) void {
        self.io = io;
        self.live = live;
        self.tool = tool;
        self.selectMode(mode);
    }

    /// Re-run the chain (`:set clipboard=…`, the settings row).
    pub fn selectMode(self: *Clipboard, mode: clipboard_os.Mode) void {
        self.os = clipboard_os.select(mode, self.live, self.tool);
    }

    /// A finished recording: `spec` (key notation, copied) becomes the
    /// charwise text of register `reg`.
    pub fn putMacro(self: *Clipboard, reg: u8, spec: []const u8) Allocator.Error!void {
        try self.putNamed(reg, .{ .text = try self.gpa.dupe(u8, spec), .linewise = false });
    }

    /// What `@reg` replays: the register's text, borrowed.
    pub fn macro(self: *const Clipboard, reg: u8) ?[]const u8 {
        const e = self.named.get(reg) orelse return null;
        return e.text;
    }

    /// The register names `:reg` lists: every non-empty named one, the
    /// anonymous macro slot excluded. Sorted, on `arena`.
    pub fn listedNames(self: *const Clipboard, arena: Allocator) Allocator.Error![]u8 {
        var names: std.ArrayList(u8) = .empty;
        var it = self.named.iterator();
        while (it.next()) |kv| if (kv.key_ptr.* != '@' and kv.value_ptr.text.len > 0) try names.append(arena, kv.key_ptr.*);
        std.mem.sort(u8, names.items, {}, std.sort.asc(u8));
        return names.items;
    }

    /// vim's read-only `".` register: what the last Insert typed
    /// (`:help quote.`), written when an Insert session closes.
    pub fn setLastInserted(self: *Clipboard, s: []const u8) Allocator.Error!void {
        try self.putNamed('.', .{ .text = try self.gpa.dupe(u8, s), .linewise = false });
    }

    pub fn setPendingRegister(self: *Clipboard, reg: ?u21) void {
        self.pending_register = reg;
    }

    /// `"+` and `"*` — vim's clipboard and primary-selection registers.
    /// One sink serves both: no terminal exposes two.
    pub fn isOsRegister(reg: u21) bool {
        return reg == '+' or reg == '*';
    }

    fn goesToUnnamed(reg: ?u21) bool {
        return reg == null or isOsRegister(reg.?);
    }

    /// A delete: writes the target register AND (for the unnamed target)
    /// the small-delete register `-` when the text is less than a line,
    /// else shifts the `1`–`9` history (`:help quote1`, `:help quote-`).
    pub fn pushDelete(self: *Clipboard, s: []const u8, linewise: bool) Allocator.Error!void {
        const reg = self.pending_register;
        try self.set(s, linewise);
        if (goesToUnnamed(reg)) {
            if (!linewise and std.mem.indexOfScalar(u8, s, '\n') == null) {
                try self.putNamed('-', .{ .text = try self.gpa.dupe(u8, s), .linewise = false });
                return;
            }
            var i: u8 = 8;
            while (i >= 1) : (i -= 1) {
                if (self.named.fetchRemove('0' + i)) |kv| {
                    try self.putNamed('0' + i + 1, kv.value);
                }
            }
            try self.putNamed('1', .{ .text = try self.gpa.dupe(u8, s), .linewise = linewise, .block = self.writing_block });
        }
    }

    /// A Visual-block yank (`:help blockwise-register`): `setYank`, the
    /// entries it writes marked blockwise.
    pub fn setYankBlock(self: *Clipboard, s: []const u8) Allocator.Error!void {
        self.writing_block = true;
        defer self.writing_block = false;
        try self.setYank(s, false);
    }

    /// A Visual-block delete: `pushDelete`, blockwise. The one-row case
    /// that lands in `"-` stays charwise there, as small deletes are.
    pub fn pushDeleteBlock(self: *Clipboard, s: []const u8) Allocator.Error!void {
        self.writing_block = true;
        defer self.writing_block = false;
        try self.pushDelete(s, false);
    }

    /// A yank: writes the target register AND (for the unnamed target)
    /// the `0` register.
    pub fn setYank(self: *Clipboard, s: []const u8, linewise: bool) Allocator.Error!void {
        const reg = self.pending_register;
        try self.set(s, linewise);
        if (goesToUnnamed(reg)) {
            try self.putNamed('0', .{ .text = try self.gpa.dupe(u8, s), .linewise = linewise, .block = self.writing_block });
        }
    }

    /// Write `text` to the pending register (consumed) or the unnamed one.
    /// `"+` / `"*` write the unnamed register and push to the OS sink.
    pub fn set(self: *Clipboard, s: []const u8, linewise: bool) Allocator.Error!void {
        const reg = self.pending_register;
        self.pending_register = null;
        if (reg) |r| {
            if (r == '_') {
                self.last_written = null;
                return;
            }
            if (r >= 'a' and r <= 'z') {
                const e: Entry = .{ .text = try self.gpa.dupe(u8, s), .linewise = linewise, .block = self.writing_block };
                try self.putNamed(@intCast(r), e);
                self.last_written = e.text;
                return;
            }
            if (r >= 'A' and r <= 'Z') {
                const slot: u8 = @intCast(r - 'A' + 'a');
                const merged = if (self.named.get(slot)) |prev|
                    try std.mem.concat(self.gpa, u8, &.{ prev.text, s })
                else
                    try self.gpa.dupe(u8, s);
                const e: Entry = .{ .text = merged, .linewise = linewise, .block = self.writing_block };
                try self.putNamed(slot, e);
                self.last_written = e.text;
                return;
            }
            if (r == '0') {
                const e: Entry = .{ .text = try self.gpa.dupe(u8, s), .linewise = linewise, .block = self.writing_block };
                try self.putNamed('0', e);
                self.last_written = e.text;
                return;
            }
        }
        const e: Entry = .{ .text = try self.gpa.dupe(u8, s), .linewise = linewise, .block = self.writing_block };
        if (self.unnamed) |old| self.gpa.free(old.text);
        self.unnamed = e;
        self.last_written = e.text;
        // The register is written first: a failing push (no tool, a
        // closed pipe) must not lose the yank.
        if (reg != null and isOsRegister(reg.?)) self.pushToOs(s);
    }

    /// A chrome copy — a toast's Copy, a menu's "Copy path" / "Copy
    /// link", the HTTP pane's "Copy as curl": what a person means by
    /// "copy" outside the editor is the system clipboard. The text goes
    /// to the OS sink AND the unnamed register, so it pastes in another
    /// app and in mnml alike. The editor's own yanks keep `setYank`,
    /// whose destination is the register the person named.
    pub fn copy(self: *Clipboard, s: []const u8) Allocator.Error!void {
        self.pending_register = '+';
        try self.set(s, false);
    }

    fn pushToOs(self: *Clipboard, s: []const u8) void {
        const io = self.io orelse return;
        clipboard_os.write(self.os, io, s) catch {};
    }

    /// The OS text for a `"+` / `"*` read, or null when the sink cannot
    /// read (OSC 52, `.none`) — the caller then uses the unnamed register.
    fn readFromOs(self: *Clipboard) ?[]const u8 {
        const io = self.io orelse return null;
        const t = clipboard_os.read(self.os, io, self.gpa) orelse return null;
        if (self.os_text) |old| self.gpa.free(old);
        self.os_text = t;
        self.effective_linewise = t.len > 0 and t[t.len - 1] == '\n';
        return t;
    }

    /// Read the pending register (consumed) or the unnamed one. Borrowed;
    /// valid until the next write. Sets `effective_linewise`.
    pub fn text(self: *Clipboard) []const u8 {
        const reg = self.pending_register;
        self.pending_register = null;
        if (reg) |r| {
            self.effective_block = false;
            if (r == '_') {
                self.effective_linewise = false;
                return "";
            }
            // `".` before any Insert is empty: nothing is put (E29).
            if ((r >= 'a' and r <= 'z') or (r >= 'A' and r <= 'Z') or (r >= '0' and r <= '9') or r == '-' or r == '.') {
                const slot: u8 = if (r >= 'A' and r <= 'Z') @intCast(r - 'A' + 'a') else @intCast(r);
                if (self.named.get(slot)) |e| {
                    self.effective_linewise = e.linewise;
                    self.effective_block = e.block;
                    return e.text;
                }
                self.effective_linewise = false;
                return "";
            }
            if (isOsRegister(r)) {
                if (self.readFromOs()) |t| return t;
            }
            // An unreadable sink and anything else fall through to the
            // unnamed register.
        }
        if (self.unnamed) |e| {
            self.effective_linewise = e.linewise;
            self.effective_block = e.block;
            return e.text;
        }
        self.effective_linewise = false;
        self.effective_block = false;
        return "";
    }

    pub fn isLinewise(self: *const Clipboard) bool {
        return self.effective_linewise;
    }

    /// The register the last `text()` read is blockwise.
    pub fn isBlockwise(self: *const Clipboard) bool {
        return self.effective_block;
    }

    /// The text of the most recent write, borrowed. Null after a blackhole.
    pub fn lastWritten(self: *const Clipboard) ?[]const u8 {
        return self.last_written;
    }

    pub fn named_entry(self: *const Clipboard, reg: u8) ?Entry {
        return self.named.get(reg);
    }

    fn putNamed(self: *Clipboard, reg: u8, e: Entry) Allocator.Error!void {
        errdefer self.gpa.free(e.text);
        if (self.named.fetchRemove(reg)) |old| self.gpa.free(old.value.text);
        try self.named.put(self.gpa, reg, e);
    }
};

test "unnamed + yank register + delete history + the small-delete register" {
    var c = Clipboard.init(std.testing.allocator);
    defer c.deinit();
    try c.setYank("one\n", true);
    try std.testing.expectEqualStrings("one\n", c.text());
    try std.testing.expect(c.isLinewise());
    try std.testing.expectEqualStrings("one\n", c.named_entry('0').?.text);
    try c.pushDelete("two\nx", false);
    try c.pushDelete("three\n", true);
    try std.testing.expectEqualStrings("three\n", c.text());
    try std.testing.expect(c.isLinewise());
    try std.testing.expectEqualStrings("three\n", c.named_entry('1').?.text);
    try std.testing.expectEqualStrings("two\nx", c.named_entry('2').?.text);
    // Less than a line goes to `"-`, and the history keeps its order.
    try c.pushDelete("ch", false);
    try std.testing.expectEqualStrings("ch", c.text());
    try std.testing.expectEqualStrings("ch", c.named_entry('-').?.text);
    try std.testing.expectEqualStrings("three\n", c.named_entry('1').?.text);
    c.setPendingRegister('-');
    try std.testing.expectEqualStrings("ch", c.text());
    // A named target takes the small delete instead; `"-` is untouched.
    c.setPendingRegister('a');
    try c.pushDelete("named", false);
    try std.testing.expectEqualStrings("ch", c.named_entry('-').?.text);
    // `"0p` still gives the last yank.
    c.setPendingRegister('0');
    try std.testing.expectEqualStrings("one\n", c.text());
}

test "named registers: set, append, blackhole, missing" {
    var c = Clipboard.init(std.testing.allocator);
    defer c.deinit();
    c.setPendingRegister('a');
    try c.setYank("foo", false);
    c.setPendingRegister('A');
    try c.setYank("bar", false);
    c.setPendingRegister('a');
    try std.testing.expectEqualStrings("foobar", c.text());
    // The unnamed register was never written by a named yank.
    try std.testing.expectEqualStrings("", c.text());
    c.setPendingRegister('_');
    try c.pushDelete("gone", false);
    try std.testing.expect(c.lastWritten() == null);
    try std.testing.expectEqualStrings("", c.text());
    c.setPendingRegister('z');
    try std.testing.expectEqualStrings("", c.text());
    try std.testing.expect(c.pending_register == null);
}

test "\"+ and \"* write the sink and the unnamed register; an OSC 52 read falls back" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var c = Clipboard.init(std.testing.allocator);
    defer c.deinit();
    c.attach(std.testing.io, &aw.writer, null, .auto);
    try std.testing.expect(c.os == .osc52);
    c.setPendingRegister('+');
    try c.setYank("line\n", true);
    try std.testing.expectEqualStrings("\x1b]52;c;bGluZQo=\x07", aw.written());
    // The unnamed register and `"0` took it too, linewise intact.
    try std.testing.expectEqualStrings("line\n", c.unnamed.?.text);
    try std.testing.expectEqualStrings("line\n", c.named_entry('0').?.text);
    // OSC 52 cannot read: `"+p` pastes what was yanked, still linewise.
    c.setPendingRegister('+');
    try std.testing.expectEqualStrings("line\n", c.text());
    try std.testing.expect(c.isLinewise());
    // `"*` is the same sink; a delete through it fills `"-` (or the
    // history) too.
    aw.clearRetainingCapacity();
    c.setPendingRegister('*');
    try c.pushDelete("gone", false);
    try std.testing.expectEqualStrings("\x1b]52;c;Z29uZQ==\x07", aw.written());
    try std.testing.expectEqualStrings("gone", c.named_entry('-').?.text);
    c.setPendingRegister('*');
    try std.testing.expectEqualStrings("gone", c.text());
    // A named register never reaches the sink.
    aw.clearRetainingCapacity();
    c.setPendingRegister('a');
    try c.setYank("private", false);
    try std.testing.expectEqualStrings("", aw.written());
    // `.internal` detaches the sink; the registers keep working.
    c.selectMode(.internal);
    try std.testing.expect(c.os == .none);
    c.setPendingRegister('+');
    try c.setYank("quiet", false);
    try std.testing.expectEqualStrings("", aw.written());
    try std.testing.expectEqualStrings("quiet", c.text());
}

test "a tool sink answers a \"+ read; the OS text is linewise when it ends in a newline" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var c = Clipboard.init(std.testing.allocator);
    defer c.deinit();
    const tool: clipboard_os.Tool = .{
        .name = "fake",
        .copy = &.{ "/bin/sh", "-c", "cat > /dev/null" },
        .paste = &.{ "/bin/sh", "-c", "printf 'from the os\\n'" },
    };
    c.attach(std.testing.io, null, tool, .os);
    try std.testing.expect(c.os == .tool);
    try c.setYank("mine", false);
    c.setPendingRegister('+');
    try std.testing.expectEqualStrings("from the os\n", c.text());
    try std.testing.expect(c.isLinewise());
    // The unnamed register was not touched by the read.
    try std.testing.expectEqualStrings("mine", c.text());
    try std.testing.expect(!c.isLinewise());
    // A second read frees the first; a write through `"*` still lands
    // in the unnamed register even though the copy half discards it.
    c.setPendingRegister('*');
    try std.testing.expectEqualStrings("from the os\n", c.text());
    c.setPendingRegister('*');
    try c.setYank("pushed", false);
    try std.testing.expectEqualStrings("pushed", c.unnamed.?.text);
}

test "a chrome copy reaches the OS sink and the unnamed register, whatever register was pending" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var c = Clipboard.init(std.testing.allocator);
    defer c.deinit();
    c.attach(std.testing.io, &aw.writer, null, .auto);
    // A stray pending register (a `"a` typed before a click) does not
    // divert a chrome copy into a named register.
    c.setPendingRegister('a');
    try c.copy("ENG-123");
    try std.testing.expectEqualStrings("\x1b]52;c;RU5HLTEyMw==\x07", aw.written());
    try std.testing.expectEqualStrings("ENG-123", c.unnamed.?.text);
    try std.testing.expect(c.named_entry('a') == null);
    try std.testing.expect(c.pending_register == null);
    // Without a sink the register still takes it.
    c.selectMode(.internal);
    aw.clearRetainingCapacity();
    try c.copy("second");
    try std.testing.expectEqualStrings("", aw.written());
    try std.testing.expectEqualStrings("second", c.unnamed.?.text);
}
