//! Hover help for the sections' own parts: a list panel's header chips,
//! rows, kebabs and filter, the SEARCH flags, the HTTP panel's chips
//! and links, the git palette's repo pill, the FONTS update chip, the
//! AI grid's open slot, the welcome rows, a pane-hosted list's items,
//! a link, and the info view itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../../app.zig");
const App = app_mod.App;
const copy = @import("../info_view_copy.zig");
const Entry = copy.Entry;
const hit = @import("../../ui/hit.zig");
const PanelId = hit.PanelId;
const http_panel = @import("../../ui/http_panel.zig");
const search_view = @import("../../ui/search_section_view.zig");
const git_palette_ui = @import("../../ui/git_palette.zig");
const sessions = @import("../../sessions.zig");
const git_palette = @import("../git_palette.zig");
const line_blame = @import("../line_blame.zig");
const session_changes = @import("../session_changes.zig");
const status_view = @import("../../ui/git_status_view.zig");

const ask = copy.ask_link;

fn panelName(p: PanelId) []const u8 {
    return switch (p) {
        .todos => "TODOS",
        .notes => "NOTES",
        .findings => "FINDINGS",
        .sessions => "SESSIONS",
        .git => "GIT",
        .diagnostics => "DIAGNOSTICS",
        .http => "HTTP",
        .outline => "OUTLINE",
        .debug => "DEBUG",
        .integrations => "INTEGRATIONS",
        .scripts => "SCRIPTS",
        .search => "SEARCH",
        .script => "the script's section",
        .jobs => "JOBS",
    };
}

// ─── list panel chrome ──────────────────────────────────────────────────

pub fn chip(panel: PanelId, kind: hit.ChipKind) Entry {
    return switch (kind) {
        .sort => if (panel == .sessions) .{
            .title = "SESSIONS: sort",
            .body = "Click steps through State, Manual and Waiting. State groups by what a session is doing — the ones that need you first, then running, then the rest; Manual keeps the order you moved the cards into; Waiting lifts every session blocked on a prompt (the raised-hand mark) over your manual order and leaves the rest where you put them. Pinned sessions stay at the top on every axis. Right-click picks a mode directly.",
            .links = &.{ .{ .command = .{ .id = .@"sessions.sort_auto", .label = "State order" } }, .{ .command = .{ .id = .@"sessions.sort_manual", .label = "Manual order" } }, .{ .command = .{ .id = .@"sessions.sort_waiting", .label = "Waiting first" } } },
        } else .{
            .title = "sort: chip",
            .body = "Click cycles the row order — newest first, oldest first, name A–Z, name Z–A; right-click picks one directly, each mode beside its reverse. The order is per panel and persisted, so notes sorted A–Z does not reorder findings. On a narrow column the chip shrinks to its icon; the menu is the same.",
            .links = &.{.{ .settings = .{ .row = comptime copy.settingsRow("ui.todos_sort"), .label = "TODOS sort in Settings" } }},
        },
        .refresh => .{
            .title = "↻ refresh",
            .body = "Rescans this section now. Right-click turns auto-refresh on or off for it — per section, persisted; on by default, with TODOS waiting half a second after the last file change so a burst of saves is one scan of the workspace. A section that never changes on its own (notes, findings) refreshes when its folder does.",
            .links = &.{.{ .command = .{ .id = .@"integrations.poll_now", .label = "Poll the integrations now" } }},
        },
        .new => if (panel == .integrations) .{
            .title = "+ source",
            .body = "Adds a private source to the Marketplace: a folder on this machine (`~/my-integrations`, a path relative to the workspace) or a GitHub monorepo as `owner/repo[:apps_dir]`. A folder must hold something to install — a `*.zon` manifest, or a folder with `build.zig` and `manifest.zon` — and says how many it found. The source is appended to `marketplace.sources` in your home `config.zon`, never the workspace's, and the tab lists it at once. Right-click has the tab's menu.",
            .links = &.{ .{ .command = .{ .id = .@"marketplace.add_source", .label = "Add a source" } }, .{ .command = .{ .id = .@"marketplace.refresh", .label = "Refresh the sources" } } },
        } else .{
            .title = "+ new",
            .body = "Creates an entry in this section: a todo is appended to TODO.md at the workspace root under an `## Inbox` heading; a note becomes a file in `.mnml/notes/`, a finding one in `.mnml/findings/` from a template; SESSIONS' `+` opens the New session menu — a local Claude Code session, one in a worktree, two, four or eight at once, or a cloud run. The section refreshes at once rather than waiting for the next scan.",
            .links = &.{ .{ .command = .{ .id = .@"notes.new", .label = "New note" } }, .{ .command = .{ .id = .@"ai.claude_code_new", .label = "New Claude session" } } },
        },
        .history => .{
            .title = "Ended sessions",
            .body = "Click shows or hides the sessions that have ended — they keep their card, greyed, with the transcript a click away, until cleared. Right-click offers show, hide and clear. A session killed from its card ends here too; `sessions.open_transcript` reads what it said.",
            .links = &.{ .{ .command = .{ .id = .@"sessions.toggle_ended", .label = "Show / hide the ended" } }, .{ .command = .{ .id = .@"sessions.clear_ended", .label = "Clear them" } } },
        },
    };
}

pub fn row(app: *App, arena: Allocator, r: hit.PanelRow) Allocator.Error!?Entry {
    // The SESSIONS card and the git palette row have rich tips of
    // their own; those are the entry's body.
    if (r.panel == .sessions) if (try sessions.hoverTip(app, arena, r.idx)) |tip| return fromTip(arena, tip, "A session's card: a click selects it, a second click or Enter opens its pane; the kebab has rename, pin, the colour, kill, the transcript, the worktree rows. Its Move rows reorder it under the Manual sort.", &.{ .{ .command = .@"sessions.open", .label = "Open the pane" }, .{ .command = .@"sessions.open_transcript", .label = "The transcript" }, .{ .command = .@"sessions.kill", .label = "Kill" } }, &.{ .{ .command = .{ .id = .@"sessions.open_transcript", .label = "Read the transcript" } }, ask });
    if (r.panel == .git) if (try git_palette.hoverTip(app, arena, r.idx)) |tip| return fromTip(arena, tip, "A git palette row: Enter acts on it — checkout a branch, open a commit, apply a stash; right-click is its menu with the rest.", &.{}, &.{ .{ .command = .{ .id = .@"git.status_pane", .label = "The status pane" } }, .{ .command = .{ .id = .@"git.checkout", .label = "Checkout" } }, ask });
    return switch (r.panel) {
        .jobs => try jobsRow(app, arena, r.idx),
        .todos => .{
            .title = try std.fmt.allocPrint(arena, "TODO row {d}", .{r.idx + 1}),
            .body = "A marker found in the code — TODO / FIXME / XXX / HACK / REVIEW — with its file and line. Enter or double-click jumps there; the kebab on the focused row hands it to a Claude or Codex session with the file and line filled in, or marks it done. Right-click has copy the path and ignore this file.",
            .keys = &.{.{ .chord = "Enter", .label = "Jump to the line" }},
            .links = &.{ .{ .command = .{ .id = .@"todos.fix_with_agent", .label = "Hand it to an agent" } }, .{ .command = .{ .id = .@"todos.open", .label = "Open the file" } }, ask },
        },
        .notes => .{
            .title = try std.fmt.allocPrint(arena, "Note {d}", .{r.idx + 1}),
            .body = "A markdown file in the workspace's `.mnml/notes/`. Enter or double-click opens it in an editor; the kebab has delete and copy the path. Notes travel with the checkout, not with mnml, so a note is as shared as the folder is.",
            .keys = &.{.{ .chord = "Enter", .label = "Open" }},
            .links = &.{ .{ .command = .{ .id = .@"notes.open", .label = "Open it" } }, .{ .command = .{ .id = .@"notes.new", .label = "New note" } } },
        },
        .findings => .{
            .title = try std.fmt.allocPrint(arena, "Finding {d}", .{r.idx + 1}),
            .body = "A report a tester or a review round left in the workspace's `.mnml/findings/` — severity, steps, the verdict. Enter or double-click opens it in an editor; the kebab resolves it (moves it out of the open list) or deletes it. Right-click has copy the path.",
            .keys = &.{.{ .chord = "Enter", .label = "Open" }},
            .links = &.{ .{ .command = .{ .id = .@"findings.open", .label = "Open it" } }, .{ .command = .{ .id = .@"findings.resolve", .label = "Resolve it" } }, ask },
        },
        .sessions => .{
            .title = try std.fmt.allocPrint(arena, "Session {d}", .{r.idx + 1}),
            .body = "A Claude Code or Codex session's card — its name, branch, cwd and what the pane is showing; a raised hand before the name means the session is stopped on a question for you; a `◆` in the column left of the card means it finished a turn or ended since you last looked at it (the `•` there instead means it is on screen now, and a `⇄` that the session is linked to mnml as its IDE). A click selects it and a second click or Enter opens its pane; the kebab has rename, pin, the colour, kill, the transcript, the worktree rows, and its Move rows reorder it under the Manual sort.",
            .keys = &.{ .{ .chord = "Enter", .label = "Open the pane" }, .{ .command = .@"sessions.next_waiting", .label = "Next ready for you" } },
            .links = &.{ .{ .command = .{ .id = .@"sessions.open_transcript", .label = "Read the transcript" } }, ask },
        },
        .git => .{
            .title = try std.fmt.allocPrint(arena, "Git row {d}", .{r.idx + 1}),
            .body = "A row of the git palette — a changed file, a branch, a worktree, a stash, a tag, under its section's header. Enter acts on it: opens the diff, checks out the branch, applies the stash; right-click is its menu with the rest. The repo pill at the top says which repo the rows belong to.",
            .keys = &.{ .{ .chord = "Enter", .label = "Act on the row" }, .{ .command = .@"git.commit", .label = "Commit" }, .{ .command = .@"git.status_pane", .label = "The status pane" } },
            .links = &.{ .{ .command = .{ .id = .@"git.status_pane", .label = "The status pane" } }, ask },
        },
        .diagnostics => .{
            .title = try std.fmt.allocPrint(arena, "Diagnostic {d}", .{r.idx + 1}),
            .body = "A problem the language server reported — its severity, message, file and line, worst first. Enter or double-click jumps to the line; the code action at that spot is the usual fix. Right-click filters by severity or copies the message. The list covers every open file.",
            .keys = &.{ .{ .chord = "Enter", .label = "Jump to it" }, .{ .command = .@"lsp.quick_fix", .label = "Quick fix" } },
            .links = &.{ .{ .command = .{ .id = .@"lsp.quick_fix", .label = "Quick fix at the cursor" } }, .{ .command = .{ .id = .@"lsp.code_action", .label = "Code actions" } }, ask },
        },
        .http => .{
            .title = try std.fmt.allocPrint(arena, "HTTP row {d}", .{r.idx + 1}),
            .body = "A row of the HTTP panel — a request file, a recent send, a captured browser request, an env, a chain, a mock, a cookie, a collection — under its section's header. Enter opens it as a request (a file) or replays it (a send); right-click is the row's menu. `/` filters the section it is in.",
            .keys = &.{.{ .chord = "Enter", .label = "Open / replay" }},
            .links = &.{ .{ .command = .{ .id = .@"http.new", .label = "New request" } }, .{ .command = .{ .id = .@"http.history", .label = "The full history" } } },
        },
        .outline => .{
            .title = try std.fmt.allocPrint(arena, "Symbol {d}", .{r.idx + 1}),
            .body = "A symbol of the active file from its language server — a function, a type, a heading — in document order, nested by scope. Enter or a click jumps to it; the row under the cursor's own symbol is followed as you move. Empty until a server has indexed the file.",
            .keys = &.{ .{ .chord = "Enter", .label = "Jump to it" }, .{ .command = .@"lsp.symbols", .label = "Symbol picker" } },
            .links = &.{ .{ .command = .{ .id = .@"lsp.symbols", .label = "Pick a symbol" } }, .{ .command = .{ .id = .@"lsp.references", .label = "Find references" } } },
        },
        .debug => .{
            .title = try std.fmt.allocPrint(arena, "Debug row {d}", .{r.idx + 1}),
            .body = "A row of the debug column — a variable, a watch, a frame of the call stack, a breakpoint — under its section's header. Enter expands or jumps; `e` edits a variable or a watch, `x` removes a watch or a breakpoint, Space toggles a breakpoint on or off. Right-click is the row's menu.",
            .links = &.{ .{ .command = .{ .id = .@"dap.add_watch", .label = "Add a watch" } }, .{ .command = .{ .id = .@"dap.continue", .label = "Continue" } }, ask },
        },
        .integrations => if (try @import("../integrations.zig").rowStaleText(app, arena, r.idx)) |why| if (try @import("../integrations.zig").rowNoRebuild(app, arena, r.idx)) |cannot| .{
            .title = try std.fmt.allocPrint(arena, "Integration {d} \u{b7} old SDK", .{r.idx + 1}),
            .body = try std.fmt.allocPrint(arena, "The `old SDK` chip: {s}. An integration draws through the SDK it was compiled against, so this one misses whatever the SDK has changed since \u{2014} and it cannot be rebuilt here: {s}. Reinstall it from the Marketplace.", .{ why, cannot }),
            .keys = &.{.{ .chord = "Enter", .label = "Open it" }},
            .links = &.{.{ .command = .{ .id = .@"integrations.show_marketplace", .label = "Open the Marketplace" } }},
        } else .{
            .title = try std.fmt.allocPrint(arena, "Integration {d} \u{b7} rebuild", .{r.idx + 1}),
            .body = try std.fmt.allocPrint(arena, "The `rebuild` chip: {s}. An integration draws through the SDK it was compiled against, so this one misses whatever the SDK has changed since. Right-click \u{2192} Rebuild builds it again from its folder and re-runs `--install`; `integrations.rebuild_stale` does every one.", .{why}),
            .keys = &.{.{ .chord = "Enter", .label = "Open it" }},
            .links = &.{ .{ .command = .{ .id = .@"integrations.rebuild_focused", .label = "Rebuild it" } }, .{ .command = .{ .id = .@"integrations.rebuild_stale", .label = "Rebuild every stale one" } } },
        } else if (app.integrations.tab != .installed) .{
            .title = try std.fmt.allocPrint(arena, "{s} entry {d}", .{ if (app.integrations.tab == .marketplace) "Marketplace" else "Dev", r.idx + 1 }),
            .body = "An integration this tab lists but that is not necessarily installed — its name, source and state. Enter or a second click opens its detail pane, where it is described and installed from; the Installed tab holds the ones already on this machine.",
            .keys = &.{.{ .chord = "Enter", .label = "Open the detail pane" }},
            .links = &.{.{ .command = .{ .id = .@"integrations.show_installed", .label = "The installed ones" } }},
        } else .{
            .title = try std.fmt.allocPrint(arena, "Integration {d}", .{r.idx + 1}),
            .body = "An installed integration — its chip, label and state. Enter opens it; right-click is its menu: details, disable or enable, show on or hide from the top bar (a new install starts off it), add to the activity bar, the manifest, copy the id, open as, update, rebuild, uninstall. A disabled row is dimmed.",
            .keys = &.{.{ .chord = "Enter", .label = "Open it" }},
            .links = &.{ .{ .command = .{ .id = .@"integrations.configure_picker", .label = "Configure it" } }, .{ .command = .{ .id = .@"integrations.show_manifest", .label = "Show the manifest" } } },
        },
        .scripts => .{
            .title = try std.fmt.allocPrint(arena, "Script row {d}", .{r.idx + 1}),
            .body = "Something a Lua script registered — a command, a section, a hook — with the file and line it came from, or an installed script package. Enter opens the source at that line; right-click is the row's menu — reload this script, enable or disable, remove. A failed load shows its error as the row's detail.",
            .keys = &.{.{ .chord = "Enter", .label = "Open the source" }},
            .links = &.{ .{ .command = .{ .id = .@"script.reload", .label = "Reload every script" } }, .{ .command = .{ .id = .@"script.doctor", .label = "Script doctor" } }, ask },
        },
        .search => .{
            .title = try std.fmt.allocPrint(arena, "Search hit {d}", .{r.idx + 1}),
            .body = "A hit of the workspace search — the file, or a line under it with the match highlighted. Enter jumps to the line (a file row folds its hits); right-click has open in a split, copy the path, copy the line. The flags on the header change the query's matching and rerun it.",
            .keys = &.{.{ .chord = "Enter", .label = "Jump to it" }},
            .links = &.{ .{ .command = .{ .id = .@"search.open_pane", .label = "Open as a pane" } }, .{ .command = .{ .id = .@"find.grep_replace", .label = "Replace across the hits" } } },
        },
        .script => .{
            .title = try std.fmt.allocPrint(arena, "Row {d} of the script's section", .{r.idx + 1}),
            .body = "A row a Lua script put in its section — what Enter and the kebab do are the script's own handlers. A reload of the script rebuilds the section. The Scripts section names the script and the line the section came from.",
            .keys = &.{.{ .chord = "Enter", .label = "The script's action" }},
            .links = &.{.{ .command = .{ .id = .@"view.activity_scripts", .label = "The scripts section" } }},
        },
    };
}

/// A row of the JOBS overlay: a section header, a job, or the Cancel
/// row under a running one.
fn jobsRow(app: *App, arena: Allocator, idx: u32) Allocator.Error!?Entry {
    const jobs = @import("../jobs.zig");
    const list = try jobs.buildRows(&app.jobs.reg, arena, app.now_ms, app.cfg.ui.ascii_icons);
    const kind: @import("../../ui/jobs_view.zig").Row.Kind = if (idx < list.len) list[idx].kind else .finished;
    const links: []const copy.Link = &.{ .{ .command = .{ .id = .@"jobs.show", .label = "The jobs list" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.jobs_chip"), .label = "Jobs chip in Settings" } } };
    return switch (kind) {
        .section => .{
            .title = "Jobs — a section",
            .body = "RUNNING lists what is going on now, oldest first, each with how long it has been at it; FINISHED the last fifty that ended, newest first, with how they ended and how long they took. The chip in the statusline counts the first and holds the latest failure of the second for ten seconds.",
            .links = links,
        },
        .cancel => .{
            .title = "Cancel this job",
            .body = "Stops the job on the row above through its own subsystem — the test run's worker, the send in flight, the search walk. Enter or a click runs it; the job moves to FINISHED as cancelled once the subsystem has stopped it. A job with no way to stop from here has no Cancel row.",
            .keys = &.{ .{ .chord = "Enter", .label = "Cancel it" }, .{ .chord = "c", .label = "Cancel the job under the cursor" } },
            .links = links,
        },
        .running, .finished => .{
            .title = if (idx < list.len) try std.fmt.allocPrint(arena, "{s} — {s}", .{ list[idx].what, list[idx].label }) else "A background job",
            .body = "One background job: what started it, what it is doing or how it ended, and how long it took. Enter or a click opens the pane it belongs to — the tests pane, the request, the browser, the session — or, for a job with no pane, says its words in a toast. `c` cancels a running one that can be stopped.",
            .keys = &.{ .{ .chord = "Enter", .label = "Open its pane" }, .{ .chord = "c", .label = "Cancel it" } },
            .links = links,
        },
    };
}

fn fromTip(arena: Allocator, tip: anytype, verbs: []const u8, keys: []const copy.Key, links: []const copy.Link) Allocator.Error!?Entry {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    if (tip.detail) |d| {
        try body.appendSlice(arena, d);
        if (d.len > 0 and d[d.len - 1] != '.') try body.append(arena, '.');
        try body.append(arena, ' ');
    }
    for (tip.lines) |l| if (l.len > 0) {
        try body.appendSlice(arena, l);
        if (l[l.len - 1] != '.') try body.append(arena, '.');
        try body.append(arena, ' ');
    };
    try body.appendSlice(arena, verbs);
    return .{ .title = tip.title, .body = body.items, .keys = keys, .links = links };
}

pub fn kebab(r: hit.PanelRow) Entry {
    return .{
        .title = switch (r.panel) {
            .todos => "TODO row actions",
            .sessions => "Session card actions",
            else => "Row actions",
        },
        .body = switch (r.panel) {
            .todos => "Shown on the focused row only — the hover-reveal idiom rather than a marker down every row. Click opens the row's menu: open; fix with an agent — Claude Code when the workspace has a `.claude/`, else whichever CLI is on PATH — with the file and line filled in; open in Claude Code or Codex; copy the path; mark done; ignore the file.",
            .sessions => "Shown on the focused card. Click opens its rows: rename, pin to the top, the accent colour (the card and the pane's rail share it), kill, open the transcript, and the worktree rows — open its tree, merge it, remove it. Right-click on the card is the same menu.",
            else => "Shown on the focused row only — the hover-reveal idiom rather than a marker down every row. Click opens the row's actions: open, copy the path, resolve or delete, whatever the section's rows do. Right-click on the row is the same menu.",
        },
        .keys = &.{ .{ .chord = "Enter", .label = "Open the row" }, .{ .chord = "Right-click", .label = "The same menu" } },
        .links = switch (r.panel) {
            .todos => &.{.{ .command = .{ .id = .@"todos.fix_with_agent", .label = "Hand it to an agent" } }},
            .sessions => &.{ .{ .command = .{ .id = .@"sessions.rename", .label = "Rename the session" } }, .{ .command = .{ .id = .@"sessions.open_transcript", .label = "The transcript" } } },
            else => &.{},
        },
    };
}

pub fn filter(p: PanelId) Entry {
    if (p == .search) return .{
        .title = "Search query",
        .body = "Type the text to search for across the workspace and press Enter to run it; ripgrep does the work, so a regex is fine when the `.*` flag is on. Esc clears the field. The hits group by file below; the three flags on the header — case, whole word, regex — rerun the query when toggled.",
        .keys = &.{ .{ .chord = "Enter", .label = "Run the search" }, .{ .chord = "Esc", .label = "Clear" } },
        .links = &.{ .{ .command = .{ .id = .@"search.refresh", .label = "Rerun" } }, .{ .command = .{ .id = .@"find.live_grep", .label = "Live grep instead" } } },
    };
    return .{
        .title = "Section filter",
        .body = "Type to narrow this section's rows to the ones that match — the file name, the marker text, the session's name; the count in the header follows. Esc clears it and hands the keys back to the rows. `/` focuses the field from the rows; the filter is per section and forgotten on restart.",
        .keys = &.{ .{ .chord = "/", .label = "Focus the filter" }, .{ .chord = "Esc", .label = "Clear" }, .{ .chord = "↑ / ↓", .label = "Walk the matches" } },
        .links = &.{.{ .command = .{ .id = .@"focus.cycle", .label = "Cycle focus" } }},
    };
}

pub fn searchChip(f: search_view.Flag) Entry {
    return switch (f) {
        .case_sensitive => .{
            .title = "Aa — case-sensitive",
            .body = "Click toggles whether the query's case must match — `foo` finds `Foo` with it off, only `foo` with it on — and reruns the search. Off is smart case: an all-lowercase query ignores case, and one with a capital letter matches case anyway. The flag is per search, not persisted.",
            .links = &.{ .{ .command = .{ .id = .@"search.toggle_case_sensitive", .label = "Toggle it" } }, .{ .command = .{ .id = .@"search.refresh", .label = "Rerun" } } },
        },
        .whole_word => .{
            .title = "\\b — whole word",
            .body = "Click toggles whether the query must match a whole word — `log` stops matching `login` — and reruns the search. It wraps the query in `\\b` word boundaries, so a query that already has a regex boundary does not need it. The flag is per search.",
            .links = &.{ .{ .command = .{ .id = .@"search.toggle_whole_word", .label = "Toggle it" } }, .{ .command = .{ .id = .@"search.refresh", .label = "Rerun" } } },
        },
        .regex => .{
            .title = ".* — regex",
            .body = "Click toggles whether the query is a regular expression or literal text, and reruns the search. Off, a `.` is a dot and a `(` a parenthesis; on, ripgrep's Rust-regex syntax applies, so escape the ones you mean literally. The flag is per search.",
            .links = &.{ .{ .command = .{ .id = .@"search.toggle_regex", .label = "Toggle it" } }, .{ .command = .{ .id = .@"search.refresh", .label = "Rerun" } } },
        },
    };
}

// ─── the HTTP panel's parts ─────────────────────────────────────────────

pub fn http(part: http_panel.Part) Entry {
    return switch (part) {
        .chip => |c| switch (c.kind) {
            .filter => .{
                .title = "HTTP section filter",
                .body = "Puts the keys in the filter for this ONE section of the HTTP panel — the collections, the recent sends, the captured requests — so the query narrows only its rows. The header row beside the chip folds the whole section. Esc clears the filter.",
                .keys = &.{ .{ .chord = "/", .label = "Focus the filter" }, .{ .chord = "Esc", .label = "Clear" } },
                .links = &.{.{ .command = .{ .id = .@"http.panel_toggle_section", .label = "Fold the section" } }},
            },
            .refresh => .{
                .title = "HTTP: refresh",
                .body = "Rescans the collections, the request files, the envs, the captured log and the mocks and rebuilds the HTTP panel — after a file was written outside mnml, or a capture ended. The same as `http.refresh` from the palette. Sends in flight are untouched.",
                .links = &.{ .{ .command = .{ .id = .@"http.refresh", .label = "Refresh now" } }, .{ .command = .{ .id = .@"http.sync", .label = "Sync the sources" } } },
            },
            .capture => .{
                .title = "HTTP: start a capture",
                .body = "Launches the browser pane and starts recording its network log into the CAPTURED section — every request the page makes, with its response, replayable as a request of your own. Stop it from the same chip or `http.capture_now` for a one-shot. Needs Chrome; the browser settings pick headless or not.",
                .links = &.{ .{ .command = .{ .id = .@"http.capture_start", .label = "Start a capture" } }, .{ .command = .{ .id = .@"http.view_captured", .label = "View the captured log" } }, .{ .settings = .{ .row = comptime copy.settingsRow("browser.headless"), .label = "Headless browser" } } },
            },
            .clear => switch (c.section) {
                .recent => .{
                    .title = "HTTP: clear recent",
                    .body = "Truncates `.rqst/history.jsonl` — every RECENT row goes, for this workspace, with no undo. The global history (`http.history_global`) is other workspaces' and stays. Send again and the list starts over.",
                    .links = &.{ .{ .command = .{ .id = .@"http.clear_recent", .label = "Clear the history" } }, .{ .command = .{ .id = .@"http.history_global", .label = "Every workspace's history" } } },
                },
                .captured => .{
                    .title = "HTTP: clear captured",
                    .body = "Truncates the captured log — every CAPTURED row goes, with no undo. A capture still running keeps writing after the clear, so stop it first if you want the list to stay empty.",
                    .links = &.{ .{ .command = .{ .id = .@"http.clear_captured", .label = "Clear the log" } }, .{ .command = .{ .id = .@"http.capture_start", .label = "Start a capture" } } },
                },
                .cookies => .{
                    .title = "Cookies: clear the jar",
                    .body = "Empties the cookie jar — every cookie a send stored, for every host, with no undo. The next send starts without a session. `cookies.persist` is whether the jar is written to disk between runs.",
                    .links = &.{ .{ .command = .{ .id = .@"cookies.show", .label = "Show the jar first" } }, .{ .command = .{ .id = .@"cookies.clear", .label = "Clear it" } } },
                },
                else => .{
                    .title = "HTTP: clear the filter",
                    .body = "Clears the filter on this section of the HTTP panel so every row shows again. The rows themselves are untouched; the chip is the mouse's Esc.",
                    .keys = &.{.{ .chord = "Esc", .label = "Clear" }},
                    .links = &.{.{ .command = .{ .id = .@"http.refresh", .label = "Refresh the panel" } }},
                },
            },
            .new => switch (c.section) {
                .envs => .{
                    .title = "HTTP: new env",
                    .body = "Creates a new `.env` in `.mnml/env/` and opens it — `KEY=value` lines that `{{KEY}}` in a request resolves to when this env is picked. One env per target (dev, staging); the picked one is in the request pane's header. Keep secrets out of git: `.mnml/env/` is yours to ignore.",
                    .links = &.{ .{ .command = .{ .id = .@"http.new_env", .label = "New env" } }, .{ .command = .{ .id = .@"http.edit_env", .label = "Edit the picked env" } } },
                },
                else => .{
                    .title = "HTTP: new collection",
                    .body = "Creates a new request collection — a folder under `.mnml/collections/` — after asking for a name. Requests saved into it from a Request pane's Ctrl+S land as `req-N.http`; the ` + ` on the folder's row opens a blank one aimed there.",
                    .links = &.{ .{ .command = .{ .id = .@"http.new_collection", .label = "New collection" } }, .{ .command = .{ .id = .@"http.import_postman", .label = "Import a Postman collection" } } },
                },
            },
        },
        .link => |l| switch (l) {
            .new_request => .{
                .title = "New HTTP request",
                .body = "Opens a blank Request pane as a new tab — method, URL, headers, body as fields; Enter edits a field, Ctrl+Enter sends, Ctrl+S saves it as a `.http` file into a collection. The env picked in its header resolves `{{VAR}}` at send time.",
                .links = &.{ .{ .command = .{ .id = .@"http.new", .label = "New request" } }, .{ .command = .{ .id = .@"http.paste_curl", .label = "From a curl command" } } },
            },
            .paste_curl => .{
                .title = "Paste curl",
                .body = "Reads a `curl` command from the clipboard and opens it as a Request pane — method, URL, headers and body parsed out, `-u` and `-H 'Authorization'` included. The usual way in from a browser's *Copy as cURL*. A command curl would not accept stays as text in the URL field.",
                .links = &.{ .{ .command = .{ .id = .@"http.paste_curl", .label = "Paste from the clipboard" } }, .{ .command = .{ .id = .@"http.copy_curl", .label = "Copy the active request as curl" } } },
            },
            .import => .{
                .title = "Import",
                .body = "Imports a Postman collection or a HAR file from the clipboard into a collection — one `.http` per request, folders kept. Environments in a Postman export become envs. The import is a copy; edits here never write back to Postman.",
                .links = &.{ .{ .command = .{ .id = .@"http.import_postman", .label = "Import Postman" } }, .{ .command = .{ .id = .@"http.import_har", .label = "Import a HAR" } } },
            },
            .new_env => .{
                .title = "HTTP: new env",
                .body = "Creates a new `.env` in `.mnml/env/` and opens it — `KEY=value` lines that `{{KEY}}` in a request resolves to when this env is picked. One env per target (dev, staging); the picked one is in the request pane's header. Keep secrets out of git.",
                .links = &.{ .{ .command = .{ .id = .@"http.new_env", .label = "New env" } }, .{ .command = .{ .id = .@"http.pick_env", .label = "Pick an env" } } },
            },
            .new_chain => .{
                .title = "HTTP: new chain",
                .body = "Creates a new `.chain.json` in `.mnml/chains/` — a list of requests run in order, each able to capture a value from the response before (a token, an id) into a variable the next one uses. `http.run_chain` runs it; `mnml chain run FILE` does the same headless.",
                .links = &.{ .{ .command = .{ .id = .@"http.new_chain", .label = "New chain" } }, .{ .command = .{ .id = .@"http.run_chain", .label = "Run one" } } },
            },
            .new_collection => .{
                .title = "HTTP: new collection",
                .body = "Creates a new request collection — a folder under `.mnml/collections/` — after asking for a name. Requests saved into it from a Request pane's Ctrl+S land as `req-N.http`; the ` + ` on the folder's row opens a blank one aimed there.",
                .links = &.{ .{ .command = .{ .id = .@"http.new_collection", .label = "New collection" } }, .{ .command = .{ .id = .@"http.import_postman", .label = "Import a Postman collection" } } },
            },
        },
        .folder_new => .{
            .title = "New request in this collection",
            .body = "Opens a blank Request pane whose Ctrl+S lands as `req-N.http` inside this collection's folder — the fastest way to add a request without leaving the panel. Rename it from the pane's header once it has a purpose.",
            .links = &.{ .{ .command = .{ .id = .@"http.new_request", .label = "New request here" } }, .{ .command = .{ .id = .@"http.new", .label = "A blank one anywhere" } } },
        },
    };
}

// ─── the git palette's pill ─────────────────────────────────────────────

pub fn gitPalette(part: git_palette_ui.Part) Entry {
    return switch (part) {
        .repo => .{
            .title = "Repo pill",
            .body = "The repo whose rows the palette shows, with its colour. Click opens the repos menu — switch repo, *All repos* (every open repo's rows at once, `git.palette_all`), reopen a closed one, add a workspace; right-click picks the repo's colour. With several repos under the workspace this pill, not the file you are looking at, decides what the branch chip follows.",
            .links = &.{ .{ .command = .{ .id = .@"git.switch_repo", .label = "Switch repo" } }, .{ .command = .{ .id = .@"git.palette_all", .label = "Every repo at once" } }, .{ .command = .{ .id = .@"git.refresh_repos", .label = "Rescan for repos" } } },
        },
        .repo_prev => .{
            .title = "Previous repo",
            .body = "Steps the palette to the previous repo in discovery order, wrapping at the first — `[` does the same from the keyboard. The branch chip and the graph follow. With one repo the arrow is dimmed.",
            .links = &.{.{ .command = .{ .id = .@"git.repo_prev", .label = "Previous repo" } }},
        },
        .repo_next => .{
            .title = "Next repo",
            .body = "Steps the palette to the next repo in discovery order, wrapping at the last — `]` does the same from the keyboard. The branch chip and the graph follow. With one repo the arrow is dimmed.",
            .links = &.{.{ .command = .{ .id = .@"git.repo_next", .label = "Next repo" } }},
        },
    };
}

// ─── the rest ───────────────────────────────────────────────────────────

pub fn fontUpdate() Entry {
    return .{
        .title = "↑ Update the font",
        .body = "This Nerd Font family has a newer release than the one installed. Click runs the Homebrew command that brings it to the latest, in a terminal pane below — read the command before it runs. The terminal needs a relaunch to read the new face; mnml's glyph audit is what noticed.",
        .links = &.{ .{ .command = .{ .id = .@"integrations.audit_glyphs", .label = "Audit the glyphs" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.ascii_icons"), .label = "ASCII icons instead" } } },
    };
}

pub fn aiPlaceholder() Entry {
    return .{
        .title = "+ Add Claude Code",
        .body = "An empty slot of the AI grid — the layout that shows several sessions at once as splits. Click starts the next Claude Code session here; the card becomes the session's pane. `ui.ai_layout_mode = tabs` stacks sessions in one leaf instead and has no slots.",
        .links = &.{ .{ .command = .{ .id = .@"ai.claude_code_new", .label = "Start a session here" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.ai_layout_mode"), .label = "AI session layout" } } },
    };
}

/// sessiondiff: the `N files` chip on a SESSIONS card.
pub fn sessionChangesChip() Entry {
    return .{
        .title = "Files this session changed",
        .body = "How many files this Claude or Codex session has changed since it started — dirty now and not before it, written after it began, or in a commit it made (`ui.session_changes` picks the rules). Click opens them as a git status pane scoped to the session: diff, stage, and commit with the session's title as the message. The count follows the repo's status; the refresh chip reads git again.",
        .links = &.{ .{ .command = .{ .id = .@"sessions.changes", .label = "What did this session change" } }, .{ .command = .{ .id = .@"sessions.refresh", .label = "Refresh the sessions" } } },
    };
}

pub fn welcome(w: hit.WelcomeRow) Entry {
    return switch (w.kind) {
        .workspace => .{
            .title = "Workspace",
            .body = "A workspace this window has open — the one it started on, then the extra folders `workspaces` in config.zon and Add folder bring in — the same list Switch workspace offers. Enter or a click shows that workspace's files in the tree; `open` marks the one the tree is showing. On the start surface j / k walk the list and Tab moves to the next one.",
            .keys = &.{ .{ .chord = "Enter", .label = "Show it in the tree" }, .{ .command = .@"view.switch_workspace", .label = "Switch workspace" } },
            .links = &.{ .{ .command = .{ .id = .@"view.add_workspace", .label = "Add a folder" } }, .{ .command = .{ .id = .@"view.manage_workspaces", .label = "Manage workspaces" } } },
        },
        .recent => .{
            .title = "Recent file",
            .body = "A file opened recently in this workspace, newest first, from the session's recent list — the rows Recent files lists. Click or Enter opens it; right-click offers open, copy the path and the full list. The welcome pane closes itself once something is open.",
            .keys = &.{ .{ .chord = "Enter", .label = "Open" }, .{ .command = .@"picker.recent", .label = "Every recent file" } },
            .links = &.{ .{ .command = .{ .id = .@"picker.recent", .label = "Every recent file" } }, .{ .command = .{ .id = .@"file.clear_recent", .label = "Clear the list" } } },
        },
        .session => .{
            .title = "Session to resume",
            .body = "A Claude Code or Codex session of this workspace that no process is running any more, newest first, from the SESSIONS section's scan: its name — the one its tab and SESSIONS card go by: your rename, else its first prompt — the tool and how long ago it last moved. Enter or a click resumes it in a terminal pane (from here, with nothing else open, the whole editor area), in the directory it ran in, where the conversation picks up.",
            .keys = &.{ .{ .chord = "Enter", .label = "Resume it" }, .{ .command = .@"view.activity_sessions", .label = "The SESSIONS section" } },
            .links = &.{ .{ .command = .{ .id = .@"view.activity_sessions", .label = "Every session" } }, .{ .command = .{ .id = .@"sessions.refresh", .label = "Scan again" } } },
        },
        .new_session => .{
            .title = "+ New Claude Code session here",
            .body = "Starts a fresh Claude Code session in this workspace, in a terminal pane; its card joins the SESSIONS section. With Claude Code not installed the pane says so rather than failing quietly.",
            .keys = &.{.{ .chord = "Enter", .label = "Start it" }},
            .links = &.{ .{ .command = .{ .id = .@"ai.claude_code_new", .label = "Start a session" } }, .{ .command = .{ .id = .@"view.activity_sessions", .label = "The SESSIONS section" } } },
        },
        .shortcut => .{
            .title = "Shortcut",
            .body = "One of the commands worth knowing first — the file picker, the palette, the tree, Settings — with its chord under the active profile, read from the same table the cheatsheet lists. Click or Enter runs it; `?` on the start surface opens the cheatsheet. The welcome pane closes once something is open.",
            .keys = &.{ .{ .chord = "Enter", .label = "Run it" }, .{ .command = .@"view.cheatsheet", .label = "Every chord" } },
            .links = &.{ .{ .command = .{ .id = .@"view.cheatsheet", .label = "The cheatsheet" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.welcome"), .label = "Welcome screen" } } },
        },
    };
}

pub fn scriptHit(app: *App, arena: Allocator, pane: PaneId, id: u32) Allocator.Error!?Entry {
    const p = app.panes.get(pane) orelse return null;
    if (p.* == .session_changes) return sessionChangesHit(app, &p.session_changes, id);
    const kind = @tagName(std.meta.activeTag(p.*));
    if (p.* == .editor and id == line_blame.hit_id) return .{
        .title = (try line_blame.hoverTitle(app, arena, pane)) orelse "Current-line blame",
        .body = "Who last changed the cursor's line, how long ago, and the commit's summary — `git blame` for this one line, asked on the git worker once the cursor rests and kept until the file changes. Click opens that commit in the graph with the cursor on it. It says nothing while the buffer has unsaved changes (git blames the file on disk) or for a line not committed yet.",
        .links = &.{ .{ .command = .{ .id = .@"git.toggle_line_blame", .label = "Turn it off" } }, .{ .command = .{ .id = .@"git.blame_toggle", .label = "Blame every line in the gutter" } }, .{ .settings = .{ .row = comptime copy.settingsRow("editor.line_blame"), .label = "Current-line blame in Settings" } } },
    };
    if (p.* == .ai_usage) return try usagePane(app, arena, id);
    // The git graph's controls live above `0xF000_0000`, which the list
    // reading below would take for a kebab.
    if (p.* == .git_graph) if (git_graph.entry(id)) |e| return e;
    if (hit.ListHit.chipOf(id)) |c| return chip(.script, c);
    if (id == hit.ListHit.filter_id) return filter(.script);
    if (id >= hit.ListHit.kebab_base) return kebab(.{ .panel = .script, .idx = id - hit.ListHit.kebab_base });
    // A mounted integration paints and owns every cell, so only it can
    // say what is under the pointer: it names the element in a `hover`
    // message (`wire.SiblingMessage.hover`), and that is the entry.
    if (p.asMount()) |mp| {
        if (mp.hover_title.len > 0) return .{
            .title = try arena.dupe(u8, mp.hover_title),
            .body = try arena.dupe(u8, mp.hover_body),
        };
        return .{
            .title = try std.fmt.allocPrint(arena, "{s} pane", .{mp.title()}),
            .body = "A mounted integration: it paints every cell of this pane and takes its keys and clicks. Point at one of its chips, rows or buttons and it says what that one does; `?` in the pane lists its keys.",
            .links = &.{.{ .command = .{ .id = .@"focus.cycle", .label = "Cycle focus" } }},
        };
    }
    return .{
        .title = try std.fmt.allocPrint(arena, "{s} pane row", .{kind}),
        .body = "A row of a list hosted in a pane — the sessions table, a script's pane. Click selects it; click again, or Enter, acts on it; right-click is the row's menu. The header chips above are the same sort, refresh and filter the sections have.",
        .keys = &.{ .{ .chord = "Enter", .label = "Act on the row" }, .{ .chord = "Right-click", .label = "The row's menu" } },
        .links = &.{.{ .command = .{ .id = .@"focus.cycle", .label = "Cycle focus" } }},
    };
}

const PaneId = app_mod.PaneId;
const git_graph = @import("git_graph.zig");

/// The Claude usage pane's parts (`app/usage_pane.zig`'s hit ids).
fn usagePane(app: *App, arena: Allocator, id: u32) Allocator.Error!Entry {
    const up = @import("../usage_pane.zig");
    if (id == up.hit_kebab) return .{
        .title = "Usage pane menu",
        .body = "Add a Claude account, refresh every account now, or open the last raw response. A right-click on an account's own rows gives that account's menu instead — Re-auth, rename, remove, and under Advanced the paste-a-token prompt.",
        .keys = &.{ .{ .chord = "a", .label = "Add an account" }, .{ .chord = "r", .label = "Refresh" } },
        .links = &.{ .{ .command = .{ .id = .@"ai.claude_add_account", .label = "Add an account" } }, .{ .command = .{ .id = .@"ai.refresh_usage", .label = "Refresh now" } } },
    };
    if (up.accountOfHit(app, id)) |name| {
        if (up.isBreakdownHit(id)) return .{
            .title = try std.fmt.allocPrint(arena, "This week by surface — {s}", .{name}),
            .body = "Where this account's week went, one row per surface — Claude Code, chat on claude.ai, Cowork, everything else — as the endpoint's `seven_day_breakdown` reports it. Each percent is a share of the WEEKLY window above, not of these rows' total, so they add up to the week's figure at most; the muted time is when the endpoint took them. An account whose endpoint sends no breakdown shows no rows. Right-click is the account's menu.",
            .keys = &.{ .{ .chord = "Right-click", .label = "The account's menu" }, .{ .chord = "r", .label = "Refresh" } },
            .links = &.{ .{ .command = .{ .id = .@"ai.refresh_usage", .label = "Refresh now" } }, .{ .command = .{ .id = .@"ai.show_last_response", .label = "The raw response" } } },
        };
        if (up.isReauthHit(id)) return .{
            .title = try std.fmt.allocPrint(arena, "Re-auth {s}", .{name}),
            .body = "The fix for the state line beside it — `expired`, `keychain holds another account`, `no login yet`. Click opens a pane running `claude login`; once the login lands in the macOS keychain and its email is this account's, it is written to the account's token file, the pane closes and the figures come back. A login for another account on file is not filed here: a box says whose it is and offers to file it under that one.",
            .keys = &.{.{ .chord = "Right-click", .label = "The account's menu" }},
            .links = &.{ .{ .command = .{ .id = .@"ai.claude_reauth", .label = "Re-auth an account" } }, .{ .command = .{ .id = .@"ai.refresh_usage", .label = "Refresh now" } } },
        };
        if (up.isPencilHit(id)) return .{
            .title = try std.fmt.allocPrint(arena, "Rename {s}", .{name}),
            .body = "Click opens the rename prompt, seeded with the name. The new name is written to `ai.claude_accounts` in the home config; the account's token file, numbers and identity pin go with it.",
            .links = &.{.{ .command = .{ .id = .@"ai.claude_rename_account", .label = "Rename an account" } }},
        };
        return .{
            .title = try std.fmt.allocPrint(arena, "Claude account — {s}", .{name}),
            .body = "One account's windows, as Claude Code's own usage screen shows them: the five-hour session, the week across models, a week per model, and any other window the endpoint reports under a key this build does not name, each bar coloured by the endpoint's own severity with its reset time. Under the week, when the endpoint sends one, `This week by surface` splits it by where it was spent. The line under the name says where its sign-in stands — `signed in · resets 3:20am`, or `expired`, `keychain holds another account`, `no login yet`, each with a Re-auth button. An expired token whose account the Claude Code CLI is logged in as again is re-captured on its own. Right-click is the account's menu — Re-auth, rename, remove, Advanced. The green gutter and `(active)` mark the account the Claude Code CLI is logged in as.",
            .keys = &.{ .{ .chord = "Right-click", .label = "The account's menu" }, .{ .chord = "r", .label = "Refresh" } },
            .links = &.{ .{ .command = .{ .id = .@"ai.claude_reauth", .label = "Re-auth" } }, .{ .command = .{ .id = .@"ai.refresh_usage", .label = "Refresh now" } } },
        };
    }
    return .{
        .title = "Claude usage",
        .body = "Every watched Claude account, one block each, with a line saying where its sign-in stands and a Re-auth button when it needs one. `a` adds an account, `r` refreshes them all. Right-click here or the kebab is the pane's menu.",
        .keys = &.{ .{ .chord = "a", .label = "Add an account" }, .{ .chord = "r", .label = "Refresh" }, .{ .chord = "Right-click", .label = "The pane's menu" } },
        .links = &.{ .{ .command = .{ .id = .@"ai.claude_add_account", .label = "Add an account" } }, .{ .command = .{ .id = .@"ai.show_last_response", .label = "The raw response" } } },
    };
}

/// sessiondiff: a hint word or a row of a session's changes view.
pub fn sessionChangesHit(app: *App, v: *const session_changes.ChangesPane, id: u32) Entry {
    if (status_view.hintOf(id)) |a| return switch (a) {
        .stage, .unstage, .toggle, .stage_all, .unstage_all => .{
            .title = "Stage / unstage",
            .body = "`s` stages the cursor's file in the session's repo, `u` unstages it, space picks whichever it is not. Only the session's files are listed, and only those move — the whole-repo `a` / `A` are not on this view on purpose.",
            .keys = &.{.{ .chord = "s", .label = "Stage the file" }},
            .links = &.{ .{ .command = .{ .id = .@"git.stage", .label = "Stage it" } }, .{ .command = .{ .id = .@"git.unstage", .label = "Unstage it" } } },
        },
        .diff => .{
            .title = "Diff",
            .body = "Enter opens the cursor row's diff: unstaged against the index, staged against HEAD, a committed file from the session's starting HEAD to now. On the Commit… row Enter commits instead.",
            .keys = &.{.{ .chord = "Enter", .label = "Open the diff" }},
            .links = &.{.{ .command = .{ .id = .@"git.diff_file", .label = "Open it" } }},
        },
        .commit, .ai_commit => .{
            .title = "Commit",
            .body = "`c` opens the commit prompt for the session's repo, seeded with the session's title; Enter keeps it. What is staged there is what commits, so stage the session's rows first.",
            .keys = &.{.{ .chord = "c", .label = "Commit" }},
            .links = &.{.{ .command = .{ .id = .@"git.commit", .label = "Commit" } }},
        },
        .refresh => .{
            .title = "Refresh",
            .body = "`r` reads git again for this session — its status, its commits since the starting HEAD, the mtimes. The view already follows the repo's status; this catches a file edited again while it was already dirty.",
            .keys = &.{.{ .chord = "r", .label = "Refresh" }},
            .links = &.{.{ .command = .{ .id = .@"sessions.refresh", .label = "Refresh every session" } }},
        },
    };
    return switch (session_changes.rowKind(app, v, id)) {
        .unstaged => .{
            .title = "Unstaged — the session changed it",
            .body = "A file the session changed that is not in the index: dirty now and not dirty when it started, or written after it started. `s` stages it; Enter diffs it against the index. A name in orange after the path is another session that touched the same file.",
            .keys = &.{ .{ .chord = "Enter", .label = "Open the diff" }, .{ .chord = "s", .label = "Stage it" } },
            .links = &.{ .{ .command = .{ .id = .@"git.stage", .label = "Stage it" } }, .{ .command = .{ .id = .@"git.open_file", .label = "Open the file" } } },
        },
        .staged => .{
            .title = "Staged — ready to commit",
            .body = "A file the session changed that is in the index now; the Commit… row takes it. `u` puts it back to unstaged; Enter diffs the index against HEAD. Anything else staged in the repo commits with it.",
            .keys = &.{.{ .chord = "Enter", .label = "Open the diff" }},
            .links = &.{ .{ .command = .{ .id = .@"git.unstage", .label = "Unstage it" } }, .{ .command = .{ .id = .@"git.commit", .label = "Commit" } } },
        },
        .committed => .{
            .title = "Committed since the session started",
            .body = "A file in a commit made since the session's pane started — by the session or by you — with the newest commit's letter. Enter opens its diff from the session's starting HEAD to now. Nothing to stage: it is in the history already.",
            .keys = &.{.{ .chord = "Enter", .label = "Open the diff" }},
            .links = &.{ .{ .command = .{ .id = .@"git.graph", .label = "The commit graph" } }, .{ .command = .{ .id = .@"git.open_file", .label = "Open the file" } } },
        },
        .commit => .{
            .title = "Commit…",
            .body = "Commits what is staged in the session's repo, with the session's title seeded as the message — Enter on the prompt keeps it, typing replaces it. Stage the session's rows first; `c` anywhere in the view does the same.",
            .keys = &.{.{ .chord = "Enter", .label = "Commit" }},
            .links = &.{.{ .command = .{ .id = .@"git.commit", .label = "Commit" } }},
        },
        .none => .{
            .title = "What this session changed",
            .body = "A row of a session's changes view — the files one Claude or Codex session changed since its pane started, grouped as uncommitted and committed since. Click selects, click again or Enter opens the diff, right-click is the row menu.",
            .links = &.{ .{ .command = .{ .id = .@"sessions.changes", .label = "What did this session change" } }, .{ .command = .{ .id = .@"sessions.refresh", .label = "Refresh" } } },
        },
    };
}

pub fn link(arena: Allocator, url: []const u8) Allocator.Error!Entry {
    return .{
        .title = try std.fmt.allocPrint(arena, "Link: {s}", .{url}),
        .body = "A link in text mnml painted — a URL on a session's card or in the sessions table's summary, or a key an installed integration declares (a ticket such as `ENG-123`, which opens that integration's page for it). Click opens it in the OS browser (`ui.external_browser` names which); right-click offers Copy link and Open link. Only http and https go out — anything else is a toast, not a launch.",
        .keys = &.{.{ .chord = "Right-click", .label = "Copy link / Open link" }},
        .links = &.{.{ .command = .{ .id = .@"browser.open_url", .label = "Open it in the browser pane" } }},
    };
}

pub fn infoView(part: hit.InfoPart) Entry {
    return switch (part) {
        .body => .{
            .title = "Info panel",
            .body = "This box: what the pointer rests on — a chip, a row, a button, a menu row — or, when the pointer is elsewhere, what the keyboard focus is on, then the active pane. The `→` rows run the command they name, `⚙` opens a Settings row, `↗` a web page and `✦` asks the AI session about the thing with its state attached. The wheel scrolls a long entry; a dim *no help written yet* is a control without an entry.",
            .keys = &.{.{ .chord = "Wheel", .label = "Scroll the entry" }},
            .links = &.{ .{ .settings = .{ .row = comptime copy.settingsRow("ui.hover_help_height"), .label = "Its height" } }, .{ .command = .{ .id = .@"view.discovery", .label = "The click-discovery panel" } } },
        },
        .pin => .{
            .title = "Pin the entry",
            .body = "Click pins what the box shows now: the entry stays — its words and its links — wherever the pointer goes, until the pin is clicked again or Esc is pressed in the box. Lit yellow while pinned. Without it the box follows the pointer, and holds an entry only while the pointer travels to the box.",
            .keys = &.{.{ .command = .@"help.pin_toggle", .label = "Pin / unpin" }},
            .links = &.{ .{ .command = .{ .id = .@"help.pin_toggle", .label = "Pin / unpin" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.hover_help_grace_ms"), .label = "The travel grace" } } },
        },
        .kebab => .{
            .title = "Info panel menu",
            .body = "Click opens the panel's one row: turn it off. Settings → UI → Hover help brings it back — the kebab goes with the panel, so the menu cannot undo itself. The panel's height is `ui.hover_help_height`.",
            .links = &.{ .{ .settings = .{ .row = comptime copy.settingsRow("ui.hover_help"), .label = "Hover help in Settings" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.hover_help_height"), .label = "Its height" } } },
        },
        .try_it => .{
            .title = "A link row",
            .body = "Click runs what the row names: `→` a palette command, `⚙` a Settings row (the overlay opens on it), `↗` a web page in the OS browser, `✦` a question to the Claude session with the hovered thing's state in the prompt. The rows belong to the entry above them and change with it.",
            .keys = &.{.{ .command = .palette, .label = "Every command" }},
            .links = &.{.{ .command = .{ .id = .palette, .label = "The command palette" } }},
        },
    };
}

/// For the AI: a row's own tip — the session card's state, the git
/// row's file — when the section has one.
pub fn askContext(app: *App, arena: Allocator, r: hit.PanelRow) Allocator.Error!?[]const u8 {
    const tip = switch (r.panel) {
        .sessions => try sessions.hoverTip(app, arena, r.idx),
        .git => try git_palette.hoverTip(app, arena, r.idx),
        else => null,
    } orelse return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.print(arena, "- {s} row: {s}\n", .{ panelName(r.panel), tip.title });
    if (tip.detail) |d| try out.print(arena, "  {s}\n", .{d});
    for (tip.lines) |l| try out.print(arena, "  {s}\n", .{l});
    return out.items;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "every chip kind, every panel's row and kebab, every flag, every HTTP part, the pill, the info view parts have entries" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const a = app.frame.allocator();
    inline for (comptime std.enums.values(hit.ChipKind)) |k| try t.expect(chip(.notes, k).body.len >= 40);
    inline for (comptime std.enums.values(PanelId)) |p| {
        try t.expect((try row(&app, a, .{ .panel = p, .idx = 0 })).?.body.len >= 40);
        try t.expect(kebab(.{ .panel = p, .idx = 0 }).body.len >= 40);
        try t.expect(filter(p).body.len >= 40);
    }
    inline for (comptime std.enums.values(search_view.Flag)) |f| try t.expect(searchChip(f).body.len >= 40);
    inline for (comptime std.enums.values(http_panel.Link)) |l| try t.expect(http(.{ .link = l }).body.len >= 40);
    inline for (comptime std.enums.values(http_panel.Section)) |s| inline for (comptime std.enums.values(http_panel.ChipKind)) |k| try t.expect(http(.{ .chip = .{ .section = s, .kind = k } }).body.len >= 40);
    try t.expect(http(.{ .folder_new = 0 }).body.len >= 40);
    inline for (comptime std.enums.values(git_palette_ui.Part)) |p| try t.expect(gitPalette(p).body.len >= 40);
    try t.expectEqualStrings("Info panel", infoView(.body).title);
    try t.expectEqualStrings("Info panel menu", infoView(.kebab).title);
    try t.expectEqualStrings("A link row", infoView(.{ .try_it = 0 }).title);
    try t.expect(fontUpdate().body.len >= 40 and aiPlaceholder().body.len >= 40);
    try t.expect(welcome(.{ .kind = .recent, .idx = 0 }).body.len >= 40);
    try t.expect((try link(a, "https://x.y")).body.len >= 40);
}

test "a git graph pane's controls read their own entries through the pane-row reading, never the kebab's Row actions" {
    const graph_view = @import("../../ui/git_graph_view.zig");
    const git_toolbar = @import("../../ui/git_toolbar.zig");
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const a = app.frame.allocator();
    // The pane owns the graph from here; `app.deinit` frees it.
    const pane = try app.panes.add(.{ .git_graph = .{ .gpa = t.allocator, .repo = 0, .name = try t.allocator.dupe(u8, "proj"), .arena = .init(t.allocator), .detail_arena = .init(t.allocator) } });
    const ids = [_]u32{
        git_toolbar.hitId(.push),
        graph_view.sortId(.author),
        graph_view.wipButtonId(.stage_all),
        graph_view.wipButtonId(.textarea),
        graph_view.wipFileId(.{ .idx = 0, .staged = false, .button = true }),
        graph_view.wipFileId(.{ .idx = 1, .staged = true, .button = false }),
    };
    for (ids) |id| {
        const e = (try scriptHit(&app, a, pane, id)).?;
        try t.expect(!std.mem.eql(u8, e.title, "Row actions"));
        try t.expectEqualStrings(git_graph.entry(id).?.title, e.title);
    }
}

test "the start surface's rows say what they are: the window's workspaces, and a session named as its tab is, resumed where there is room" {
    try std.testing.expectEqualStrings("Workspace", welcome(.{ .kind = .workspace, .idx = 0 }).title);
    const s = welcome(.{ .kind = .session, .idx = 0 });
    // From the start surface a resumed session takes the whole editor
    // area; it is not always "on the right".
    try std.testing.expect(std.mem.indexOf(u8, s.body, "on the right") == null);
    try std.testing.expect(std.mem.indexOf(u8, s.body, "first prompt") != null);
}
