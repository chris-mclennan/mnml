//! Registers. The unnamed register plus vim's named (`a`–`z`, append via
//! `A`–`Z`), yank (`0`), delete-history (`1`–`9`) and blackhole (`_`)
//! registers. A pending register name set by `set_register_hint` routes
//! exactly one following write or read, then clears — vim's `"a` sticks
//! for one op.
//!
//! Every stored string is gpa-owned by the clipboard. `text()` and
//! `lastWritten()` hand out borrowed slices valid until the next write.
//!
//! The OS clipboard (`+`) is a later phase; `"+` reads fall back to the
//! unnamed register so a paste is never silently empty. TODO(clipboard-os)

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    text: []u8,
    linewise: bool,
};

pub const Clipboard = struct {
    gpa: Allocator,
    unnamed: ?Entry = null,
    named: std.AutoHashMapUnmanaged(u8, Entry) = .empty,
    pending_register: ?u21 = null,
    /// Linewise-ness of the register the last `text()` read from — the
    /// paste ops consult it after reading.
    effective_linewise: bool = false,
    /// The text of the last write, whichever register took it. Null after
    /// a blackhole write.
    last_written: ?[]const u8 = null,

    pub fn init(gpa: Allocator) Clipboard {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Clipboard) void {
        if (self.unnamed) |e| self.gpa.free(e.text);
        var it = self.named.valueIterator();
        while (it.next()) |e| self.gpa.free(e.text);
        self.named.deinit(self.gpa);
    }

    pub fn setPendingRegister(self: *Clipboard, reg: ?u21) void {
        self.pending_register = reg;
    }

    /// A delete: writes the target register AND (for the unnamed target)
    /// shifts the `1`–`9` history.
    pub fn pushDelete(self: *Clipboard, s: []const u8, linewise: bool) Allocator.Error!void {
        const reg = self.pending_register;
        try self.set(s, linewise);
        if (reg == null or reg == '+') {
            var i: u8 = 8;
            while (i >= 1) : (i -= 1) {
                if (self.named.fetchRemove('0' + i)) |kv| {
                    try self.putNamed('0' + i + 1, kv.value);
                }
            }
            try self.putNamed('1', .{ .text = try self.gpa.dupe(u8, s), .linewise = linewise });
        }
    }

    /// A yank: writes the target register AND (for the unnamed target)
    /// the `0` register.
    pub fn setYank(self: *Clipboard, s: []const u8, linewise: bool) Allocator.Error!void {
        const reg = self.pending_register;
        try self.set(s, linewise);
        if (reg == null or reg == '+') {
            try self.putNamed('0', .{ .text = try self.gpa.dupe(u8, s), .linewise = linewise });
        }
    }

    /// Write `text` to the pending register (consumed) or the unnamed one.
    pub fn set(self: *Clipboard, s: []const u8, linewise: bool) Allocator.Error!void {
        const reg = self.pending_register;
        self.pending_register = null;
        if (reg) |r| {
            if (r == '_') {
                self.last_written = null;
                return;
            }
            if (r >= 'a' and r <= 'z') {
                const e: Entry = .{ .text = try self.gpa.dupe(u8, s), .linewise = linewise };
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
                const e: Entry = .{ .text = merged, .linewise = linewise };
                try self.putNamed(slot, e);
                self.last_written = e.text;
                return;
            }
            if (r == '0') {
                const e: Entry = .{ .text = try self.gpa.dupe(u8, s), .linewise = linewise };
                try self.putNamed('0', e);
                self.last_written = e.text;
                return;
            }
        }
        const e: Entry = .{ .text = try self.gpa.dupe(u8, s), .linewise = linewise };
        if (self.unnamed) |old| self.gpa.free(old.text);
        self.unnamed = e;
        self.last_written = e.text;
    }

    /// Read the pending register (consumed) or the unnamed one. Borrowed;
    /// valid until the next write. Sets `effective_linewise`.
    pub fn text(self: *Clipboard) []const u8 {
        const reg = self.pending_register;
        self.pending_register = null;
        if (reg) |r| {
            if (r == '_') {
                self.effective_linewise = false;
                return "";
            }
            if ((r >= 'a' and r <= 'z') or (r >= 'A' and r <= 'Z') or (r >= '0' and r <= '9')) {
                const slot: u8 = if (r >= 'A' and r <= 'Z') @intCast(r - 'A' + 'a') else @intCast(r);
                if (self.named.get(slot)) |e| {
                    self.effective_linewise = e.linewise;
                    return e.text;
                }
                self.effective_linewise = false;
                return "";
            }
            // `+` and anything else fall through to the unnamed register.
        }
        if (self.unnamed) |e| {
            self.effective_linewise = e.linewise;
            return e.text;
        }
        self.effective_linewise = false;
        return "";
    }

    pub fn isLinewise(self: *const Clipboard) bool {
        return self.effective_linewise;
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

test "unnamed + yank register + delete history" {
    var c = Clipboard.init(std.testing.allocator);
    defer c.deinit();
    try c.setYank("one\n", true);
    try std.testing.expectEqualStrings("one\n", c.text());
    try std.testing.expect(c.isLinewise());
    try std.testing.expectEqualStrings("one\n", c.named_entry('0').?.text);
    try c.pushDelete("two", false);
    try c.pushDelete("three", false);
    try std.testing.expectEqualStrings("three", c.text());
    try std.testing.expect(!c.isLinewise());
    try std.testing.expectEqualStrings("three", c.named_entry('1').?.text);
    try std.testing.expectEqualStrings("two", c.named_entry('2').?.text);
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
