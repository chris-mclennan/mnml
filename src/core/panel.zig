//! Shared vocabulary of the list panels (TODOS / NOTES / FINDINGS /
//! SESSIONS): which panel, and how it orders its rows. Lives in core
//! because both the command layer (`MenuAction`) and the hit-map name it.

const std = @import("std");

const ConfigSort = @import("../config/Config.zig").ListSort;

/// // changed (git): `git` — the status rows in the rail.
/// // changed (lsp): `diagnostics` — the LSP problems list lives in the
/// right slot like the other list panels.
/// // changed (http-more): `http` — the seven-section HTTP sidebar.
/// // changed (section-side): `outline` — the symbol outline drawn in a
/// column (`App.outline_panel` is its pane) when its column is open.
/// // changed (debug-ui): `debug` — the DEBUG section (variables, watch,
/// call stack, breakpoints) is a column surface like the rest.
pub const PanelId = enum { todos, notes, findings, sessions, git, diagnostics, http, outline, debug };

/// How a list panel orders its rows. Every key is paired with its
/// reverse; the four are what the right-click menu lists and what the
/// `sort:` chip cycles through.
pub const ListSort = enum {
    newest,
    oldest,
    name,
    name_desc,

    pub const all = [_]ListSort{ .newest, .oldest, .name, .name_desc };

    pub fn label(s: ListSort) []const u8 {
        return switch (s) {
            .newest => "Newest first",
            .oldest => "Oldest first",
            .name => "Name (A–Z)",
            .name_desc => "Name (Z–A)",
        };
    }

    /// Config token; short and stable.
    pub fn token(s: ListSort) []const u8 {
        return @tagName(s);
    }

    /// Unknown tokens fall back to the default — a typo must not stop the
    /// panel drawing. `newest` / `name` predate the reversed pairs and
    /// keep meaning what they always did.
    pub fn fromToken(t: []const u8) ListSort {
        const s = std.mem.trim(u8, t, " \t");
        inline for (all) |m| if (std.ascii.eqlIgnoreCase(s, @tagName(m))) return m;
        return .newest;
    }

    /// The config schema spells the same four choices as its own enum
    /// (`Config.ListSort`, so the loader and the settings overlay need
    /// no core import). The two are kept in step by name.
    /// // changed (panels): the bridge lives here so every list panel
    /// reads and persists `ui.<panel>_sort` the same way.
    pub fn toConfig(s: ListSort) ConfigSort {
        return std.meta.stringToEnum(ConfigSort, @tagName(s)) orelse .newest;
    }

    pub fn fromConfig(c: ConfigSort) ListSort {
        return fromToken(@tagName(c));
    }

    pub fn next(s: ListSort) ListSort {
        return switch (s) {
            .newest => .oldest,
            .oldest => .name,
            .name => .name_desc,
            .name_desc => .newest,
        };
    }

    /// Widest label, in code points — the chip pads to it so it never
    /// resizes under a repeat-clicking pointer.
    pub const widest_label: usize = blk: {
        var w: usize = 0;
        for (all) |m| w = @max(w, std.unicode.utf8CountCodepoints(m.label()) catch unreachable);
        break :blk w;
    };
};

test "sort tokens round-trip and unknown falls back" {
    for (ListSort.all) |m| try std.testing.expectEqual(m, ListSort.fromToken(m.token()));
    for (ListSort.all) |m| try std.testing.expectEqual(m, ListSort.fromConfig(m.toConfig()));
    try std.testing.expectEqual(ListSort.newest, ListSort.fromToken("bogus"));
    try std.testing.expectEqual(ListSort.name_desc, ListSort.fromToken(" NAME_DESC "));
    var m: ListSort = .newest;
    for (0..4) |_| m = m.next();
    try std.testing.expectEqual(ListSort.newest, m);
    try std.testing.expectEqual(@as(usize, 12), ListSort.widest_label);
}
