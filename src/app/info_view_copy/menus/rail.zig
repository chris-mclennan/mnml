//! Hover help for the rail's section menus (`context_menus.openRailMenu`):
//! a right press on a rail row opens a menu titled by the section —
//! `Show <section>` first (a family: the words are the section's and
//! say whether it is open now), the moves to the other column or the
//! bottom dock (a family: the words name the host), the section's own
//! verbs. The `Sidebar ▸` mode submenu every rail menu carries, and the
//! `Sidebar` menu the column's own ground and the sidebar edge grip
//! open, are the chrome's rows (`menus/chrome.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("../../../app.zig").App;
const copy = @import("../../info_view_copy.zig");
const menus = @import("../menus.zig");
const command = @import("../../../core/command.zig");
const rail_ui = @import("../../../ui/activity_bar.zig");
const Section = rail_ui.Section;
const activity_bar = @import("../../activity_bar.zig");
const side = @import("../../side.zig");
const Row = menus.Row;
const Entry = copy.Entry;
const Key = copy.Key;
const ask = copy.ask_link;

pub const rows = [_]Row{
    // ── Explorer ──
    .{ .label = "Reveal active file", .entry = .{
        .title = "Reveal active file",
        .body = "Expands the tree down to the file in the active editor and puts the cursor on its row, opening the left column if it was hidden — the same thing `view.reveal_in_tree` does from the palette. With a terminal or a non-file pane active there is nothing to reveal and it toasts. The row's own menu then has the file verbs.",
        .links = &.{ .{ .command = .{ .id = .@"view.reveal_in_tree", .label = "Reveal it" } }, .{ .command = .{ .id = .@"picker.files", .label = "Fuzzy-open a file" } } },
    } },
    // ── Search ──
    .{ .label = "Refresh", .command = .@"search.refresh", .entry = .{
        .title = "Refresh the search",
        .body = "Runs the query on the SEARCH section's header again with its flags — `Aa`, `\\b`, `.*` — so hits in files changed since the last run appear and stale ones go; the query itself is untouched. The header's ⟳ chip is the same row. In a repo it runs `git grep` first, so an untracked scratch file never answers; outside one it uses `rg`, and falls back to an in-process walk when neither is installed.",
        .links = &.{ .{ .command = .{ .id = .@"search.refresh", .label = "Run it again" } }, .{ .command = .{ .id = .@"view.activity_search", .label = "Show the section" } } },
    } },
    .{ .label = "Open as pane", .entry = .{
        .title = "Open as pane",
        .body = "Runs the section's query as a grep PANE in the editor area — the older form of the search, one row per hit, *Replace in files…* a row of its own menu — keeping the section's flags; with an empty query it asks for one first. The pane and the section are two lists: a rerun in one does not refresh the other.",
        .links = &.{ .{ .command = .{ .id = .@"search.open_pane", .label = "Open the pane" } }, .{ .command = .{ .id = .@"find.grep_replace", .label = "Replace across files" } } },
    } },
    .{ .label = "Find in files…", .entry = .{
        .title = "Find in files…",
        .body = "Asks for a query and greps the workspace with `rg` — or, without it, mnml's own walk over a vim pattern — into a grep pane — one row per hit, Enter opening the file at that line — reached here from the section's menu. The SEARCH section above it is the live form: type there and the hits follow the query; *Open as pane* moves that query into a pane.",
        .keys = &.{.{ .command = .@"find.grep", .label = "Find in files" }},
        .links = &.{ .{ .command = .{ .id = .@"find.grep", .label = "Grep the workspace" } }, .{ .command = .{ .id = .@"find.live_grep", .label = "Live grep with a preview" } }, .{ .command = .{ .id = .@"view.activity_search", .label = "The SEARCH section" } } },
    } },
    // ── Source control ──
    .{ .label = "Open git graph", .entry = .{
        .title = "Open git graph",
        .body = "Enters git mode on the active repo and shows its commit graph — the DAG of the history, one row per commit with its branches and tags, Enter showing the commit's diff: the sidebar becomes the git palette and your layout is stashed, and another section's row puts it back. A workspace with no repo toasts.",
        .keys = &.{.{ .command = .@"git.graph", .label = "Commit graph" }},
        .links = &.{ .{ .command = .{ .id = .@"git.graph", .label = "Open the graph" } }, .{ .command = .{ .id = .@"git.status_pane", .label = "The status pane" } } },
    } },
    // ── Run and debug ──
    .{ .label = "Toggle breakpoint at cursor", .entry = .{
        .title = "Toggle breakpoint at cursor",
        .body = "Sets a breakpoint on the active editor's cursor line — a ● in the gutter — or removes the one there, from the section's menu instead of the gutter; a running session takes the change at once. The DEBUG column's breakpoints list shows every one, and the gutter's own right-click edits a condition or a hit count. With a terminal active there is no line and it toasts.",
        .keys = &.{.{ .command = .@"dap.toggle_breakpoint", .label = "Toggle breakpoint" }},
        .links = &.{ .{ .command = .{ .id = .@"dap.toggle_breakpoint", .label = "Toggle it" } }, .{ .command = .{ .id = .@"dap.toggle_breakpoint_conditional", .label = "With a condition" } }, .{ .command = .{ .id = .@"dap.list_breakpoints", .label = "List them all" } } },
    } },
    .{ .label = "Debug console", .entry = .{
        .title = "Debug console",
        .body = "Opens the debug console as a pane beside the active one — the REPL where an expression typed at the prompt is evaluated in the paused frame and the adapter's output scrolls. Without a session the console opens but every expression answers that nothing is running; *Start debugging* first.",
        .keys = &.{.{ .command = .@"dap.repl", .label = "Debug console" }},
        .links = &.{ .{ .command = .{ .id = .@"dap.repl", .label = "Focus the console" } }, .{ .command = .{ .id = .@"dap.run", .label = "Start debugging" } }, ask },
    } },
    // ── Integrations ──
    .{ .label = "Refresh integrations", .entry = .{
        .title = "Refresh integrations",
        .body = "Rescans the manifests in the workspace's `.mnml/integrations/` and the home `integrations/` folder, and looks for each one's binary again, so an integration installed or edited on disk since launch appears in the section without a restart; the rail's pins and the top bar's chips are rebuilt from the result. The workspace folder is skipped until the workspace is trusted, so a tool installed there stays out of the list until you answer the trust prompt.",
        .links = &.{ .{ .command = .{ .id = .@"integrations.refresh", .label = "Rescan now" } }, copy.docsSection("Launchers and integration manifests"), copy.docsSection("Workspace trust") },
    } },
    .{ .label = "Refresh binary cache", .entry = .{
        .title = "Refresh binary cache",
        .body = "Runs the same rescan as *Refresh integrations* — the manifests are re-read and every binary looked for again on PATH and in the data root's `bin/` — so a tool installed since launch stops showing as missing; the two rows are one command under two names. A row still marked missing afterwards names the binary it looked for.",
        .links = &.{ .{ .command = .{ .id = .@"integrations.refresh_binary_cache", .label = "Look again" } }, .{ .command = .{ .id = .@"integrations.refresh", .label = "Rescan the manifests" } }, ask },
    } },
    // ── Sessions ──
    .{ .label = "+ New Claude Code session", .entry = .{
        .title = "+ New Claude Code session",
        .body = "Starts another Claude Code session — the `claude` CLI in a terminal pane — and shows the SESSIONS section with its new card: under the default `ui.ai_layout_mode = grid` the first two split to the right of the active leaf and later ones fill a grid that grows, a new page every eight; under `tabs` they stack as tabs in one leaf. Each session has its own card, rail colour and transcript. Claude routed off in `ai.routing` refuses with a toast.",
        .links = &.{ .{ .command = .{ .id = .@"ai.claude_code_new", .label = "Start one" } }, .{ .command = .{ .id = .@"ai.new_session_worktree", .label = "In a worktree instead" } }, .{ .settings = .{ .row = copy.settingsRow("ai.routing.claude.backend"), .label = "Claude routing in Settings" } } },
    } },
    .{ .label = "+ New session in a worktree…", .entry = .{
        .title = "+ New session in a worktree…",
        .body = "Asks for a branch name, makes a git worktree for it and starts a Claude Code session there, so the agent's edits land on a branch and checkout of their own while yours stay put; the card carries the branch. Closing the session leaves the worktree for you to merge or remove. Needs a git repo, and Claude routed on.",
        .links = &.{ .{ .command = .{ .id = .@"ai.new_session_worktree", .label = "Start one" } }, .{ .command = .{ .id = .@"git.worktrees", .label = "The worktrees list" } }, copy.docsSection("Session worktrees") },
    } },
    .{ .label = "+ New Codex session", .entry = .{
        .title = "+ New Codex session",
        .body = "Starts another Codex session — the `codex` CLI in a terminal pane — beside the active pane and shows the SESSIONS section with its card; under `ui.ai_layout_mode = tabs` it stacks as a tab. Codex has no API route in this build, so the CLI must be on PATH, and Codex routed off in `ai.routing` refuses with a toast.",
        .links = &.{ .{ .command = .{ .id = .@"ai.codex_new", .label = "Start one" } }, .{ .settings = .{ .row = copy.settingsRow("ai.routing.codex.backend"), .label = "Codex routing in Settings" } } },
    } },
    .{ .label = "+ New cloud run…", .entry = .{
        .title = "+ New cloud run…",
        .body = "Asks for a Jira ticket key (or a free prompt) and fires a cloud agent run for it on ECS — a Claude session on a machine that is not this one — then lists it under the section's CLOUD AGENTS rows, where its state and log can be followed. It needs `cloud_agents.runs_table` and a region (or `MNML_CLOUD_AGENTS_REGION`); without them the row toasts what is missing.",
        .links = &.{ .{ .command = .{ .id = .@"cloud_agents.new_run", .label = "Fire a run" } }, .{ .command = .{ .id = .@"view.activity_sessions", .label = "The sessions section" } }, ask },
    } },
    .{ .label = "Open as a table", .entry = .{
        .title = "Open as a table",
        .body = "Opens every session on this machine — this workspace's and every other's — as a table pane grouped by workspace, one row per session with its state, tokens, cost and age, the summary under the list adding the model, branch and last messages for the row under the cursor; Enter focuses one, and the pane follows sessions as they come and go. Sessions that ended over a day ago stay hidden until the `ended:` chip shows them.",
        .links = &.{ .{ .command = .{ .id = .@"sessions.table", .label = "Open the table" } }, .{ .command = .{ .id = .@"view.activity_sessions", .label = "The sessions section" } } },
    } },
    // ── HTTP ──
    .{ .label = "+ New request", .entry = .{
        .title = "+ New request",
        .body = "Opens a blank Request pane — method, URL, headers, body — as a tab beside the active pane, Postman-style scratch rather than a file; Ctrl+Enter sends and the response lands in the same pane. *Save request* in its menu writes it as a `.http` file into the collection root, where this section lists it.",
        .links = &.{ .{ .command = .{ .id = .@"http.new", .label = "New request" } }, .{ .command = .{ .id = .@"http.paste_curl", .label = "From a curl command instead" } }, .{ .settings = .{ .row = copy.settingsRow("http.collection_root"), .label = "Collection root" } } },
    } },
    // ── Notes ──
    .{ .label = "+ New note", .entry = .{
        .title = "+ New note",
        .body = "Asks for a name — seeded `note-N.md`, the first number free — then writes that markdown file into the workspace's `.mnml/notes/` and opens it in an editor; the NOTES section lists it first under the newest-first sort. The folder is the workspace's, so the note travels with the checkout — and lands in git unless `.mnml/` is ignored there.",
        .links = &.{ .{ .command = .{ .id = .@"notes.new", .label = "New note" } }, .{ .command = .{ .id = .@"view.activity_notes", .label = "The notes section" } } },
    } },
    // ── TODOs ──
    .{ .label = "Rescan", .entry = .{
        .title = "Rescan the TODOs",
        .body = "Walks the workspace again for TODO / FIXME / XXX / HACK / REVIEW markers and rebuilds the section's list now, rather than waiting for the throttled rescan that follows a file change. A large tree takes a moment; the header's ⟳ chip is the same row, and the sort chip orders what it finds.",
        .links = &.{ .{ .command = .{ .id = .@"todos.refresh", .label = "Rescan now" } }, .{ .command = .{ .id = .@"view.activity_todos", .label = "The TODOs section" } }, .{ .settings = .{ .row = copy.settingsRow("ui.todos_sort"), .label = "TODO sort in Settings" } } },
    } },
    // ── Scripts ──
    .{ .label = "Reload init.lua", .entry = .{
        .title = "Reload init.lua",
        .body = "Drops every command, section, hook, pane and statusline segment the scripts registered and runs the home `init.lua` again from the top — and the workspace's, once the workspace is trusted — so an edit to a script lands without a restart. A script that errors on load shows the error in the SCRIPTS section; a script section you were in is rebuilt, so its cursor moves.",
        .links = &.{ .{ .command = .{ .id = .@"script.reload", .label = "Reload now" } }, .{ .command = .{ .id = .@"script.doctor", .label = "The script doctor" } }, .{ .command = .{ .id = .@"view.activity_scripts", .label = "The scripts section" } } },
    } },
    .{ .label = "New workspace init.lua", .entry = .{
        .title = "New workspace init.lua",
        .body = "Creates `.mnml/init.lua` in the workspace from the commented template — every hook and API call shown, commented out — and opens it in an editor; a file that exists already is opened as it is. Save it and *Reload init.lua* runs it — in an untrusted workspace not until you answer the trust prompt, since it is exec-bearing. The file is the workspace's, so it lands in git unless `.mnml/` is ignored there.",
        .links = &.{ .{ .command = .{ .id = .@"script.new_init", .label = "Create and open it" } }, .{ .command = .{ .id = .@"script.reload", .label = "Reload the scripts" } }, copy.docsSection("Workspace trust") },
    } },
    // ── a script's own section ──
    .{ .label = "Refresh", .kind = .script_list_refresh, .entry = .{
        .title = "Refresh the section",
        .body = "Asks the script that owns this section for its rows again — the same call its header's ⟳ chip makes — so a list the script fills from a file or a command catches up with it. What the rows say is the script's to decide; a script that errors on the call keeps the rows it has, with the error in the SCRIPTS section.",
        .links = &.{ .{ .command = .{ .id = .@"script.reload", .label = "Reload every script" } }, .{ .command = .{ .id = .@"view.activity_scripts", .label = "The scripts section" } } },
    } },
};

/// The section whose menu carries `title` — a rail menu is titled by
/// the section's label. (The diagnostics chip's menu shares the word
/// `Diagnostics`; the families below only fire on a `Show <title>` row
/// or a move row, which that menu does not have.)
pub fn sectionOf(title: []const u8) ?Section {
    inline for (comptime std.enums.values(Section)) |s| if (std.mem.eql(u8, s.meta().label, title)) return s;
    return null;
}

fn hostName(s: side.Side) []const u8 {
    return switch (s) {
        .left => "the left column",
        .right => "the right column",
        .bottom => "the bottom dock",
    };
}

/// The section's own command as a shortcut row — only where a profile
/// binds one (the lint refuses a key on an unbound command).
fn showKeys(comptime s: Section) []const Key {
    const id = activity_bar.commandOf(s) orelse return &.{};
    const keys = command.spec(id).keys;
    if (keys.vim.len + keys.standard.len + keys.both.len == 0) return &.{};
    return &.{.{ .command = id, .label = "Show " ++ s.meta().label }};
}

fn showLinks(comptime s: Section) []const copy.Link {
    return if (activity_bar.commandOf(s)) |id| &.{ .{ .command = .{ .id = id, .label = "Show " ++ s.meta().label } }, .{ .settings = .{ .row = copy.settingsRow("ui.sidebar"), .label = "Sidebar mode in Settings" } } } else &.{.{ .command = .{ .id = .@"view.activity_scripts", .label = "The scripts section" } }};
}

/// `Show <section>` — the menu's first row, the rail row's own click:
/// the words say what the section is and whether it is the one open.
pub fn show(app: *App, arena: Allocator, s: Section) Allocator.Error!Entry {
    const label = s.meta().label;
    const host = hostName(side.sideOf(app, s));
    const open = side.isShown(app, s);
    const body = switch (s) {
        .git => if (open)
            try std.fmt.allocPrint(arena, "Git mode is on already — the sidebar is the git palette and the editor area the commit graph — so this row leaves it as it is, and so does the rail row's own click; any OTHER section's row is what leaves git mode and puts the layout back the way it was.", .{})
        else
            try std.fmt.allocPrint(arena, "Enters git mode, as a left click on the rail row does: the sidebar becomes the git palette — status, commits, branches, worktrees, stashes for the active repo — and the editor area shows the commit graph. Any other section's click leaves it and puts the layout back; the rows under this one are the git verbs the chip and the palette also have.", .{}),
        .script => if (open)
            try std.fmt.allocPrint(arena, "This script's section is the one open in {s} now, so this row leaves it as it is — the same as its rail row's left click, which shows a section rather than toggling it. A reload of the script rebuilds the section, so a row you were on may move.", .{host})
        else
            try std.fmt.allocPrint(arena, "Opens the section a Lua script registered with `mnml.section{{}}` in {s}, replacing what that host shows, as a left click on its rail row does; the rows, filter and sort are the script's to fill. A reload of the script rebuilds the section.", .{host}),
        else => if (open)
            try std.fmt.allocPrint(arena, "The {s} section is the one open in {s} now, so this row leaves it as it is — the same as the rail row's left click, which shows a section rather than toggling it. The move rows change which host it opens in; what sits between them and `Sidebar` is the section's own verbs, when it has any.", .{ label, host })
        else
            try std.fmt.allocPrint(arena, "Opens the {s} section in {s}, replacing whatever that host shows, the way a left click on its rail row does; the host opens if it was hidden, and the rail marks the section. The move rows change which host it opens in; what sits between them and `Sidebar` is the section's own verbs, when it has any.", .{ label, host }),
    };
    return switch (s) {
        inline else => |tag| .{
            .title = try std.fmt.allocPrint(arena, "Show {s}", .{label}),
            .body = body,
            .keys = comptime showKeys(tag),
            .links = comptime showLinks(tag),
        },
    };
}

fn moveLinks(comptime dest: side.Side) []const copy.Link {
    return switch (dest) {
        .left => &.{ .{ .command = .{ .id = .@"view.toggle_tree", .label = "Toggle the left column" } }, .{ .settings = .{ .row = copy.settingsRow("ui.tree_width"), .label = "Left column width" } } },
        .right => &.{ .{ .command = .{ .id = .@"view.toggle_right_panel", .label = "Toggle the right column" } }, .{ .settings = .{ .row = copy.settingsRow("ui.right_panel_width"), .label = "Right column width" } } },
        .bottom => &.{ .{ .command = .{ .id = .@"view.toggle_bottom_panel", .label = "Toggle the bottom dock" } }, .{ .settings = .{ .row = copy.settingsRow("ui.bottom_panel_height"), .label = "Bottom dock height" } } },
    };
}

/// `Move to <host>` — one row per host the section is not in now.
pub fn move(app: *App, arena: Allocator, s: Section, dest: side.Side) Allocator.Error!Entry {
    const label = s.meta().label;
    const here = hostName(side.sideOf(app, s));
    const there = hostName(dest);
    const note: []const u8 = switch (dest) {
        .bottom => " The dock is a strip under the editor, `ui.bottom_panel_height` rows tall, that every section moved down shares as tabs.",
        .right => " The right column also hosts the outline and the problems list, so the section becomes a tab beside them.",
        .left => " The left column is the tree's; the section takes the column and the tree comes back when Explorer is shown.",
    };
    return switch (dest) {
        inline else => |d| .{
            .title = try std.fmt.allocPrint(arena, "Move {s} to {s}", .{ label, there }),
            .body = try std.fmt.allocPrint(arena, "Moves the {s} section from {s} to {s}: one that is open re-opens there, keeping the keys if it had them, and one that is closed simply opens there next time; its rail row shows it there from now on, and the host it left shows what it showed before. The same menu on the new host has the row back.{s}", .{ label, here, there, note }),
            .links = comptime moveLinks(d),
        },
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "rail: sectionOf reads a menu's title; Show and Move say the section, the host and the state" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const a = app.frame.allocator();
    try t.expectEqual(Section.git, sectionOf("Source control").?);
    try t.expectEqual(Section.script, sectionOf("Script section").?);
    try t.expect(sectionOf("Editor") == null);
    // The explorer is open on a fresh app; notes is not.
    const shown = try show(&app, a, .explorer);
    try t.expectEqualStrings("Show Explorer", shown.title);
    try t.expect(std.mem.indexOf(u8, shown.body, "the one open in the left column now") != null);
    const notes = try show(&app, a, .notes);
    try t.expect(std.mem.indexOf(u8, notes.body, "Opens the Notes section") != null);
    // `view.activity_notes` is bound in neither profile, so the row has
    // no shortcut line; its first link is the section's command.
    try t.expectEqual(@as(usize, 0), notes.keys.len);
    try t.expectEqual(command.CommandId.@"view.activity_notes", notes.links[0].command.id);
    const git = try show(&app, a, .git);
    try t.expect(std.mem.indexOf(u8, git.body, "git mode") != null);
    const moved = try move(&app, a, .todos, .bottom);
    try t.expectEqualStrings("Move TODOs to the bottom dock", moved.title);
    try t.expect(std.mem.indexOf(u8, moved.body, "from the left column to the bottom dock") != null);
    try t.expect(moved.links[0] == .command);
    // No two sections' Show rows read the same.
    try t.expect(!std.mem.eql(u8, shown.body, notes.body));
}

test "rail: every row of every section's menu resolves to a curated entry" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const cm = @import("../../context_menus.zig");
    inline for (comptime std.enums.values(Section)) |s| {
        app.overlay.deinit(app.gpa);
        app.overlay = .none;
        try cm.openRailMenu(&app, s, 5, 5);
        if (try menus.firstUncovered(&app, app.frame.allocator())) |label| {
            std.debug.print("rail: no entry for `{s}` in menu `{s}`\n", .{ label, app.overlay.menu.title });
            return error.Uncovered;
        }
    }
    // The two `Refresh` rows tell each other apart by what they run.
    try t.expectEqualStrings("Refresh the search", menus.lookupItem("Search", null, "Refresh", .{ .command = .@"search.refresh" }).?.title);
    try t.expect(menus.lookupItem("Search", null, "Refresh", .{ .command = .@"git.refresh" }) == null or !std.mem.eql(u8, menus.lookupItem("Search", null, "Refresh", .{ .command = .@"git.refresh" }).?.title, "Refresh the search"));
    try t.expectEqualStrings("Find in files…", menus.lookup("Search", null, "Find in files…").?.title);
}

/// `Hide from activity bar` — the section's row leaves the bar; the
/// section and its command stay.
pub fn hide(app: *App, arena: Allocator, s: Section) Allocator.Error!Entry {
    _ = app;
    const label = s.meta().label;
    return .{
        .title = try std.fmt.allocPrint(arena, "Hide {s} from the activity bar", .{label}),
        .body = try std.fmt.allocPrint(arena, "Takes the {s} row off the activity bar — `ui.rail.hidden` in the home config holds the list, so it stays off in every workspace — without closing the section if it is open now; its command still runs from the palette and any chord it has. *Activity bar: show every hidden section again* brings every hidden row back at once, and *Show on dock instead* is the other way to clear a row: the section goes onto the launcher dock, where it can be moved back.", .{label}),
        .links = &.{ .{ .command = .{ .id = .@"view.rail_show_sections", .label = "Show the hidden sections again" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.dock.mode"), .label = "Launcher dock in Settings" } } },
    };
}

/// `Show on dock instead` — the row moves from the bar onto the dock,
/// both halves of the move written to the home config.
pub fn toDock(app: *App, arena: Allocator, s: Section) Allocator.Error!Entry {
    _ = app;
    const label = s.meta().label;
    return .{
        .title = try std.fmt.allocPrint(arena, "Show {s} on the dock instead", .{label}),
        .body = try std.fmt.allocPrint(arena, "Moves the {s} section from the activity bar onto the launcher dock: its row is hidden on the bar (`ui.rail.hidden`) and its command pinned onto the strip (`ui.dock.pins`), where the dock draws it as a pinned panel wearing the section's glyph — a click opens the section the way the rail row did. Right-click the dock item for *Move back to activity bar*, which undoes both halves. With the dock hidden (`ui.dock.mode = hidden`) the pin waits on the strip until the dock shows.", .{label}),
        .links = &.{ .{ .settings = .{ .row = comptime copy.settingsRow("ui.dock.mode"), .label = "Launcher dock in Settings" } }, .{ .command = .{ .id = .@"view.rail_show_sections", .label = "Show the hidden sections again" } } },
    };
}

/// `Move back to activity bar` — a pinned panel's row on the dock: the
/// reverse of *Show on dock instead*, in one row.
pub fn fromDock(app: *App, arena: Allocator, s: Section) Allocator.Error!Entry {
    _ = app;
    const label = s.meta().label;
    return .{
        .title = try std.fmt.allocPrint(arena, "Move {s} back to the activity bar", .{label}),
        .body = try std.fmt.allocPrint(arena, "Puts the {s} section back on the activity bar: its row is unhidden (`ui.rail.hidden`) and the pin taken off the dock (`ui.dock.pins`) — *Show on dock instead* undone in one row. The section itself is untouched; open, it stays open, and its rail row marks it again.", .{label}),
        .links = &.{ .{ .command = .{ .id = .@"view.rail_show_sections", .label = "Show every hidden section" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.dock.mode"), .label = "Launcher dock in Settings" } } },
    };
}
