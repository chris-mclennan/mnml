//! The which-key leader tree (NvChad-style). `<space>` in vim Normal
//! mode and `Ctrl+K` under the standard keymap open it at the root; each
//! key descends; a leaf runs its command. A binding is a leaf *or* a
//! group, never both, so the state is just the path typed so far.
//!
//! The tree is DERIVED at comptime from the spec table's leader chords
//! (`commands/specs.zig`, every `space …` key): a chord typed fast (the
//! keymap reads the spec) and the same chord walked in the popup (this
//! tree) are one entry. What the spec table does not carry stays here
//! in two small side tables: the group labels by prefix (`groups`) and
//! the `dead` rows the Rust popup shows for commands that no longer
//! exist there either (the `+pr` pair went with the SCM split).

const std = @import("std");
const command = @import("../core/command.zig");
const CommandId = command.CommandId;

pub const Node = union(enum) {
    cmd: struct { id: CommandId, label: []const u8 },
    group: struct { label: []const u8, kids: []const Entry },
    dead: struct { id: []const u8, label: []const u8 },
    /// A command an installed integration registered, with the chord
    /// its manifest declared. The strings belong to the registry, which
    /// outlives the frame.
    dyn: struct { id: []const u8, label: []const u8 },
    /// The step into a deeper integration chord (`<leader>ij` on the
    /// way to `<leader>ijw`). Its children are read from the registry
    /// the same way, so there is no tree to keep in step.
    dyn_group: struct { label: []const u8 },

    pub fn label(n: *const Node) []const u8 {
        return switch (n.*) {
            .cmd => |c| c.label,
            .group => |g| g.label,
            .dead => |d| d.label,
            .dyn => |d| d.label,
            .dyn_group => |g| g.label,
        };
    }
};

/// `vim_only`: shown and reachable in the vim profile only.
pub const Entry = struct { key: u8, node: Node, vim_only: bool = false };

// ─── the tree, derived from the spec table ──────────────────────────────

/// A group's row: the prefix it sits at (`"f"`, `"Lc"`) and its label.
/// The only thing the tree says that the spec table does not — every
/// leaf under it is a `space …` chord in `commands/specs.zig`.
pub const Group = struct { prefix: []const u8, label: []const u8 };

/// Every group, keyed by prefix. A spec chord under a prefix no row
/// here names is a compile error, so a chord cannot be bound without a
/// place in the popup. The glyphs are `ui/whichkey_glyph.zig`'s,
/// keyed by these labels.
pub const groups = [_]Group{
    .{ .prefix = "f", .label = "+find" },
    .{ .prefix = "c", .label = "+nvchad" },
    // NvChad's `<leader>ra` (vim only: the leaf under it is).
    .{ .prefix = "r", .label = "+lsp" },
    .{ .prefix = "s", .label = "+split" },
    // nvim-dap's leader chords (`docs/KEYMAP_PROFILES.md` → Debugger).
    .{ .prefix = "d", .label = "+debug" },
    .{ .prefix = "l", .label = "+lsp" },
    .{ .prefix = "g", .label = "+git" },
    .{ .prefix = "a", .label = "+ai/term" },
    .{ .prefix = "t", .label = "+toggle" },
    // NvChad's `<leader>h` is the horizontal terminal, so the requests
    // sit under `R`.
    .{ .prefix = "R", .label = "+http" },
    .{ .prefix = "T", .label = "+test" },
    .{ .prefix = "L", .label = "+lang/run" },
    .{ .prefix = "Lc", .label = "+cargo" },
    .{ .prefix = "Ln", .label = "+npm" },
    .{ .prefix = "Lp", .label = "+pytest" },
    .{ .prefix = "Lg", .label = "+go" },
    .{ .prefix = "P", .label = "+pr" },
    .{ .prefix = "i", .label = "+integrations" },
    .{ .prefix = "I", .label = "+insert" },
    // Named layouts — the tab page under a name (`app/named_layouts.zig`).
    .{ .prefix = "W", .label = "+layouts" },
    .{ .prefix = "H", .label = "+harpoon" },
    // NvChad's `<leader>wK`: `<leader>w` is a prefix, never a save.
    .{ .prefix = "w", .label = "+which-key" },
};

/// A row the Rust popup shows for a command that no longer exists there
/// either (the `+pr` pair went with the SCM split): it paints, and the
/// press explains. Not a command, so not in the spec table.
pub const Dead = struct { path: []const u8, id: []const u8, label: []const u8 };

pub const dead_rows = [_]Dead{
    .{ .path = "Pp", .id = "pr.picker", .label = "PRs: cross-host picker (Enter URL / Tab pipeline)" },
    .{ .path = "Pr", .id = "pr.refresh", .label = "PRs: refresh cross-host cache (background)" },
};

/// A leader chord from the spec table: `space f f` in `keys.both` is
/// the leaf `ff` in both profiles; in `keys.vim` it is the vim
/// profile's alone.
pub const Leaf = struct { path: []const u8, id: CommandId, label: []const u8, vim_only: bool };

/// `space f f` → `"ff"`; null for a chord that is not a leader chain
/// of plain characters (and for the bare leader, `space`).
pub fn leaderPath(comptime spec: []const u8) ?[]const u8 {
    comptime {
        var it = std.mem.splitScalar(u8, spec, ' ');
        const head = it.next() orelse return null;
        if (!std.mem.eql(u8, head, "space")) return null;
        var path: []const u8 = "";
        while (it.next()) |tok| {
            if (tok.len != 1 or tok[0] < 0x21 or tok[0] > 0x7e) return null;
            path = path ++ tok;
        }
        if (path.len == 0) return null;
        return path;
    }
}

/// Every leader chord of the spec table, in table order.
pub const leaves: []const Leaf = blk: {
    @setEvalBranchQuota(4_000_000);
    const specs = @import("../commands/specs.zig");
    var out: []const Leaf = &.{};
    for (specs.specs) |s| {
        const label = if (s.short.len > 0) s.short else s.title;
        const id = @field(CommandId, s.id);
        for (s.keys.both) |k| if (leaderPath(k)) |p| {
            out = out ++ &[_]Leaf{.{ .path = p, .id = id, .label = label, .vim_only = false }};
        };
        for (s.keys.vim) |k| if (leaderPath(k)) |p| {
            out = out ++ &[_]Leaf{.{ .path = p, .id = id, .label = label, .vim_only = true }};
        };
        // The standard profile's popup is the same tree less the vim
        // rows; a leader chord for it alone has nowhere to go.
        for (s.keys.standard) |k| if (leaderPath(k) != null)
            @compileError("leader chord `" ++ k ++ "` of " ++ s.id ++ " is in keys.standard: a which-key row is keys.both (both profiles) or keys.vim");
    }
    break :blk out;
};

fn groupLabel(comptime prefix: []const u8) ?[]const u8 {
    for (groups) |g| if (std.mem.eql(u8, g.prefix, prefix)) return g.label;
    return null;
}

/// The entry at `path`: a leaf (one command, whichever profiles bind
/// it), a dead row, or a group with its kids.
fn entryAt(comptime path: []const u8) Entry {
    comptime {
        const key = path[path.len - 1];
        var leaf: ?Leaf = null;
        var deeper = false;
        for (leaves) |l| {
            if (std.mem.eql(u8, l.path, path)) {
                if (leaf) |o| {
                    if (o.id != l.id) @compileError("leader chord `space " ++ path ++ "` names two commands: " ++ @tagName(o.id) ++ " and " ++ @tagName(l.id));
                    leaf = .{ .path = path, .id = o.id, .label = o.label, .vim_only = o.vim_only and l.vim_only };
                } else leaf = l;
            } else if (std.mem.startsWith(u8, l.path, path)) deeper = true;
        }
        for (dead_rows) |d| {
            if (std.mem.eql(u8, d.path, path)) {
                if (leaf != null) @compileError("dead row `" ++ path ++ "` is also a command's chord");
                return .{ .key = key, .node = .{ .dead = .{ .id = d.id, .label = d.label } } };
            }
            if (std.mem.startsWith(u8, d.path, path)) deeper = true;
        }
        if (leaf) |l| {
            if (deeper) @compileError("leader chord `space " ++ path ++ "` (" ++ @tagName(l.id) ++ ") is also the prefix of a longer chord: a row is a leaf or a group, never both");
            return .{ .key = key, .vim_only = l.vim_only, .node = .{ .cmd = .{ .id = l.id, .label = l.label } } };
        }
        const label = groupLabel(path) orelse
            @compileError("leader chords under `space " ++ path ++ "` have no group: add a row to `whichkey.groups`");
        const kids = kidsAt(path);
        var vim_only = true;
        for (kids) |k| {
            if (!k.vim_only) vim_only = false;
        }
        return .{ .key = key, .vim_only = vim_only, .node = .{ .group = .{ .label = label, .kids = kids } } };
    }
}

/// The distinct next keys under `prefix`, each as its entry.
fn kidsAt(comptime prefix: []const u8) []const Entry {
    comptime {
        var seen: []const u8 = "";
        var out: []const Entry = &.{};
        for (leaves) |l| {
            if (l.path.len > prefix.len and std.mem.startsWith(u8, l.path, prefix) and std.mem.indexOfScalar(u8, seen, l.path[prefix.len]) == null) {
                seen = seen ++ l.path[prefix.len .. prefix.len + 1];
                out = out ++ &[_]Entry{entryAt(l.path[0 .. prefix.len + 1])};
            }
        }
        for (dead_rows) |d| {
            if (d.path.len > prefix.len and std.mem.startsWith(u8, d.path, prefix) and std.mem.indexOfScalar(u8, seen, d.path[prefix.len]) == null) {
                seen = seen ++ d.path[prefix.len .. prefix.len + 1];
                out = out ++ &[_]Entry{entryAt(d.path[0 .. prefix.len + 1])};
            }
        }
        // A group row that no chord reaches is a label with nothing
        // under it — the table has drifted from the specs.
        if (prefix.len == 0) for (groups) |g| {
            var used = false;
            for (leaves) |l| {
                if (std.mem.startsWith(u8, l.path, g.prefix) and l.path.len > g.prefix.len) used = true;
            }
            for (dead_rows) |d| {
                if (std.mem.startsWith(u8, d.path, g.prefix) and d.path.len > g.prefix.len) used = true;
            }
            if (!used) @compileError("which-key group `" ++ g.prefix ++ "` (" ++ g.label ++ ") has no chord under it");
        };
        return out;
    }
}

/// The popup's tree. Every leaf is a `space …` chord of the spec table
/// (`keys.both`, or `keys.vim` for the vim profile's alone), so a chord
/// typed fast and the same chord walked in the popup can never name two
/// different things, and a chord can never be in one and not the other.
pub const root: Node = .{ .group = .{ .label = "<leader>", .kids = blk: {
    @setEvalBranchQuota(4_000_000);
    const kids = kidsAt("");
    break :blk kids;
} } };

pub const max_depth = 8;

/// How the ACTIVE profile spells the key that opens this popup. The vim
/// profile has a leader and writes it Neovim's way; the standard profile
/// has none — it opens the popup on `Ctrl+K` (`docs/KEYMAP_PROFILES.md`
/// rule 2). The header and the dead-end toast both read it here, so
/// neither can name a chord its profile does not carry. A deliberate
/// departure from the reference editor, which titles both profiles
/// `<leader>` (`docs/PARITY.md`).
pub fn leaderLabel(vim: bool) []const u8 {
    return if (vim) "<leader>" else "Ctrl+K";
}

/// The gap between the leader and the keys typed after it: none in vim
/// (`<leader>f`), one cell for a chord spelling (`Ctrl+K f`).
pub fn leaderGap(vim: bool) []const u8 {
    return if (vim) "" else " ";
}

/// The keys typed since the leader.
pub const State = struct {
    path: [max_depth]u8 = undefined,
    len: usize = 0,

    pub fn slice(s: *const State) []const u8 {
        return s.path[0..s.len];
    }
};

/// The node at `path` in the vim profile's tree (every entry).
pub fn lookup(path: []const u8) ?*const Node {
    return lookupIn(path, true);
}

/// The node at `path`; under the standard profile (`vim = false`) a
/// `vim_only` entry is not there.
pub fn lookupIn(path: []const u8, vim: bool) ?*const Node {
    var node: *const Node = &root;
    for (path) |ch| {
        switch (node.*) {
            .group => |g| {
                node = for (g.kids) |*k| {
                    if (k.key == ch and (vim or !k.vim_only)) break &k.node;
                } else return null;
            },
            .cmd, .dead, .dyn, .dyn_group => return null,
        }
    }
    return node;
}

// ─── the rows an installed integration adds ─────────────────────────────

/// The continuation an integration's chord contributes at `path`, if
/// any: `<leader>ib` seen from `"i"` is the leaf `b`, and `<leader>ijw`
/// seen from `"i"` is the step `j`. Only all-ASCII, unmodified,
/// space-led chords take part — anything else is a chord, not a leader
/// row, and is left to the keymap.
fn dynEntryAt(spec: []const u8, path: []const u8, id: []const u8, title: []const u8, owner: []const u8) ?Entry {
    var it = std.mem.splitScalar(u8, spec, ' ');
    const head = it.next() orelse return null;
    if (!std.mem.eql(u8, head, "space")) return null;
    var rest: [max_depth + 1]u8 = undefined;
    var n: usize = 0;
    while (it.next()) |tok| {
        if (tok.len != 1 or tok[0] < 0x21 or tok[0] > 0x7e) return null;
        if (n == rest.len) return null;
        rest[n] = tok[0];
        n += 1;
    }
    if (n <= path.len) return null;
    if (!std.mem.eql(u8, rest[0..path.len], path)) return null;
    const key = rest[path.len];
    if (n == path.len + 1) return .{ .key = key, .node = .{ .dyn = .{ .id = id, .label = title } } };
    return .{ .key = key, .node = .{ .dyn_group = .{ .label = owner } } };
}

/// Every integration row at `path`, in registration order, skipping a
/// key the static tree already owns — the built-in wins, so installing
/// something can never take a chord out from under the editor.
pub fn dynamicKids(arena: std.mem.Allocator, reg: *const command.DynRegistry, path: []const u8, static_kids: []const Entry) std.mem.Allocator.Error![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    var slot: u32 = 0;
    while (reg.at(slot)) |c| : (slot += 1) {
        const owner = switch (c.owner) {
            .integration => |name| name,
            else => "plugin",
        };
        for (c.keys) |spec| {
            const e = dynEntryAt(spec, path, c.id, c.title, owner) orelse continue;
            var taken = false;
            for (static_kids) |k| {
                if (k.key == e.key) taken = true;
            }
            for (out.items) |k| {
                if (k.key == e.key) taken = true;
            }
            if (!taken) try out.append(arena, e);
        }
    }
    return out.toOwnedSlice(arena);
}

/// The node at `path` counting the integrations' rows — what the popup
/// descends through and what a press resolves against.
pub fn lookupWith(arena: std.mem.Allocator, reg: *const command.DynRegistry, path: []const u8, vim: bool) std.mem.Allocator.Error!?Node {
    if (lookupIn(path, vim)) |n| return n.*;
    if (path.len == 0) return null;
    const parent = path[0 .. path.len - 1];
    // The parent must itself exist, statically or as a step.
    if ((try lookupWith(arena, reg, parent, vim)) == null) return null;
    const statics = continuations(arena, parent, vim);
    for (try dynamicKids(arena, reg, parent, statics)) |e| {
        if (e.key == path[path.len - 1]) return e.node;
    }
    return null;
}

/// `continuations` plus the integrations' rows.
pub fn kidsWith(arena: std.mem.Allocator, reg: *const command.DynRegistry, path: []const u8, vim: bool) std.mem.Allocator.Error![]const Entry {
    const statics = continuations(arena, path, vim);
    const dyns = try dynamicKids(arena, reg, path, statics);
    if (dyns.len == 0) return statics;
    var out = try arena.alloc(Entry, statics.len + dyns.len);
    @memcpy(out[0..statics.len], statics);
    @memcpy(out[statics.len..], dyns);
    return out;
}

/// The continuations at `path` for the profile; empty when it is not
/// a group. Frame-arena copy when a `vim_only` entry is dropped.
pub fn continuations(arena: std.mem.Allocator, path: []const u8, vim: bool) []const Entry {
    const n = lookupIn(path, vim) orelse return &.{};
    const kids = switch (n.*) {
        .group => |g| g.kids,
        .cmd, .dead, .dyn, .dyn_group => return &.{},
    };
    if (vim) return kids;
    var any = false;
    for (kids) |k| if (k.vim_only) {
        any = true;
    };
    if (!any) return kids;
    var out = arena.alloc(Entry, kids.len) catch return kids;
    var n_out: usize = 0;
    for (kids) |k| if (!k.vim_only) {
        out[n_out] = k;
        n_out += 1;
    };
    return out[0..n_out];
}

/// The chords beneath a node, recursively: a leaf is one of its own, a
/// group is the sum of its kids'. What the popup shows in a group row's
/// `+find (7)` — read off the tree, so a chord added below changes the
/// number with nothing else to edit. `vim = false` leaves the `vim_only`
/// entries out, as that profile's popup does.
pub fn chordCount(n: *const Node, vim: bool) u16 {
    return switch (n.*) {
        .cmd, .dead, .dyn => 1,
        // A step's rows are the registry's; the popup counts them when
        // it paints the row, not here.
        .dyn_group => 1,
        .group => |g| blk: {
            var sum: u16 = 0;
            for (g.kids) |k| {
                if (!vim and k.vim_only) continue;
                sum += chordCount(&k.node, vim);
            }
            break :blk sum;
        },
    };
}

test "leader tree: root groups, descend, leaves, dead ends" {
    try std.testing.expect(lookup("") != null);
    try std.testing.expectEqualStrings("+split", lookup("s").?.label());
    try std.testing.expectEqual(CommandId.@"view.split_right", lookup("sv").?.cmd.id);
    try std.testing.expect(lookup("zz") == null);
    try std.testing.expect(lookup("svx") == null);
    try std.testing.expect(continuations(std.testing.allocator, "s", true).len == 13);
    // The needs-you jumps sit with the sessions (`+ai/term`), vim only:
    // the standard profile has Ctrl+Alt+N / Ctrl+Alt+Shift+N.
    try std.testing.expectEqual(CommandId.@"sessions.next_waiting", lookupIn("aj", true).?.cmd.id);
    try std.testing.expectEqual(CommandId.@"sessions.prev_waiting", lookupIn("ak", true).?.cmd.id);
    try std.testing.expect(lookupIn("aj", false) == null);
    try std.testing.expect(lookupIn("sn", true) == null);
    try std.testing.expect(continuations(std.testing.allocator, "sv", true).len == 0);
    // `+debug` and `+lsp` on `r` are the vim profile's — nvim-dap's
    // door and NvChad's `<leader>ra`; the standard popup keeps the
    // reference editor's rows, which carry neither.
    try std.testing.expect(lookupIn("d", true) != null);
    try std.testing.expect(lookupIn("d", false) == null);
    try std.testing.expect(lookupIn("db", false) == null);
    try std.testing.expect(lookupIn("r", true) != null);
    try std.testing.expect(lookupIn("r", false) == null);
    try std.testing.expectEqual(CommandId.@"lsp.rename", lookupIn("ra", true).?.cmd.id);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const std_root = continuations(arena_state.allocator(), "", false);
    for (std_root) |e| try std.testing.expect(e.key != 'd' and e.key != 'r');
    // The vim profile's root adds `+debug`, `+lsp` on `r`, `+nvchad`,
    // `+which-key` and NvChad's `x` / `h` / `v` / `e` / `E` / `/` / `b` / `D`,
    // and `K`, the info view's keyboard route (`help.focus`).
    try std.testing.expectEqual(continuations(arena_state.allocator(), "", true).len - 13, std_root.len);
    // NvChad's `<leader>b` is `:enew`, a leaf — the `+buffer` group is gone.
    try std.testing.expectEqual(CommandId.@"scratch.new", lookupIn("b", true).?.cmd.id);
    try std.testing.expect(lookupIn("b", false) == null);
}

test "leader tree: the groups R T L P i I H, the digits, the root leaves ? B m p o, tr, iE and the t leaves" {
    const t = std.testing;
    for ([_][]const u8{ "R", "T", "L", "i", "I", "H" }) |g| try t.expect(lookup(g).?.* == .group);
    try t.expectEqualStrings("+cargo", lookup("Lc").?.label());
    try t.expectEqual(CommandId.@"cargo.test", lookup("Lct").?.cmd.id);
    try t.expectEqual(CommandId.@"go.run", lookup("Lgr").?.cmd.id);
    try t.expectEqual(CommandId.@"http.send", lookup("Rs").?.cmd.id);
    try t.expectEqual(CommandId.@"test.run_at_cursor", lookup("Tt").?.cmd.id);
    try t.expectEqual(CommandId.@"integrations.toggle_enabled", lookup("iE").?.cmd.id);
    try t.expectEqual(CommandId.@"snippet.pick", lookup("Is").?.cmd.id);
    try t.expectEqual(CommandId.@"harpoon.add", lookup("Ha").?.cmd.id);
    try t.expectEqual(CommandId.@"harpoon.goto_1", lookup("1").?.cmd.id);
    try t.expectEqual(CommandId.@"harpoon.goto_9", lookup("9").?.cmd.id);
    try t.expectEqual(CommandId.@"view.cheatsheet", lookup("?").?.cmd.id);
    try t.expectEqual(CommandId.@"browser.open", lookup("B").?.cmd.id);
    try t.expectEqual(CommandId.@"markdown.preview", lookup("m").?.cmd.id);
    try t.expectEqual(CommandId.palette, lookup("p").?.cmd.id);
    try t.expectEqual(CommandId.@"task.run", lookup("o").?.cmd.id);
    try t.expectEqual(CommandId.@"view.toggle_right_panel", lookup("tr").?.cmd.id);
    try t.expectEqual(CommandId.@"view.toggle_hidden", lookup("th").?.cmd.id);
    try t.expectEqual(CommandId.@"view.toggle_hidden_all", lookup("tH").?.cmd.id);
    try t.expectEqual(CommandId.@"editor.toggle_keymap", lookup("tk").?.cmd.id);
    try t.expectEqual(CommandId.@"theme.pick", lookup("tt").?.cmd.id);
    try t.expectEqual(CommandId.@"view.fullscreen", lookup("tf").?.cmd.id);
    // One zoom spelling, beside the split verbs.
    try t.expectEqual(CommandId.@"view.toggle_zoom", lookup("sz").?.cmd.id);
    try t.expect(lookup("tz") == null);
    try t.expect(lookup("zz") == null);
    try t.expectEqual(CommandId.@"view.reset_layout", lookup("t0").?.cmd.id);
    // NvChad's root: `x` closes the buffer, `h` / `v` open terminals,
    // and `w` is the `wK` prefix — never a save.
    try t.expectEqual(CommandId.@"buffer.close", lookup("q").?.cmd.id);
    try t.expectEqual(CommandId.@"buffer.close", lookup("x").?.cmd.id);
    try t.expectEqual(CommandId.@"term.shell_bottom", lookup("h").?.cmd.id);
    try t.expectEqual(CommandId.@"term.shell_right", lookup("v").?.cmd.id);
    try t.expectEqualStrings("explorer", lookup("e").?.label());
    try t.expectEqualStrings("+which-key", lookup("w").?.label());
    try t.expectEqual(CommandId.@"whichkey.leader", lookup("wK").?.cmd.id);
    // The +pr group paints with its two dead leaves; the cut ones are not offered.
    try t.expectEqualStrings("+pr", lookup("P").?.label());
    try t.expectEqualStrings("pr.picker", lookup("Pp").?.dead.id);
    try t.expect(lookup("Ppx") == null);
    try t.expect(lookup("aM") == null);
    try t.expect(lookup("ip") == null);
    try t.expect(lookup("Lcr") == null);
    // Every key at the root is unique (a group's kids too) — the trie
    // would silently shadow the second otherwise.
    try expectUniqueKeys(&root);
}

test "every group in both profiles has a glyph with an ascii twin, and the counts are the tree's" {
    const t = std.testing;
    const glyphs = @import("../ui/whichkey_glyph.zig");
    // Both profiles, every group reachable in it: a row of its own in
    // the table (not the neutral fall-through) and a one-byte twin.
    for ([_]bool{ true, false }) |vim| {
        var stack: [64]*const Node = undefined;
        var n_stack: usize = 1;
        stack[0] = &root;
        var seen: usize = 0;
        while (n_stack > 0) {
            n_stack -= 1;
            const node = stack[n_stack];
            const g = node.group;
            if (node != &root) {
                seen += 1;
                const face = glyphs.forGroup(g.label);
                if (std.mem.eql(u8, face.glyph, glyphs.neutral.glyph)) {
                    std.debug.print("which-key group with no glyph: {s}\n", .{g.label});
                    return error.GroupWithoutGlyph;
                }
                try t.expect(face.fallback.len == 1 and std.ascii.isPrint(face.fallback[0]));
            }
            for (g.kids) |*k| {
                if (!vim and k.vim_only) continue;
                if (k.node == .group) {
                    stack[n_stack] = &k.node;
                    n_stack += 1;
                }
            }
        }
        // The standard profile's groups (vim adds `+debug`, `+lsp` on
        // `r`, `+nvchad`, `+which-key`); `+buffer` went with NvChad's
        // `<leader>b`.
        try t.expect(seen >= 18);
    }
    // The count is a walk of the tree, not a literal: an iterative
    // sweep of every leaf beneath a node agrees with `chordCount`.
    for ([_][]const u8{ "", "f", "s", "g", "L", "Lc", "t", "a", "l", "d", "T", "R", "i", "H", "I", "P", "c", "r", "W", "w" }) |path| {
        for ([_]bool{ true, false }) |vim| {
            const n = lookupIn(path, vim) orelse continue;
            try t.expectEqual(leavesUnder(n, vim), chordCount(n, vim));
        }
    }
    // The numbers the popup paints today, so a chord added or dropped
    // shows up here rather than silently on screen.
    try t.expectEqual(@as(u16, 8), chordCount(lookup("f").?, true));
    try t.expectEqual(@as(u16, 4), chordCount(lookup("f").?, false));
    try t.expectEqual(@as(u16, 13), chordCount(lookup("s").?, true));
    try t.expectEqual(@as(u16, 12), chordCount(lookup("s").?, false));
    try t.expectEqual(@as(u16, 5), chordCount(lookup("Lc").?, true));
    try t.expectEqual(@as(u16, 20), chordCount(lookup("L").?, true));
    try t.expectEqual(@as(u16, 16), chordCount(lookup("d").?, true));
    try t.expectEqual(@as(u16, 1), chordCount(lookup("Pp").?, true));
    // The root: every chord the spec table binds in `keys.vim` alone
    // is a row the standard popup does not show.
    var vim_only: u16 = 0;
    for (leaves) |l| {
        if (l.vim_only) vim_only += 1;
    }
    // (+2: `space t p` and `space K`, the info view's pin and its
    // keyboard route — hoverpin)
    try t.expectEqual(@as(u16, 46), vim_only);
    try t.expectEqual(chordCount(&root, false) + vim_only, chordCount(&root, true));
    // NvChad's `<leader>ds` / `<leader>rn`, vim-only like their groups.
    try t.expectEqual(CommandId.@"lsp.diagnostics", lookup("ds").?.cmd.id);
    try t.expectEqual(CommandId.@"view.toggle_relative_numbers", lookup("rn").?.cmd.id);
    try t.expect(lookupIn("rn", false) == null);
}

test "one leader table: every spec leader chord is the tree's row at the same path in each profile, and every tree row is a spec chord" {
    const t = std.testing;
    const specs = @import("../commands/specs.zig");
    var from_specs: usize = 0;
    for (specs.specs) |s| {
        const id = command.by_name.get(s.id).?;
        for ([_]struct { list: []const []const u8, vim: bool, standard: bool }{
            .{ .list = s.keys.both, .vim = true, .standard = true },
            .{ .list = s.keys.vim, .vim = true, .standard = false },
        }) |side| for (side.list) |k| {
            const path = runtimeLeaderPath(k) orelse continue;
            from_specs += 1;
            // Present at that path, naming that command, in every
            // profile that binds it ...
            for ([_]bool{ true, false }) |vim| {
                const bound = if (vim) side.vim else side.standard;
                const n = lookupIn(path.slice(), vim);
                if (bound) {
                    if (n == null or n.?.* != .cmd or n.?.cmd.id != id) {
                        std.debug.print("spec chord `{s}` ({s}) is not the tree's row in the {s} profile\n", .{ k, s.id, if (vim) "vim" else "standard" });
                        return error.LeaderTablesDisagree;
                    }
                } else if (n != null and n.?.* == .cmd and n.?.cmd.id == id and !isBoth(s, path.slice())) {
                    std.debug.print("vim chord `{s}` ({s}) shows in the standard popup\n", .{ k, s.id });
                    return error.LeaderTablesDisagree;
                }
            }
        };
        for (s.keys.standard) |k| try t.expect(runtimeLeaderPath(k) == null);
    }
    // ... and the tree has no row the specs do not (the dead rows aside).
    try t.expectEqual(from_specs + dead_rows.len, leavesUnder(&root, true));
    try t.expectEqual(leaves.len, from_specs);
}

fn isBoth(s: anytype, path: []const u8) bool {
    for (s.keys.both) |k| if (runtimeLeaderPath(k)) |p| if (std.mem.eql(u8, p.slice(), path)) return true;
    return false;
}

const RtPath = struct {
    buf: [max_depth]u8 = undefined,
    len: usize = 0,
    fn slice(p: *const RtPath) []const u8 {
        return p.buf[0..p.len];
    }
};

/// `leaderPath` at run time, written again so the test does not read
/// the derivation it checks.
fn runtimeLeaderPath(spec: []const u8) ?RtPath {
    var it = std.mem.splitScalar(u8, spec, ' ');
    if (!std.mem.eql(u8, it.next() orelse return null, "space")) return null;
    var p: RtPath = .{};
    while (it.next()) |tok| {
        if (tok.len != 1 or p.len == max_depth) return null;
        p.buf[p.len] = tok[0];
        p.len += 1;
    }
    return if (p.len == 0) null else p;
}

/// An independent counter for the test: every leaf beneath `n`, found
/// with an explicit stack instead of `chordCount`'s recursion.
fn leavesUnder(n: *const Node, vim: bool) u16 {
    var stack: [256]*const Node = undefined;
    var n_stack: usize = 1;
    stack[0] = n;
    var n_leaves: u16 = 0;
    while (n_stack > 0) {
        n_stack -= 1;
        const node = stack[n_stack];
        switch (node.*) {
            .cmd, .dead, .dyn, .dyn_group => n_leaves += 1,
            .group => |g| for (g.kids) |*k| {
                if (!vim and k.vim_only) continue;
                stack[n_stack] = &k.node;
                n_stack += 1;
            },
        }
    }
    return n_leaves;
}

fn expectUniqueKeys(n: *const Node) !void {
    switch (n.*) {
        .cmd, .dead, .dyn, .dyn_group => {},
        .group => |g| {
            for (g.kids, 0..) |a, i| {
                for (g.kids[i + 1 ..]) |b| if (a.key == b.key) {
                    std.debug.print("duplicate which-key '{c}' under {s}\n", .{ a.key, g.label });
                    return error.DuplicateKey;
                };
                try expectUniqueKeys(&a.node);
            }
        },
    }
}

test "the popup: backspace goes up a level, a non-character key leaves it open, a dead end says so" {
    const t = std.testing;
    const app_mod = @import("../app.zig");
    var app = try app_mod.App.initWith(t.allocator, t.io, .{ .workspace = app_mod.App.scratch_workspace });
    defer app.deinit();
    _ = try app.openScratch();
    // The tree is the vim profile's popup; the standard profile's is its
    // `Ctrl+K` chords (the end of this test).
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try command.run(&app, .{ .static = .@"whichkey.leader" });
    try t.expect(app.overlay == .which_key);
    // Down into `+find`.
    try app.handle(.{ .key = app_mod.Key.char('f') });
    try t.expect(app.overlay == .which_key);
    try t.expectEqualStrings("f", app.overlay.which_key.slice());
    // An arrow is not a leader key: the popup stays where it is rather
    // than being dismissed by a stray press.
    try app.handle(.{ .key = app_mod.Key.named(.down) });
    try t.expect(app.overlay == .which_key);
    try t.expectEqualStrings("f", app.overlay.which_key.slice());
    // Backspace climbs back to the root, and closes from there.
    try app.handle(.{ .key = app_mod.Key.named(.backspace) });
    try t.expect(app.overlay == .which_key);
    try t.expectEqualStrings("", app.overlay.which_key.slice());
    try app.handle(.{ .key = app_mod.Key.named(.backspace) });
    try t.expect(app.overlay == .none);
    // A key no row carries says so instead of vanishing silently — and
    // names the key this profile actually opens the popup with: vim's
    // `<leader>`, and the standard profile's `Ctrl+K`, whose popup is its
    // `Ctrl+K` chords.
    try command.run(&app, .{ .static = .@"whichkey.leader" });
    try app.handle(.{ .key = app_mod.Key.char('\\') });
    try t.expect(app.overlay == .none);
    try t.expectEqualStrings("no leader mapping: <leader>\\", app.lastToast().?);
    try command.run(&app, .{ .static = .@"editor.use_standard" });
    try command.run(&app, .{ .static = .@"whichkey.leader" });
    try t.expect(app.overlay == .none and app.chord.menu);
    try app.handle(.{ .key = app_mod.Key.char('\\') });
    try t.expect(app.chord.len == 0);
    try t.expectEqualStrings("no Ctrl+K chord: Ctrl+K \\", app.lastToast().?);
}

test "an installed integration's chord is a row under +integrations, and a built-in row still wins" {
    const t = std.testing;
    const app_mod = @import("../app.zig");
    var app = try app_mod.App.initWith(t.allocator, t.io, .{ .workspace = app_mod.App.scratch_workspace });
    defer app.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The two chords the Bitbucket manifests declare, a Jira-shaped
    // deeper one, and one that collides with a built-in row.
    _ = try app.dyn_commands.register(.{ .id = "bitbucket_prs.open", .title = "Bitbucket PRs: open", .keys = &.{"space i b"}, .owner = .{ .integration = "bitbucket_prs" } });
    _ = try app.dyn_commands.register(.{ .id = "bitbucket_pipelines.open", .title = "Bitbucket Pipelines: open", .keys = &.{"space i l"}, .owner = .{ .integration = "bitbucket_pipelines" } });
    _ = try app.dyn_commands.register(.{ .id = "jira_work.open", .title = "Jira Work: open", .keys = &.{"space i j w"}, .owner = .{ .integration = "jira_work" } });
    _ = try app.dyn_commands.register(.{ .id = "greedy.open", .title = "Greedy", .keys = &.{"space i d"}, .owner = .{ .integration = "greedy" } });

    const kids = try kidsWith(arena, &app.dyn_commands, "i", true);
    var saw_b = false;
    var saw_l = false;
    var saw_j = false;
    var d_is_static = false;
    for (kids) |k| switch (k.key) {
        'b' => {
            saw_b = true;
            try t.expectEqualStrings("bitbucket_prs.open", k.node.dyn.id);
            try t.expectEqualStrings("Bitbucket PRs: open", k.node.label());
        },
        'l' => {
            saw_l = true;
            try t.expectEqualStrings("bitbucket_pipelines.open", k.node.dyn.id);
        },
        // The three-deep chord shows as the step it is, labelled by the
        // integration that owns it.
        'j' => {
            saw_j = true;
            try t.expectEqualStrings("jira_work", k.node.dyn_group.label);
        },
        // `i d` is `integrations.show_details`: the built-in keeps it.
        'd' => d_is_static = k.node == .cmd,
        else => {},
    };
    try t.expect(saw_b and saw_l and saw_j);
    try t.expect(d_is_static);

    // Resolution by path, which is what a press in the popup uses.
    try t.expectEqualStrings("bitbucket_prs.open", (try lookupWith(arena, &app.dyn_commands, "ib", true)).?.dyn.id);
    try t.expectEqualStrings("bitbucket_pipelines.open", (try lookupWith(arena, &app.dyn_commands, "il", true)).?.dyn.id);
    try t.expect((try lookupWith(arena, &app.dyn_commands, "ij", true)).? == .dyn_group);
    try t.expectEqualStrings("jira_work.open", (try lookupWith(arena, &app.dyn_commands, "ijw", true)).?.dyn.id);
    try t.expect((try lookupWith(arena, &app.dyn_commands, "iz", true)) == null);
    // A chord that is not leader-led is not a row.
    _ = try app.dyn_commands.register(.{ .id = "other.open", .title = "Other", .keys = &.{"ctrl+alt+o"}, .owner = .{ .integration = "other" } });
    try t.expectEqual(kids.len, (try kidsWith(arena, &app.dyn_commands, "i", true)).len);

    // And the popup walks to it: <leader> i b runs the command.
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try command.run(&app, .{ .static = .@"whichkey.leader" });
    try app.handle(.{ .key = app_mod.Key.char('i') });
    try t.expectEqualStrings("i", app.overlay.which_key.slice());
    try app.handle(.{ .key = app_mod.Key.char('b') });
    try t.expect(app.overlay == .none);
}

test "no built-in chord claims `space i b` or `space i l`, so the Bitbucket manifests cannot shadow one" {
    const t = std.testing;
    const specs = @import("../commands/specs.zig");
    for (specs.specs) |s| {
        const lists = [_][]const []const u8{ s.keys.vim, s.keys.standard, s.keys.both };
        for (lists) |list| {
            for (list) |k| {
                try t.expect(!std.mem.eql(u8, k, "space i b"));
                try t.expect(!std.mem.eql(u8, k, "space i l"));
            }
        }
    }
    // Nor does the leader tree carry a row on those paths.
    try t.expect(lookup("ib") == null);
    try t.expect(lookup("il") == null);
    try t.expect(lookup("i") != null);
}
