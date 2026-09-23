//! The which-key leader tree (NvChad-style). `<space>` in vim Normal
//! mode and `Ctrl+K` under the standard keymap open it at the root; each
//! key descends; a leaf runs its command. A binding is a leaf *or* a
//! group, never both, so the state is just the path typed so far.
//!
//! Every leaf names a `CommandId` — a typo is a compile error — except
//! a `dead` leaf, which is a row the Rust popup shows for a command
//! that no longer exists there either (the `+pr` pair went with the
//! SCM split); pressing it says so.

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

fn cmd(key: u8, id: CommandId, label: []const u8) Entry {
    return .{ .key = key, .node = .{ .cmd = .{ .id = id, .label = label } } };
}

fn dead(key: u8, id: []const u8, label: []const u8) Entry {
    return .{ .key = key, .node = .{ .dead = .{ .id = id, .label = label } } };
}

fn group(key: u8, label: []const u8, kids: []const Entry) Entry {
    return .{ .key = key, .node = .{ .group = .{ .label = label, .kids = kids } } };
}

/// A group the vim profile alone shows — nvim-dap's `<leader>d` is a
/// Neovim door; the standard profile's `Ctrl+K` popup keeps Rust's rows.
fn groupVim(key: u8, label: []const u8, kids: []const Entry) Entry {
    return .{ .key = key, .vim_only = true, .node = .{ .group = .{ .label = label, .kids = kids } } };
}

pub const root: Node = .{
    .group = .{
        .label = "<leader>",
        .kids = &.{
            group('f', "+find", &.{
                cmd('f', .@"picker.files", "files"),
                cmd('b', .@"picker.buffers", "buffers"),
                cmd('g', .@"find.grep", "grep"),
                cmd('m', .@"lsp.format", "format buffer"),
                cmd('r', .@"picker.recent", "recent"),
                cmd('o', .@"picker.recent", "oldfiles"),
                cmd('z', .@"find.find", "find in current buffer"),
            }),
            cmd('/', .@"editor.toggle_line_comment", "toggle comment"),
            cmd('n', .@"view.toggle_line_numbers", "line numbers"),
            cmd('e', .@"view.focus_tree", "explorer"),
            // // changed (sidebar-autohide): the pin sits beside the
            // explorer it docks, in both profiles.
            cmd('E', .@"view.sidebar_pin", "pin/unpin the sidebar"),
            cmd('w', .@"file.save", "write/save"),
            cmd('q', .@"buffer.close", "close buffer"),
            group('c', "+nvchad", &.{
                cmd('h', .@"view.cheatsheet", "cheatsheet (all chords)"),
                cmd('a', .@"lsp.code_action", "code action"),
                cmd('m', .@"git.graph", "git commits"),
            }),
            // NvChad's `<leader>ra`, which the reference editor's own
            // popup does not carry: vim-only, as `+debug` is, so the
            // standard profile's Ctrl+K popup keeps the reference rows.
            groupVim('r', "+lsp", &.{
                cmd('a', .@"lsp.rename", "rename symbol"),
            }),
            group('b', "+buffer", &.{
                cmd('n', .@"buffer.next", "next"),
                cmd('p', .@"buffer.prev", "previous"),
                cmd('d', .@"buffer.close", "delete"),
                cmd('r', .@"buffer.reopen", "reopen closed"),
                cmd('b', .@"picker.buffers", "switch"),
                cmd('k', .@"view.keep_tab", "keep preview tab"),
            }),
            group('s', "+split", &.{
                cmd('v', .@"view.split_right", "split right"),
                cmd('s', .@"view.split_down", "split down"),
                cmd('h', .@"view.focus_left", "focus left"),
                cmd('j', .@"view.focus_down", "focus down"),
                cmd('k', .@"view.focus_up", "focus up"),
                cmd('l', .@"view.focus_right", "focus right"),
                cmd('w', .@"view.focus_next_split", "focus next"),
                cmd('W', .@"view.focus_prev_split", "focus previous"),
                cmd('c', .@"view.close_split", "close split"),
                cmd('o', .@"view.close_others", "close others"),
                cmd('z', .@"view.toggle_zoom", "zoom / restore"),
                cmd('H', .@"view.move_section_left", "section → left side"),
                cmd('L', .@"view.move_section_right", "section → right side"),
                cmd('r', .@"script.run_selection", "run Lua selection"),
            }),
            // nvim-dap's leader chords (`docs/KEYMAP_PROFILES.md` → Debugger).
            groupVim('d', "+debug", &.{
                cmd('b', .@"dap.toggle_breakpoint", "toggle breakpoint"),
                cmd('B', .@"dap.toggle_breakpoint_conditional", "conditional breakpoint"),
                cmd('l', .@"dap.set_breakpoint_log_message", "log point"),
                cmd('c', .@"dap.continue", "continue / start"),
                cmd('o', .@"dap.next", "step over"),
                cmd('i', .@"dap.step_in", "step into"),
                cmd('O', .@"dap.step_out", "step out"),
                cmd('p', .@"dap.pause", "pause"),
                cmd('R', .@"dap.restart", "restart"),
                cmd('t', .@"dap.terminate", "terminate"),
                cmd('r', .@"dap.repl", "debug console"),
                cmd('w', .@"dap.add_watch", "add watch"),
                cmd('u', .@"dap.toggle_panel", "toggle DEBUG section"),
                cmd('h', .@"dap.evaluate_hover", "evaluate word (hover)"),
                cmd('e', .@"dap.exceptions", "exception breakpoints"),
            }),
            group('l', "+lsp", &.{
                cmd('a', .@"lsp.code_action", "code actions"),
                cmd('c', .@"lsp.completion", "complete at cursor"),
                cmd('s', .@"lsp.symbols", "symbols in this file"),
                cmd('S', .@"lsp.workspace_symbols", "workspace symbols…"),
                cmd('o', .@"outline.show", "outline pane"),
                cmd('d', .@"lsp.goto_definition", "go to definition"),
                cmd('h', .@"lsp.hover", "hover docs"),
                cmd('r', .@"lsp.references", "find references"),
                cmd('R', .@"lsp.rename", "rename symbol"),
                cmd('e', .@"lsp.diagnostics", "diagnostics list"),
                cmd('n', .@"lsp.next_diagnostic", "next diagnostic"),
                cmd('p', .@"lsp.prev_diagnostic", "prev diagnostic"),
            }),
            group('g', "+git", &.{
                cmd('c', .@"git.commit", "commit"),
                cmd('d', .@"git.diff", "diff"),
                cmd('f', .@"git.diff_file", "diff file"),
                cmd('n', .@"git.jump_next_change", "next change"),
                cmd('p', .@"git.jump_prev_change", "prev change"),
                cmd('D', .@"git.diff", "diff worktree"),
                cmd('A', .@"git.diff_all", "diff all vs HEAD (multi-file)"),
                cmd('b', .@"git.blame_toggle", "blame toggle"),
                cmd('l', .@"git.graph", "commit graph"),
                cmd('i', .@"git.rebase_interactive_onto", "interactive rebase onto…"),
                cmd('e', .@"git.explain_branch", "explain branch changes (ai)"),
                cmd('r', .@"git.push_start_pr", "push + start a PR"),
                cmd('s', .@"git.status_pane", "status / staging"),
                cmd('t', .@"git.status_pane", "git status"),
                cmd('m', .@"git.ai_commit", "ai (Claude) commit message"),
                cmd('M', .@"git.ai_recompose", "ai rewrite HEAD msg"),
                cmd('x', .@"git.codex_commit", "codex commit message"),
                cmd('o', .@"git.checkout", "checkout branch"),
                cmd('w', .@"git.worktrees", "worktrees → shell"),
                cmd('W', .@"git.worktree_open_tab", "worktree → its own tab"),
                cmd('S', .@"git.stash", "stash (with optional msg)"),
                cmd('P', .@"git.stash_pop", "stash pop"),
            }),
            // `a M` (mixr) is cut with the audio transport (docs/PARITY.md, Cuts).
            group('a', "+ai/term", &.{
                cmd('a', .@"ai.ask", "ask claude…"),
                cmd('b', .@"ai.toggle_backend", "toggle backend (cli ↔ api)"),
                cmd('d', .@"ai.dashboard", "agents dashboard"),
                cmd('e', .@"ai.explain", "explain selection"),
                cmd('f', .@"ai.fix", "fix bugs"),
                cmd('r', .@"ai.refactor", "refactor"),
                cmd('w', .@"ai.write_tests", "write tests"),
                cmd('m', .@"ai.session_view", "mirror session"),
                cmd('t', .@"term.shell", "shell"),
                cmd('c', .@"ai.claude_code", "claude code"),
                cmd('n', .@"ai.claude_code_new", "new claude session"),
                cmd('C', .@"ai.chat", "claude chat (context)"),
                cmd('x', .@"ai.codex", "codex"),
                cmd('X', .@"ai.codex_new", "new codex session"),
            }),
            group('t', "+toggle", &.{
                cmd('e', .@"view.toggle_tree", "explorer"),
                cmd('r', .@"view.toggle_right_panel", "right panel"),
                cmd(']', .@"view.right_panel_next_tab", "right panel: next"),
                cmd('[', .@"view.right_panel_prev_tab", "right panel: prev"),
                cmd('x', .@"view.right_panel_close_tab", "right panel: close tab"),
                cmd('k', .@"editor.toggle_keymap", "vim ⇄ standard"),
                cmd('t', .@"theme.pick", "theme…"),
                cmd('h', .@"view.toggle_hidden", "hidden files (focused)"),
                cmd('H', .@"view.toggle_hidden_all", "hidden files (all)"),
                cmd('w', .@"view.toggle_wrap", "wrap"),
                cmd('n', .@"view.toggle_line_numbers", "line numbers"),
                cmd('f', .@"view.fullscreen", "full screen (Esc Esc leaves)"),
                cmd('z', .@"view.toggle_zoom", "zoom this pane / restore"),
                cmd('0', .@"view.reset_layout", "reset view to default"),
            }),
            group('h', "+http", &.{
                cmd('s', .@"http.send", "send request"),
                cmd('r', .@"http.find_request", "find request…"),
                cmd('y', .@"http.copy_curl", "copy as curl"),
                cmd('d', .@"http.ai_debug", "ask Claude (debug)"),
                cmd(']', .@"http.next_block", "next ### block"),
                cmd('[', .@"http.prev_block", "previous ### block"),
            }),
            group('T', "+test", &.{
                cmd('a', .@"test.run_all", "run all"),
                cmd('f', .@"test.run_file", "run this file"),
                cmd('t', .@"test.run_at_cursor", "run test at cursor"),
                cmd('l', .@"test.rerun_failed", "re-run last-failed"),
                cmd('h', .@"test.heal", "heal failing test (Claude)"),
                cmd('w', .@"flaky.show", "flaky/wobbly dashboard"),
            }),
            // `L c r` (cargo run) is not an id in this build — `cargo.*` runs
            // the checks; `go.run` / `npm.run` cover the run verbs.
            group('L', "+lang/run", &.{
                group('c', "+cargo", &.{
                    cmd('t', .@"cargo.test", "cargo test"),
                    cmd('b', .@"cargo.build", "cargo build"),
                    cmd('c', .@"cargo.check", "cargo check"),
                    cmd('l', .@"cargo.clippy", "cargo clippy"),
                    cmd('f', .@"cargo.fmt", "cargo fmt"),
                }),
                group('n', "+npm", &.{
                    cmd('t', .@"npm.test", "npm test"),
                    cmd('b', .@"npm.build", "npm run build"),
                    cmd('r', .@"npm.run", "npm run dev"),
                    cmd('s', .@"npm.start", "npm start"),
                    cmd('i', .@"npm.install", "npm install"),
                    cmd('l', .@"npm.lint", "npm run lint"),
                    cmd('x', .@"npm.run_script", "run an npm script (prompt)"),
                }),
                group('p', "+pytest", &.{
                    cmd('t', .@"pytest.run", "pytest"),
                    cmd('l', .@"pytest.failed", "pytest --lf"),
                }),
                group('g', "+go", &.{
                    cmd('t', .@"go.test", "go test ./..."),
                    cmd('b', .@"go.build", "go build"),
                    cmd('r', .@"go.run", "go run ."),
                    cmd('v', .@"go.vet", "go vet ./..."),
                    cmd('p', .@"go.run_path", "go run <path> (prompt)"),
                }),
            }),
            // Rust's `+pr` leaves name `pr.picker` / `pr.refresh`, commands
            // that no longer exist in Rust either (the SCM split): the rows
            // paint, the press explains.
            group('P', "+pr", &.{
                dead('p', "pr.picker", "PRs: cross-host picker (Enter URL / Tab pipeline)"),
                dead('r', "pr.refresh", "PRs: refresh cross-host cache (background)"),
            }),
            // `i p` (`integrations.icon_picker`) waits on the icon-rail track.
            group('i', "+integrations", &.{
                cmd('d', .@"integrations.show_details", "detail pane (description / buttons / links)"),
                cmd('h', .@"tools.htop", "htop — interactive process viewer"),
                cmd('I', .@"tools.iftop", "iftop — interactive bandwidth monitor"),
                cmd('r', .@"tools.btop", "btop — resource monitor"),
                cmd('E', .@"integrations.toggle_enabled", "enable/disable a chip"),
            }),
            group('I', "+insert", &.{
                cmd('s', .@"snippet.pick", "snippet…"),
                cmd('x', .@"snippet.expand", "expand snippet at cursor"),
            }),
            group('H', "+harpoon", &.{
                cmd('a', .@"harpoon.add", "pin active file"),
                cmd('m', .@"harpoon.menu", "menu / picker"),
            }),
            cmd('1', .@"harpoon.goto_1", "harpoon 1"),
            cmd('2', .@"harpoon.goto_2", "harpoon 2"),
            cmd('3', .@"harpoon.goto_3", "harpoon 3"),
            cmd('4', .@"harpoon.goto_4", "harpoon 4"),
            cmd('5', .@"harpoon.goto_5", "harpoon 5"),
            cmd('6', .@"harpoon.goto_6", "harpoon 6"),
            cmd('7', .@"harpoon.goto_7", "harpoon 7"),
            cmd('8', .@"harpoon.goto_8", "harpoon 8"),
            cmd('9', .@"harpoon.goto_9", "harpoon 9"),
            cmd('?', .@"view.cheatsheet", "cheatsheet (all chords)"),
            cmd('B', .@"browser.open", "open browser (Chrome/CDP)"),
            cmd('m', .@"markdown.preview", "markdown preview"),
            cmd('p', .palette, "command palette"),
            cmd('o', .@"task.run", "run task…"),
        },
    },
};

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
    try std.testing.expect(continuations(std.testing.allocator, "s", true).len == 14);
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
    try std.testing.expectEqual(continuations(arena_state.allocator(), "", true).len - 2, std_root.len);
}

test "leader tree: the NvChad groups h T L P i I H, the digits, the root leaves ? B m p o, tr, iE and the t leaves" {
    const t = std.testing;
    for ([_][]const u8{ "h", "T", "L", "i", "I", "H" }) |g| try t.expect(lookup(g).?.* == .group);
    try t.expectEqualStrings("+cargo", lookup("Lc").?.label());
    try t.expectEqual(CommandId.@"cargo.test", lookup("Lct").?.cmd.id);
    try t.expectEqual(CommandId.@"go.run", lookup("Lgr").?.cmd.id);
    try t.expectEqual(CommandId.@"http.send", lookup("hs").?.cmd.id);
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
    try t.expectEqual(CommandId.@"view.toggle_zoom", lookup("tz").?.cmd.id);
    try t.expectEqual(CommandId.@"view.reset_layout", lookup("t0").?.cmd.id);
    // Rust's root leaves: e / q / w read as its popup does; x is not one.
    try t.expectEqual(CommandId.@"buffer.close", lookup("q").?.cmd.id);
    try t.expectEqualStrings("explorer", lookup("e").?.label());
    try t.expectEqualStrings("write/save", lookup("w").?.label());
    try t.expect(lookup("x") == null);
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
        try t.expect(seen >= 19);
    }
    // The count is a walk of the tree, not a literal: an iterative
    // sweep of every leaf beneath a node agrees with `chordCount`.
    for ([_][]const u8{ "", "f", "s", "g", "L", "Lc", "t", "a", "l", "d", "T", "h", "i", "H", "I", "P", "b", "c", "r" }) |path| {
        for ([_]bool{ true, false }) |vim| {
            const n = lookupIn(path, vim) orelse continue;
            try t.expectEqual(leavesUnder(n, vim), chordCount(n, vim));
        }
    }
    // The numbers the popup paints today, so a chord added or dropped
    // shows up here rather than silently on screen.
    try t.expectEqual(@as(u16, 7), chordCount(lookup("f").?, true));
    try t.expectEqual(@as(u16, 14), chordCount(lookup("s").?, true));
    try t.expectEqual(@as(u16, 5), chordCount(lookup("Lc").?, true));
    try t.expectEqual(@as(u16, 19), chordCount(lookup("L").?, true));
    try t.expectEqual(@as(u16, 15), chordCount(lookup("d").?, true));
    try t.expectEqual(@as(u16, 1), chordCount(lookup("Pp").?, true));
    // The root: the vim profile carries `+debug`'s fifteen and
    // `<leader>ra`'s one more than the standard one.
    try t.expectEqual(chordCount(&root, false) + 16, chordCount(&root, true));
}

/// An independent counter for the test: every leaf beneath `n`, found
/// with an explicit stack instead of `chordCount`'s recursion.
fn leavesUnder(n: *const Node, vim: bool) u16 {
    var stack: [256]*const Node = undefined;
    var n_stack: usize = 1;
    stack[0] = n;
    var leaves: u16 = 0;
    while (n_stack > 0) {
        n_stack -= 1;
        const node = stack[n_stack];
        switch (node.*) {
            .cmd, .dead, .dyn, .dyn_group => leaves += 1,
            .group => |g| for (g.kids) |*k| {
                if (!vim and k.vim_only) continue;
                stack[n_stack] = &k.node;
                n_stack += 1;
            },
        }
    }
    return leaves;
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
    var app = try app_mod.App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    _ = try app.openScratch();
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
    // names the key this profile actually opens the popup with. The app
    // above is the default (standard) profile, so that is `Ctrl+K`.
    try command.run(&app, .{ .static = .@"whichkey.leader" });
    try app.handle(.{ .key = app_mod.Key.char('\\') });
    try t.expect(app.overlay == .none);
    try t.expectEqualStrings("no leader mapping: Ctrl+K \\", app.lastToast().?);
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try command.run(&app, .{ .static = .@"whichkey.leader" });
    try app.handle(.{ .key = app_mod.Key.char('\\') });
    try t.expectEqualStrings("no leader mapping: <leader>\\", app.lastToast().?);
}

test "an installed integration's chord is a row under +integrations, and a built-in row still wins" {
    const t = std.testing;
    const app_mod = @import("../app.zig");
    var app = try app_mod.App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
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
