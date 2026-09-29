//! Hover help for the statusline chips' menus (`context_menus.zig`'s
//! `open*Menu` per chip, plus `clock`, `coverage`, `ghost_chip`,
//! `now_playing` and the LSP chip in `app/statusline.zig`): the branch
//! chip's git verbs, the diagnostics chip, the bell, the find / sel /
//! position / size / wrap / language / symbol / tests / transfer chips,
//! the stress meter, the AI ghost-text chip, the clock, the coverage
//! chip, the mixr cluster, the workspace chip and the PR chip. The
//! theme pill's `Toggle` row is a family: its label says whether there
//! is a pair to swap between.

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("../../../app.zig").App;
const copy = @import("../../info_view_copy.zig");
const menus = @import("../menus.zig");
const command = @import("../../../core/command.zig");
const Row = menus.Row;
const Entry = copy.Entry;
const ask = copy.ask_link;

pub const rows = [_]Row{
    // ── the branch chip: `Git` ──
    .{ .menu = "Git", .label = "Status / staging", .entry = .{
        .title = "Status / staging",
        .body = "Opens the git status pane on the chip's repo — every changed file in one list, `-` (Space too, in the standard profile) staging and unstaging a row, `s` / `u` staging or unstaging it outright, Enter opening that file's diff — and asks the worker for a fresh status as it opens. Outside a git repository the row toasts rather than opening anything. *Commit graph* is the other half: the history rather than the working tree.",
        .keys = &.{ .{ .command = .@"git.status_pane", .label = "Status / staging" }, .{ .command = .@"git.commit", .label = "Commit what is staged" } },
        .links = &.{ .{ .command = .{ .id = .@"git.status_pane", .label = "Open it" } }, .{ .command = .{ .id = .@"git.diff", .label = "Diff the worktree" } }, .{ .command = .{ .id = .@"git.commit", .label = "Commit the staged files" } } },
    } },
    .{ .menu = "Git", .label = "Commit graph", .entry = .{
        .title = "Commit graph",
        .body = "Opens the commit-graph pane for this repo — the DAG newest first, the working tree as its top row, a commit's diff on Enter — and puts the left column into git mode with it. The working-tree row carries the commit box, so a message can be written without leaving the graph. It is the same pane the rail's git section opens.",
        .keys = &.{ .{ .command = .@"git.graph", .label = "The commit graph" }, .{ .command = .@"view.activity_git", .label = "Git in the left column" } },
        .links = &.{ .{ .command = .{ .id = .@"git.graph", .label = "Open it" } }, .{ .command = .{ .id = .@"git.status_pane", .label = "The status pane instead" } } },
    } },
    .{ .menu = "Git", .label = "Checkout branch\u{2026}", .entry = .{
        .title = "Checkout branch\u{2026}",
        .body = "Asks the worker for every local and remote branch and offers them as a picker; the pick is checked out and the chip's label follows it. Uncommitted changes the switch would overwrite make git refuse — the toast carries the reason and a `log` link into the command log. Stash them first, or take them onto a fresh branch with *New branch…*.",
        .links = &.{ .{ .command = .{ .id = .@"git.checkout", .label = "Pick a branch" } }, .{ .command = .{ .id = .@"git.stash", .label = "Stash the changes first" } }, ask },
    } },
    .{ .menu = "Git", .label = "New branch\u{2026}", .entry = .{
        .title = "New branch\u{2026}",
        .body = "Asks for a name and creates that branch from HEAD, checked out; uncommitted changes come along, so it is the way to move work off the wrong branch. A name git refuses — a space in it, one that exists already — comes back as a toast and nothing is created. The branch has no upstream until the first *Push*, which sets one.",
        .links = &.{ .{ .command = .{ .id = .@"git.new_branch", .label = "Create one" } }, .{ .command = .{ .id = .@"git.push", .label = "Push it upstream" } }, .{ .command = .{ .id = .@"git.checkout", .label = "Switch to an existing one" } } },
    } },
    // `Fetch` and `Commit…` are this menu's and the rail's Source
    // control menu's, running the same command from both — one row.
    .{ .label = "Fetch", .entry = .{
        .title = "Fetch",
        .body = "Runs `git fetch --all --prune` on the active repo on the worker: remote refs and tags come down, branches deleted on the remote go, and nothing in the working tree is touched. The chip's ahead / behind counts are honest again once it lands. A remote it cannot reach — no network, no credentials — toasts the reason with a `log` link into the command log.",
        .links = &.{ .{ .command = .{ .id = .@"git.fetch", .label = "Fetch now" } }, .{ .command = .{ .id = .@"git.pull", .label = "Pull instead" } }, ask },
    } },
    .{ .menu = "Git", .label = "Pull", .entry = .{
        .title = "Pull",
        .body = "Runs `git pull --ff-only`: the branch moves up to its upstream when the history allows it, and git refuses rather than making a merge commit when it does not. A dirty tree or a diverged branch is that refusal, not a prompt — the toast says which, with a `log` link into the command log. *Fetch* is the way to see what is on the remote without moving.",
        .links = &.{ .{ .command = .{ .id = .@"git.pull", .label = "Pull now" } }, .{ .command = .{ .id = .@"git.fetch", .label = "Just fetch" } }, ask },
    } },
    .{ .menu = "Git", .label = "Push", .entry = .{
        .title = "Push",
        .body = "Pushes the current branch to its upstream, adding `--set-upstream` when it has none, and refreshes the status once it lands. A rejected push — the remote moved on, or the credentials are not there — comes back as a toast with a `log` link; nothing here ever force-pushes for you. Pull first when the remote is ahead.",
        .links = &.{ .{ .command = .{ .id = .@"git.push", .label = "Push now" } }, .{ .command = .{ .id = .@"git.pull", .label = "Pull first" } }, ask },
    } },
    // The branch chip's menu and the branches panel's row menus offer
    // it in place of Pull / Push on a branch that was never pushed.
    .{ .label = "Publish branch (set upstream)", .entry = .{
        .title = "Publish branch (set upstream)",
        .body = "The branch has never been pushed: it has no upstream (or the one it had was deleted on the remote), so there is nothing to pull from and nothing on the remote to delete. This row pushes it with `push -u` to the remote, which makes that remote branch its upstream — after that the menu offers Pull, Push and the force push as for any tracking branch. A rejected push toasts the reason with a `log` link.",
        .links = &.{ .{ .command = .{ .id = .@"git.push", .label = "Publish the current branch" } }, .{ .command = .{ .id = .@"git.set_upstream", .label = "Track an existing remote branch instead" } }, ask },
    } },
    .{ .menu = "Git", .label = "Stash\u{2026}", .entry = .{
        .title = "Stash\u{2026}",
        .body = "Asks for an optional message and runs `git stash push -u`, so untracked files go with the tracked ones and the working tree comes back clean. The entry joins the stash list, newest first, and *Stash pop* takes that one back. With nothing to stash git says so and the list is unchanged.",
        .links = &.{ .{ .command = .{ .id = .@"git.stash", .label = "Stash the tree" } }, .{ .command = .{ .id = .@"git.stash_pop", .label = "Pop the last one" } }, .{ .command = .{ .id = .@"git.status_pane", .label = "See what would go" } } },
    } },
    .{ .menu = "Git", .label = "Stash pop", .entry = .{
        .title = "Stash pop",
        .body = "Applies the most recent stash entry back onto the working tree and drops it — the pair to *Stash…*, with no picker in between. A file the stash touches that has changed since can conflict; git then keeps the entry rather than dropping it and leaves the markers in the tree for you. The toast carries a `log` link to the command the worker ran.",
        .links = &.{ .{ .command = .{ .id = .@"git.stash_pop", .label = "Pop it" } }, .{ .command = .{ .id = .@"git.status_pane", .label = "See the result" } }, ask },
    } },
    .{ .label = "Commit\u{2026}", .entry = .{
        .title = "Commit\u{2026}",
        .body = "Opens the commit prompt and commits what is in the index when you accept — nothing unstaged is included, so stage first. With the commit graph's working-tree box already holding a message, the row commits from that box instead of asking. An empty message cancels, and a repo with nothing staged says so. After a merge, a cherry-pick or a `merge --squash` the prompt starts from the message git has ready, as `git commit` does.",
        .keys = &.{.{ .command = .@"git.commit", .label = "Commit" }},
        .links = &.{ .{ .command = .{ .id = .@"git.commit", .label = "Write one" } }, .{ .command = .{ .id = .@"git.ai_commit", .label = "Let Claude write it" } }, .{ .command = .{ .id = .@"git.status_pane", .label = "Stage something first" } } },
    } },
    .{ .menu = "Git", .label = "AI commit message", .entry = .{
        .title = "AI commit message",
        .body = "Claude reads the staged diff and writes a message from it; the commit prompt then opens with that text, so it can be edited before anything is committed. This row commits nothing by itself. It fails before any git runs when the route is off (`ai.routing.claude.backend = off`) or a message is already on its way.",
        .links = &.{ .{ .command = .{ .id = .@"git.ai_commit", .label = "Ask Claude" } }, .{ .command = .{ .id = .@"git.commit", .label = "Write it yourself" } }, .{ .settings = .{ .row = copy.settingsRow("ai.routing.claude.backend"), .label = "Claude backend in Settings" } } },
    } },
    // Several menus carry a `Refresh`; this one is git's.
    .{ .label = "Refresh", .command = .@"git.refresh", .entry = .{
        .title = "Refresh the git status",
        .body = "Asks the git worker for a fresh status of the active repo now, instead of waiting for the next save: the chip's branch, its ahead / behind counts and the tree's dirty markers all come from that one answer. It re-reads the repository only and never touches the remote — *Fetch* is the row that does. Outside a repository it toasts.",
        .links = &.{ .{ .command = .{ .id = .@"git.refresh", .label = "Refresh now" } }, .{ .command = .{ .id = .@"git.status_pane", .label = "The status pane" } }, .{ .command = .{ .id = .@"git.fetch", .label = "Fetch from the remote" } } },
    } },

    // ── the now-playing cluster: `mixr` ──
    .{ .menu = "mixr", .label = "\u{25CB} Beatport", .prefix = true, .entry = .{
        .title = "\u{25CB} Beatport: not signed in",
        .body = "The Beatport account mixr would play from, as a status row rather than a button — the hollow circle is the not-signed-in mark. mixr control is cut from this build, so the row reports that instead: the toast names the reason and docs/PARITY.md, where the cut is recorded. The player rows under it only write a config key, so those still work.",
        .links = &.{ .{ .command = .{ .id = .@"mixr.show_auth_status", .label = "Report the status" } }, .{ .command = .{ .id = .@"mixr.show", .label = "Open mixr" } } },
    } },
    .{ .menu = "mixr", .label = "mixr (Beatport)", .entry = preferred("mixr (Beatport)", "mixr", "mixr's track is read from `~/.mixr/quick.txt` and the chip wears the baked Beatport mark.", .@"mixr.set_preferred_mixr") },
    .{ .menu = "mixr", .label = "Music", .entry = preferred("Music", "Apple Music", "Music is asked over `osascript`, so it answers on macOS and nowhere else.", .@"mixr.set_preferred_music") },
    .{ .menu = "mixr", .label = "Spotify", .entry = preferred("Spotify", "Spotify", "Spotify is asked over `osascript` too — macOS only, and only while the app is running.", .@"mixr.set_preferred_spotify") },
    .{ .menu = "mixr", .label = "Play random chart", .entry = .{
        .title = "Play random chart",
        .body = "Starts a random Beatport chart from a favourited genre through mixr — the idle chip's play button is the same call. mixr control is cut from this build, so the row toasts the reason and where it is recorded rather than playing anything. A track playing in any other player still shows on the chip.",
        .links = &.{ .{ .command = .{ .id = .@"mixr.play_now", .label = "Try it" } }, .{ .command = .{ .id = .@"mixr.show", .label = "Open mixr" } } },
    } },
    .{ .menu = "mixr", .label = "Open mixr", .entry = .{
        .title = "Open mixr",
        .body = "Opens mixr, the terminal DJ, as a pane in the editor area — a click on the chip's brand mark is the same thing. The mixr runners are cut from this build, so the row toasts the reason instead. `:term mixr` opens the binary as a plain terminal pane when it is on PATH.",
        .links = &.{ .{ .command = .{ .id = .@"mixr.show", .label = "Try it" } }, .{ .command = .{ .id = .@"term.shell", .label = "Open a shell instead" } } },
    } },
    .{ .menu = "mixr", .label = "Show: Queue", .entry = mixrView("Show: Queue", "queue — what is lined up to play next", .@"mixr.show_queue") },
    .{ .menu = "mixr", .label = "Show: History", .entry = mixrView("Show: History", "history — what has already played this session", .@"mixr.show_history") },
    .{ .menu = "mixr", .label = "Show: Browse", .entry = mixrView("Show: Browse", "browse view — the charts and genres it can pull from", .@"mixr.show_browse") },
    .{ .menu = "mixr", .label = "Show: Log", .entry = mixrView("Show: Log", "log — what mixr itself has been doing, for when a track will not load", .@"mixr.show_log") },
    .{ .menu = "mixr", .label = "Copy track title", .entry = .{
        .title = "Copy track title",
        .body = "Copies the track the chip is showing as the player spells it — `Artist - Title` — without the transport glyphs around it. The row is in the menu only while something is loaded; with nothing playing it toasts. The copy is mnml's own, so this one works whatever else is cut.",
        .links = &.{.{ .command = .{ .id = .@"mixr.copy_track", .label = "Copy it" } }},
    } },

    // ── the LSP chip: `LSP` ──
    .{ .menu = "LSP", .label = "Status", .entry = .{
        .title = "Status",
        .body = "Toasts the language servers running right now, each with the root it was started on relative to the workspace, then the ones that were wanted and are missing with the command that installs each. A left click on the chip is this same row. Nothing running and nothing missing means no server is configured for the buffer's language.",
        .links = &.{ .{ .command = .{ .id = .@"lsp.status", .label = "Report them" } }, .{ .settings = .{ .row = copy.settingsRow("editor.lsp_missing_defaults"), .label = "Missing-server notices" } } },
    } },
    // Shared with the Language chip's menu, the same command in both.
    .{ .label = "Symbols in file", .entry = .{
        .title = "Symbols in file",
        .body = "Asks the buffer's language server for its symbols and offers them as a fuzzy picker — functions, types, fields — Enter jumping to the definition with the preview column showing it. It needs a server for that language; with none it toasts and no picker opens. The outline pane is the same list kept open in the right column.",
        .keys = &.{.{ .command = .@"lsp.symbols", .label = "Symbols in this file" }},
        .links = &.{ .{ .command = .{ .id = .@"lsp.symbols", .label = "List them" } }, .{ .command = .{ .id = .@"outline.show", .label = "Keep the list open" } }, .{ .command = .{ .id = .@"lsp.status", .label = "Which servers are running" } } },
    } },
    .{ .menu = "LSP", .label = "Symbols in workspace", .entry = .{
        .title = "Symbols in workspace",
        .body = "Asks for a query, then puts it to the server as one `workspace/symbol` request instead of searching this file; the answers open as a picker, Enter opening the file at the symbol. A server still indexing answers with what it has so far, so the first hits on a large project are thin. The file list above is the fast one.",
        .links = &.{ .{ .command = .{ .id = .@"lsp.workspace_symbols", .label = "Search the project" } }, .{ .command = .{ .id = .@"lsp.symbols", .label = "This file only" } } },
    } },
    .{ .menu = "LSP", .label = "Diagnostics list", .entry = .{
        .title = "Diagnostics list",
        .body = "Opens the problems panel: every error, warning and hint the servers have reported, grouped by file, Enter jumping to the line. What it lists follows the severity filter the diagnostics chip cycles. A file no server has opened contributes nothing to it until it is opened.",
        .keys = &.{.{ .command = .@"lsp.diagnostics", .label = "The problems panel" }},
        .links = &.{ .{ .command = .{ .id = .@"lsp.diagnostics", .label = "Open it" } }, .{ .command = .{ .id = .@"lsp.diagnostics_filter", .label = "Cycle the severity filter" } }, .{ .command = .{ .id = .@"lsp.next_diagnostic", .label = "Jump to the next one" } } },
    } },
    .{ .menu = "LSP", .label = "Code actions", .entry = .{
        .title = "Code actions",
        .body = "Asks the server what it can do at the cursor — a fix for the diagnostic under it, an import to add, a refactor it offers — and lists the answers as a picker; Enter applies the edit as one undo step. With nothing available at that position the server answers with an empty list and it toasts. Put the cursor on the squiggle first.",
        .keys = &.{.{ .command = .@"lsp.code_action", .label = "Code actions" }},
        .links = &.{ .{ .command = .{ .id = .@"lsp.code_action", .label = "Ask at the cursor" } }, .{ .command = .{ .id = .@"lsp.diagnostics", .label = "The diagnostics list" } } },
    } },
    .{ .menu = "LSP", .label = "Toggle inlay hints", .entry = .{
        .title = "Toggle inlay hints",
        .body = "Turns the server's inline chips — inferred types, parameter names — on and off for every pane at once, dropping the hints it had so each pane asks again on its next idle frame. It flips `editor.inlay_hints` in memory only; nothing is written, so the next launch reads the config again. A language whose server sends no hints looks the same either way.",
        .links = &.{ .{ .command = .{ .id = .@"lsp.inlay_hints_toggle", .label = "Toggle them" } }, .{ .command = .{ .id = .@"lsp.hover", .label = "Hover docs instead" } } },
    } },
    // Shared with the Language chip's menu, the same command in both.
    .{ .label = "Format file", .entry = .{
        .title = "Format file",
        .body = "Formats the buffer with the tool `.formatters` names for the extension when there is one (or a builtin tool whose project config is present and which is installed), else with the language server, else with the builtin tool, splicing the result back as one undo step with the cursor where it was. A tool that wants the file on disk is handed it, so that path does write. `editor.format_on_save` does this on every save instead; with neither a server nor a tool for the extension it toasts.",
        .keys = &.{.{ .command = .@"lsp.format", .label = "Format the document" }},
        .links = &.{ .{ .command = .{ .id = .@"lsp.format", .label = "Format it" } }, .{ .settings = .{ .row = copy.settingsRow("editor.format_on_save"), .label = "Format on save" } }, .{ .command = .{ .id = .@"lsp.status", .label = "Which servers are running" } } },
    } },
    .{ .menu = "LSP", .label = "Install ", .prefix = true, .kind = .lsp_install, .entry = .{
        .title = "Install the missing server",
        .body = "Runs the install command for the binary this row names — the one the row above it copies — in a terminal pane in the workspace, so the output is on screen. A tool mnml ships a recipe for asks first, with *Copy command* as the other answer. Once it is on PATH the server starts on the next file of that language you open.",
        .links = &.{ .{ .command = .{ .id = .@"lsp.status", .label = "Which servers are running" } }, .{ .settings = .{ .row = copy.settingsRow("editor.lsp_missing_defaults"), .label = "Missing-server notices" } }, ask },
    } },
    .{ .menu = "LSP", .label = "\u{2717} ", .prefix = true, .kind = .copy_text, .entry = missingServer("\u{2717}", "The \u{2717} is the Nerd Font mark, which is what the menu paints by default.") },
    .{ .menu = "LSP", .label = "x ", .prefix = true, .kind = .copy_text, .entry = missingServer("x", "The plain x is what `ui.ascii_icons` paints in place of the glyph form.") },

    // ── the workspace chip: its title is the workspace's own name, so
    // these rows carry no menu ──
    .{ .label = "Worktrees\u{2026}", .entry = .{
        .title = "Worktrees\u{2026}",
        .body = "Lists this repository's git worktrees — the main tree and each one added beside it — as a picker, with the branch every tree carries. The pick toasts the worktree's path; opening a shell in it is the part still to land, so read the row as the map rather than the door. A repository with no extra trees lists only the main one.",
        .links = &.{ .{ .command = .{ .id = .@"git.worktrees", .label = "List them" } }, .{ .command = .{ .id = .@"ai.new_session_worktree", .label = "A session in a new worktree" } }, copy.docsSection("Session worktrees") },
    } },
    .{ .label = "Rescan repos", .entry = .{
        .title = "Rescan repos",
        .body = "Walks the workspace for git repositories again, toasts how many it found and asks the active one for a status — the row for after cloning or adding a repo, since discovery otherwise happens once a session. The repo rows at the top of this menu appear only once more than one is found. It is a scan of the disk, not of any remote.",
        .links = &.{ .{ .command = .{ .id = .@"git.refresh_repos", .label = "Rescan now" } }, .{ .command = .{ .id = .@"git.switch_repo", .label = "Pick a repo" } }, .{ .command = .{ .id = .@"git.refresh", .label = "Refresh the status" } } },
    } },
    .{ .label = "Switch repo\u{2026}", .entry = .{
        .title = "Switch repo\u{2026}",
        .body = "Opens a picker over every repository discovered under this workspace and makes the pick the active one — the branch chip, the status pane, the graph and every git verb follow it at once. The row is in the menu only in a workspace with more than one repository. *Rescan repos* finds one that was added since launch.",
        .links = &.{ .{ .command = .{ .id = .@"git.switch_repo", .label = "Pick one" } }, .{ .command = .{ .id = .@"git.refresh_repos", .label = "Rescan first" } }, .{ .command = .{ .id = .@"git.next_repo", .label = "Just cycle" } } },
    } },
    .{ .label = "Next repo", .entry = repoStep("Next", "next", "the end back to the first", .@"git.next_repo", .@"git.prev_repo") },
    .{ .label = "Previous repo", .entry = repoStep("Previous", "previous", "the first back to the last", .@"git.prev_repo", .@"git.next_repo") },

    // ── the test chip: `Tests` ──
    .{ .menu = "Tests", .label = "Run all", .entry = testScope("Run all", "the whole suite", "A workspace with none of those manifests toasts instead of running anything.", .@"test.run_all") },
    .{ .menu = "Tests", .label = "Run file", .entry = testScope("Run file", "the tests of the file in the active editor", "The file has to be saved — an unsaved scratch buffer has no path to hand the tool.", .@"test.run_file") },
    .{ .menu = "Tests", .label = "Run at cursor", .entry = testScope("Run at cursor", "the one test the cursor is inside", "The name is read from the nearest test above the cursor; with none above it, it toasts.", .@"test.run_at_cursor") },
    .{ .menu = "Tests", .label = "Re-run failed", .entry = .{
        .title = "Re-run failed",
        .body = "Runs the failures again rather than the whole suite: pytest, dotnet, zig and vitest re-run the results pane's failed tests by name (pytest falls back to `--lf` before a run has finished), and cargo, go and plain npm re-run the last command this menu ran, since their tools have no last-failed mode. With nothing run yet this session it toasts.",
        .links = &.{ .{ .command = .{ .id = .@"test.rerun_failed", .label = "Re-run them" } }, .{ .command = .{ .id = .@"test.run_all", .label = "The whole suite" } }, .{ .command = .{ .id = .@"test.run_file", .label = "This file" } } },
    } },

    // ── the stress meter: `Stress meter` ──
    .{ .menu = "Stress meter", .label = "Toast the numbers", .entry = .{
        .title = "Toast the numbers",
        .body = "Reads the frame-time window out as a toast — p50, p95, max and how many frames are in it — the figures the four-block bar is drawn from. The window is the last 120 renders, so it answers what the app feels like now rather than since launch. With nothing sampled yet it says so.",
        .links = &.{ .{ .command = .{ .id = .@"perf.toast_stress", .label = "Read them out" } }, .{ .command = .{ .id = .@"perf.copy_stress", .label = "Copy them instead" } }, .{ .command = .{ .id = .@"perf.reset_stress", .label = "Start a fresh window" } } },
    } },
    .{ .menu = "Stress meter", .label = "Copy summary", .entry = .{
        .title = "Copy summary",
        .body = "Puts that same one-line summary — p50, p95, max, n — on the clipboard rather than on screen, for pasting into an issue. It is the window as it stands at the click, so reset it first to time one thing in particular. Nothing is copied while no frame has been sampled.",
        .links = &.{ .{ .command = .{ .id = .@"perf.copy_stress", .label = "Copy it" } }, .{ .command = .{ .id = .@"perf.reset_stress", .label = "Reset first" } }, .{ .command = .{ .id = .@"perf.toast_stress", .label = "Just read it out" } } },
    } },
    .{ .menu = "Stress meter", .label = "Reset", .entry = .{
        .title = "Reset",
        .body = "Empties the rolling window so the next renders start a fresh measurement — what to do before opening the big file or the pane you mean to time. The bar goes blank until the first frames land in it. Nothing is recorded anywhere: the window only ever lives in memory.",
        .links = &.{ .{ .command = .{ .id = .@"perf.reset_stress", .label = "Reset it" } }, .{ .command = .{ .id = .@"perf.toast_stress", .label = "Read the window" } } },
    } },
    .{ .menu = "Stress meter", .label = "Hide the meter", .entry = .{
        .title = "Hide the meter",
        .body = "Takes the bar out of the statusline for this session — `ui.stress_meter` is flipped in memory and nothing is written, so the next launch reads the config again and the bar is back. Settings → UI is where it goes off for good. Frames keep being sampled either way, and the palette's rows still read them out.",
        .links = &.{ .{ .command = .{ .id = .@"perf.hide_stress", .label = "Hide it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.stress_meter"), .label = "Stress meter in Settings" } }, .{ .command = .{ .id = .@"perf.toast_stress", .label = "Read the numbers" } } },
    } },

    // ── the AI ghost-text chip: `AI ghost-text` ──
    .{ .menu = "AI ghost-text", .label = "Pick the backend\u{2026}", .entry = .{
        .title = "Pick the backend\u{2026}",
        .body = "Opens the picker for what writes the inline suggestions: the Claude Code subscription, the Claude API with `$ANTHROPIC_API_KEY`, a GitHub Copilot seat, or the embedded local model, which is not in this release. The one in use carries a ●, and the last row turns ghost text off. The pick is written to `ai.suggest_backend` in the home config.",
        .links = &.{ .{ .command = .{ .id = .@"ai.setup_suggestions", .label = "Pick one" } }, .{ .settings = .{ .row = copy.settingsRow("ai.suggest_backend"), .label = "Backend in Settings" } }, .{ .settings = .{ .row = copy.settingsRow("ai.inline_suggestions"), .label = "Inline suggestions" } } },
    } },
    .{ .menu = "AI ghost-text", .label = "Suggestion stats", .entry = .{
        .title = "Suggestion stats",
        .body = "Toasts this session's ghost-text figures — how many suggestions were shown, how many were accepted, and the backend's latency. A session that asked and got nothing but timeouts reports that, rather than the same silence as one that never asked. The counters start at launch and are not stored anywhere.",
        .links = &.{ .{ .command = .{ .id = .@"ai.suggestion_stats", .label = "Read them out" } }, .{ .command = .{ .id = .@"ai.setup_suggestions", .label = "Change the backend" } } },
    } },
    // Shared with the bell's menu, the same command in both.
    .{ .label = "Show messages", .entry = .{
        .title = "Show messages",
        .body = "Opens the toast history newest first as a searchable picker — every toast this session raised, with its age — and Enter raises one again, so a message that expired before it could be read comes back. Opening it marks the log read, which clears the bell's warning and error counts. The log rides in the session file, so a warning survives a restart.",
        .links = &.{ .{ .command = .{ .id = .@"messages.show", .label = "Open the log" } }, .{ .command = .{ .id = .@"messages.clear", .label = "Clear the history" } } },
    } },
    .{ .menu = "AI ghost-text", .label = "Turn ghost text off", .entry = .{
        .title = "Turn ghost text off",
        .body = "Flips `ai.inline_suggestions` and writes it to the home config; off, the request in flight is cancelled and the suggestion sitting in the buffer goes. The label reads the same either way — the tick is what says whether ghost text is on — so this row turns it back on too. Turning it on with no backend picked opens the backend picker instead.",
        .links = &.{ .{ .command = .{ .id = .@"ai.toggle_inline_suggestions", .label = "Toggle it" } }, .{ .settings = .{ .row = copy.settingsRow("ai.inline_suggestions"), .label = "Inline suggestions in Settings" } }, .{ .command = .{ .id = .@"ai.setup_suggestions", .label = "Pick a backend" } } },
    } },

    // ── the find chip: `Find` ──
    .{ .menu = "Find", .label = "Next match", .entry = findStep("Next match", "next", "from the end of the buffer back to the top", .@"find.next", .@"find.prev") },
    .{ .menu = "Find", .label = "Previous match", .entry = findStep("Previous match", "previous", "from the top back to the end", .@"find.prev", .@"find.next") },
    .{ .menu = "Find", .label = "Clear highlight", .entry = .{
        .title = "Clear highlight",
        .body = "Drops the match highlights and this chip's counter for the active editor, leaving the cursor and the text as they are; under vim the query goes with them, so *Next match* has nothing to step through until a new search; the standard profile's *Next match* takes the last query back. Esc in the find bar is the other half of the pair — it throws the live query away and puts back the search that was highlighted before the bar opened, cursor included.",
        .links = &.{ .{ .command = .{ .id = .@"find.clear", .label = "Clear them" } }, .{ .command = .{ .id = .@"find.find", .label = "Search again" } } },
    } },
    // The Edit menu has its own `Find…`; this one is the chip's.
    .{ .label = "Find\u{2026}", .entry = .{
        .title = "Find\u{2026}",
        .body = "Opens the find bar under the pane with an empty field — ↑ recalls the last queries — and the counter beside this chip starts again as you type. It searches the ACTIVE pane — a request pane's response has its own bar over the same keys — and never more than one file at a time. Searching the whole workspace is the SEARCH section's job.",
        .keys = &.{.{ .command = .@"find.find", .label = "Find in this pane" }},
        .links = &.{ .{ .command = .{ .id = .@"find.find", .label = "Open the bar" } }, .{ .command = .{ .id = .@"find.grep", .label = "Search the workspace" } }, .{ .command = .{ .id = .@"find.replace", .label = "Replace the matches" } } },
    } },

    // ── the diagnostics chip: `Diagnostics` ──
    .{ .menu = "Diagnostics", .label = "Diagnostics panel", .entry = .{
        .title = "Diagnostics panel",
        .body = "Opens the problems panel in the dock (the bottom one by default) — every diagnostic the servers have reported, by file, Enter opening the file at the line. This chip counts the active file's errors and warnings; the panel lists every file's, through its severity filter. It is the panel the LSP chip's *Diagnostics list* opens as well.",
        .keys = &.{.{ .command = .@"lsp.diagnostics", .label = "The problems panel" }},
        .links = &.{ .{ .command = .{ .id = .@"lsp.diagnostics", .label = "Open it" } }, .{ .command = .{ .id = .@"lsp.diagnostics_filter", .label = "Cycle the filter" } }, .{ .command = .{ .id = .@"lsp.code_action", .label = "Fix the one at the cursor" } } },
    } },
    .{ .menu = "Diagnostics", .label = "Next diagnostic", .entry = diagStep("Next diagnostic", "next", "from the last back to the first", .@"lsp.next_diagnostic", .@"lsp.prev_diagnostic") },
    .{ .menu = "Diagnostics", .label = "Previous diagnostic", .entry = diagStep("Previous diagnostic", "previous", "from the first back to the last", .@"lsp.prev_diagnostic", .@"lsp.next_diagnostic") },
    .{ .menu = "Diagnostics", .label = "Cycle severity filter", .entry = .{
        .title = "Cycle severity filter",
        .body = "Steps the problems panel's severity filter — All, then warnings and above, then errors only — and toasts where it landed. It changes what the panel lists — this chip's counts and the two jumps take every diagnostic regardless — never what the servers actually reported. The panel's cursor goes back to its first row on every step.",
        .links = &.{ .{ .command = .{ .id = .@"lsp.diagnostics_filter", .label = "Cycle it" } }, .{ .command = .{ .id = .@"lsp.diagnostics", .label = "The problems panel" } } },
    } },

    // ── the coverage chip: `Coverage chip`. `Both` must name its own
    // command — the Claude chip has a `Both` too. ──
    .{ .menu = "Coverage chip", .label = "Feature coverage (F)", .command = .@"coverage.chip_show_feature", .entry = coverageMode("Feature coverage (F)", "the feature number and its move over seven days, `F 83% \u{25B2}1.0`", .@"coverage.chip_show_feature") },
    .{ .menu = "Coverage chip", .label = "Code coverage (C)", .command = .@"coverage.chip_show_code", .entry = coverageMode("Code coverage (C)", "the Istanbul line number and its move since the previous commit, `C 71% \u{00B1}0.0`", .@"coverage.chip_show_code") },
    .{ .menu = "Coverage chip", .label = "Both", .command = .@"coverage.chip_show_both", .entry = coverageMode("Both", "the two numbers side by side, the feature one first", .@"coverage.chip_show_both") },
    .{ .menu = "Coverage chip", .label = "Ticker (F \u{21C4} C)", .command = .@"coverage.chip_show_ticker", .entry = coverageMode("Ticker (F \u{21C4} C)", "one number at a time, swapping every four seconds — for a statusline with no room for both", .@"coverage.chip_show_ticker") },

    // ── the enclosing-symbol chip: `Symbol` ──
    .{ .menu = "Symbol", .label = "Symbols in file\u{2026}", .entry = .{
        .title = "Symbols in file\u{2026}",
        .body = "The list this chip's label comes from: the server's symbols for this file as a fuzzy picker, Enter jumping to one with the preview column showing the definition. The chip names whichever of them the cursor is inside, so the picker is the way out of a long function to its neighbours. The LSP chip's menu has the same row without the ellipsis.",
        .keys = &.{.{ .command = .@"lsp.symbols", .label = "Symbols in this file" }},
        .links = &.{ .{ .command = .{ .id = .@"lsp.symbols", .label = "List them" } }, .{ .command = .{ .id = .@"outline.show", .label = "Keep the list open" } }, .{ .command = .{ .id = .@"lsp.workspace_symbols", .label = "The whole project" } } },
    } },
    .{ .menu = "Symbol", .label = "Symbols in workspace\u{2026}", .entry = .{
        .title = "Symbols in workspace\u{2026}",
        .body = "Leaves this file behind: it asks for a query, sends it to the server as one request, and opens the matches from anywhere in the project as a picker, Enter opening the file at the one you pick. It is how to get from the symbol the chip names to the one that calls it. A server that is still indexing answers with less than it will in a minute.",
        .links = &.{ .{ .command = .{ .id = .@"lsp.workspace_symbols", .label = "Search the project" } }, .{ .command = .{ .id = .@"lsp.references", .label = "Who calls this one" } } },
    } },

    // ── the language chip: `Language` ──
    .{ .menu = "Language", .label = "Copy language name (", .prefix = true, .kind = .copy_text, .entry = .{
        .title = "Copy the language name",
        .body = "Copies the language mnml settled on for this buffer — the name in the brackets, `zig`, `typescript` — to the clipboard; a buffer it could not place reads `—` and copies that. The language is read off the extension and the first line, and it is what picks the syntax rules and which server attaches. The rows below are that server's file-level verbs.",
        .links = &.{ .{ .command = .{ .id = .@"lsp.status", .label = "Which servers are running" } }, .{ .command = .{ .id = .@"lsp.symbols", .label = "This file's symbols" } } },
    } },

    // ── the clock chip: `Clock` ──
    .{ .menu = "Clock", .label = "Local time", .entry = clockMode("Local time", "your machine's local time, `HH:MM`", .@"clock.local") },
    .{ .menu = "Clock", .label = "UTC", .entry = clockMode("UTC", "UTC with a `Z` after it, `HH:MMZ`", .@"clock.utc") },
    .{ .menu = "Clock", .label = "Hide the clock", .entry = .{
        .title = "Hide the clock",
        .body = "Takes the clock out of the statusline and writes `ui.clock = false` to the home config, so it stays gone on the next launch. There is no chip left to bring it back from — Settings → UI, or the `clock.local` command, is the way back. It comes back as the local clock; a UTC pick is not kept.",
        .links = &.{ .{ .command = .{ .id = .@"clock.local", .label = "Show it again" } }, .{ .settings = .{ .row = copy.settingsRow("ui.clock"), .label = "Clock in Settings" } } },
    } },

    // ── the WRAP chip: its title says the state, so these rows carry
    // no menu ──
    .{ .label = "Enable wrap", .entry = wrapToggle(true) },
    .{ .label = "Disable wrap", .entry = wrapToggle(false) },
    .{ .label = "Editor settings\u{2026}", .entry = .{
        .title = "Editor settings\u{2026}",
        .body = "Opens the Settings overlay, where wrap sits in the UI section and the editor's rows — tab width, format on save, the clipboard — in the Editor one, as a scrollable list: ←→ changes a value, Enter saves and closes, Esc reverts what this visit changed. Each row writes to its own file — wrap, tab width and format-on-save to this workspace's `.mnml/config.zon`, the home-scoped rows to the home config — where the row above is this pane's alone.",
        .keys = &.{.{ .command = .@"view.settings", .label = "Settings" }},
        .links = &.{ .{ .command = .{ .id = .@"view.settings", .label = "Open Settings" } }, .{ .settings = .{ .row = copy.settingsRow("ui.wrap"), .label = "Wrap in Settings" } }, copy.docsSection("The settings overlay") },
    } },

    // ── the Sel chip: `Selection` ──
    .{ .menu = "Selection", .label = "Copy selection", .entry = .{
        .title = "Copy selection",
        .body = "Copies the selected text as it is — the characters and lines this chip counts are exactly what lands on the clipboard. With nothing selected it takes the cursor's whole line, its newline included. `editor.clipboard` decides whether that goes to the system clipboard or stays in mnml's own register.",
        .links = &.{ .{ .command = .{ .id = .@"editor.copy", .label = "Copy it" } }, .{ .command = .{ .id = .@"editor.paste", .label = "Paste it somewhere" } }, .{ .settings = .{ .row = copy.settingsRow("editor.clipboard"), .label = "Clipboard in Settings" } } },
    } },
    .{ .menu = "Selection", .label = "Cut selection", .entry = .{
        .title = "Cut selection",
        .body = "Takes the same text but removes it from the buffer, as one undo step — an undo puts the text back where it was. With nothing selected it cuts the cursor's whole line. In the vim profile the register holds what it took, so `p` pastes it straight back.",
        .links = &.{ .{ .command = .{ .id = .@"editor.cut", .label = "Cut it" } }, .{ .command = .{ .id = .@"editor.paste", .label = "Paste it back" } }, .{ .settings = .{ .row = copy.settingsRow("editor.clipboard"), .label = "Clipboard in Settings" } } },
    } },

    // ── the Ln/Col chip: `Cursor` ──
    .{ .label = "Go to line\u{2026}", .entry = .{
        .title = "Go to line\u{2026}",
        .body = "Asks for a line and puts the cursor at its first character, scrolled into view — the chip beside it is where the cursor is now, and this is how to send it somewhere else. `12:4` lands on a column too, and a number past the end of the buffer lands on the last line. It moves within the active editor only.",
        .keys = &.{.{ .command = .@"editor.goto_line", .label = "Go to line" }},
        .links = &.{ .{ .command = .{ .id = .@"editor.goto_line", .label = "Go to a line" } }, .{ .command = .{ .id = .@"picker.marks", .label = "Jump to a mark" } } },
    } },
    .{ .menu = "Cursor", .label = "Copy position (", .prefix = true, .kind = .copy_text, .entry = .{
        .title = "Copy the cursor position",
        .body = "Copies the `line:column` in the brackets to the clipboard — both one-based, the spelling *Go to line…* above takes back — for a review comment or a stack trace. Columns are counted in characters, so a tab is one column and so is a wide glyph; a byte offset this is not.",
        .links = &.{ .{ .command = .{ .id = .@"editor.goto_line", .label = "Go back to a position" } }, .{ .command = .{ .id = .@"file.copy_path", .label = "Copy the file's path" } } },
    } },

    // ── the bell: `Messages` (its `Show messages` is the shared row
    // written above) ──
    .{ .label = "Clear history", .command = .@"messages.clear", .entry = .{
        .title = "Clear history",
        .body = "Empties the toast log and toasts how many entries went, which clears the bell's unread warning and error counts with them. They are gone: the log is not written anywhere else, and the session file loses them on its next save. Read them through *Show messages* first if a warning still matters.",
        .links = &.{ .{ .command = .{ .id = .@"messages.clear", .label = "Clear it" } }, .{ .command = .{ .id = .@"messages.show", .label = "Read them first" } } },
    } },

    // ── the transfer chip: `Transfers` ──
    .{ .menu = "Transfers", .label = "Cancel all transfers", .entry = .{
        .title = "Cancel all transfers",
        .body = "Asks every running copy or move to stop. The flag is checked between files, so one enormous file finishes rather than leaving a truncated destination that looks complete, and the rest of the queue stops. What the cancelled transfer created is removed again, a file that was already there is never touched, and a move keeps its source. With nothing running it toasts.",
        .links = &.{ .{ .command = .{ .id = .@"transfer.cancel_all", .label = "Cancel them" } }, ask },
    } },

    // ── the size chip: `Size` ──
    .{ .menu = "Size", .label = "Copy size (", .prefix = true, .kind = .copy_text, .entry = .{
        .title = "Copy the size",
        .body = "Copies the byte count alone — the number in the brackets, without the `bytes` or the line count beside it. It is the text as the editor holds it, so an unsaved change is counted and the file on disk may still be a different size. Save first when the number has to match what git sees.",
        .links = &.{.{ .command = .{ .id = .@"file.copy_path", .label = "Copy the path instead" } }},
    } },

    // ── the PR chip: its title is `PR #<n>`, so these rows carry no
    // menu ──
    .{ .label = "Copy number (", .prefix = true, .kind = .copy_text, .entry = .{
        .title = "Copy the PR number",
        .body = "Copies the pull request's number on its own — `2317`, without the `#` the label shows — for a commit message, a branch name or a `gh` command. It is the PR the chip found for the checked-out branch, not whatever is open in a browser. *Copy URL* above is the whole link instead.",
        .links = &.{ .{ .command = .{ .id = .@"git.copy_current_branch", .label = "Copy the branch name" } }, .{ .command = .{ .id = .@"git.status_pane", .label = "What is uncommitted" } } },
    } },
    .{ .label = "Refresh", .command = .@"pr.refresh", .entry = .{
        .title = "Refresh the PR",
        .body = "Would ask the forge about this branch's pull request again, for when the chip is behind a review that has just landed. The cross-host PR picker is cut from this build, so the row toasts the reason and where it is recorded — it comes back with the Zig forge integrations — and the chip keeps whatever it last had.",
        .links = &.{ .{ .command = .{ .id = .@"pr.refresh", .label = "Try it" } }, .{ .command = .{ .id = .@"integrations.show_installed", .label = "The installed integrations" } }, ask },
    } },

    // ── an integration's own statusline chip: the menu's title is the
    // segment's id, so these rows carry no menu ──
    .{ .label = "Refresh now", .command = .@"integrations.poll_now", .entry = .{
        .title = "Refresh now",
        .body = "Tells every integration that declares a values source to poll now instead of waiting out its interval — not this chip alone, so a statusline full of them refreshes together and the toast says how many were told. The row is here only when this chip's integration actually polls; one whose value is pushed over the IPC channel has nothing to ask for.",
        .links = &.{ .{ .command = .{ .id = .@"integrations.poll_now", .label = "Poll now" } }, .{ .command = .{ .id = .@"integrations.show_installed", .label = "The installed integrations" } }, copy.docsSection("Launchers and integration manifests") },
    } },
    .{ .label = "Open", .kind = .dyn, .entry = .{
        .title = "Open",
        .body = "Runs whatever this chip's manifest names as its click command — the pane, the view or the ex line the integration meant its number to lead to. A left click on the chip does the same; the row exists so the right button can reach it without leaving the menu. A chip whose manifest names no click command has no row here.",
        .links = &.{ .{ .command = .{ .id = .@"integrations.show_installed", .label = "What it belongs to" } }, copy.docsSection("Launchers and integration manifests") },
    } },
    .{ .label = "Requests\u{2026}", .kind = .requests_for, .entry = .{
        .title = "Requests\u{2026}",
        .body = "Opens the REQUESTS view filtered to the service behind this chip — every HTTP call the integration made, with its status and how long it took — which is where a number that is stale, slow or wrong gets explained. The filter is the chip id's family, so `jira_work.assigned` shows every `jira` call rather than this chip's alone.",
        .links = &.{ .{ .command = .{ .id = .@"integrations.show_installed", .label = "The installed integrations" } }, copy.docsSection("What integrations see") },
    } },
    .{ .label = "Integrations\u{2026}", .entry = .{
        .title = "Integrations\u{2026}",
        .body = "Opens the Integrations view on its Installed tab: every manifest mnml loaded, with the commands and chips each declares and where it came from. It is the place to check that the chip's integration is the version you think it is, and its rows lead to the manifest file itself.",
        .links = &.{ .{ .command = .{ .id = .@"integrations.show_installed", .label = "Show them" } }, copy.docsSection("Launchers and integration manifests") },
    } },
};

// ─── the templates ──────────────────────────────────────────────────────

/// The mixr menu's three player rows: which player the idle chip wears
/// and starts.
fn preferred(comptime label: []const u8, comptime who: []const u8, comptime note: []const u8, comptime id: command.CommandId) Entry {
    return .{
        .title = label,
        .body = "Makes " ++ who ++ " the player the now-playing chip wears at rest and starts on a click, and writes `ui.preferred_music_app` to the home config so it holds in every workspace. Whatever is actually PLAYING still wins the chip — the preference only decides the idle form. " ++ note,
        .links = &.{ .{ .command = .{ .id = id, .label = "Prefer " ++ who } }, .{ .command = .{ .id = .@"mixr.copy_track", .label = "Copy the playing track" } } },
    };
}

/// The mixr menu's four `Show:` rows — one view of a running mixr each.
fn mixrView(comptime label: []const u8, comptime what: []const u8, comptime id: command.CommandId) Entry {
    return .{
        .title = label,
        .body = "Opens mixr on its " ++ what ++ ". The four *Show:* rows are one call each into a running mixr, and those calls are cut from this build, so each toasts the reason and names where the cut is recorded rather than switching a view. Nothing about the statusline chip changes either way.",
        .links = &.{ .{ .command = .{ .id = id, .label = "Try it" } }, .{ .command = .{ .id = .@"mixr.show", .label = "Open mixr" } } },
    };
}

/// The LSP chip's `✗ <binary> — <hint>` row and its ascii twin: the
/// row IS the hint, and a click copies it.
fn missingServer(comptime mark: []const u8, comptime form: []const u8) Entry {
    return .{
        .title = mark ++ " <server> — how to install it",
        .body = "A language server mnml wanted for a file in this workspace and could not find on PATH: the row names the binary and the command that installs it, and a click COPIES that command rather than running it — *Install …* under it is the row that runs it. " ++ form ++ " `editor.lsp_missing_defaults` decides whether a server from the shipped table is announced at all.",
        .links = &.{ .{ .command = .{ .id = .@"lsp.status", .label = "Which servers are running" } }, .{ .settings = .{ .row = copy.settingsRow("editor.lsp_missing_defaults"), .label = "Missing-server notices" } }, .{ .settings = .{ .row = copy.settingsRow("ui.ascii_icons"), .label = "ASCII icons" } } },
    };
}

/// The workspace chip's `Next repo` / `Previous repo`.
fn repoStep(comptime which: []const u8, comptime dir: []const u8, comptime wrap: []const u8, comptime id: command.CommandId, comptime back: command.CommandId) Entry {
    return .{
        .title = which ++ " repo",
        .body = "Makes the " ++ dir ++ " repository in discovery order the active one, wrapping " ++ wrap ++ " — the way round a multi-repo workspace without the picker. Everything git follows at once: this chip, the branch chip, the status pane, the graph. With only one repo found it toasts that there is only one — the row is not in the menu then either.",
        .keys = &.{ .{ .command = id, .label = which ++ " repo" }, .{ .command = back, .label = "The other way" } },
        .links = &.{ .{ .command = .{ .id = id, .label = "Go " ++ dir } }, .{ .command = .{ .id = .@"git.switch_repo", .label = "Pick one instead" } } },
    };
}

/// The test chip's three `Run …` rows: the same tool, a different
/// scope.
fn testScope(comptime label: []const u8, comptime what: []const u8, comptime caveat: []const u8, comptime id: command.CommandId) Entry {
    return .{
        .title = label,
        .body = "Runs " ++ what ++ " with the project's own tool, whichever manifest is nearest the active file — cargo, npm or go in a terminal pane below the active one; pytest, dotnet, zig and vitest in the test-results pane. " ++ caveat ++ " The pane keeps the output, and closing it ends the run.",
        .links = &.{ .{ .command = .{ .id = id, .label = "Run it" } }, .{ .command = .{ .id = .@"test.rerun_failed", .label = "Re-run the failures" } } },
    };
}

/// The find chip's two steps.
fn findStep(comptime label: []const u8, comptime dir: []const u8, comptime wrap: []const u8, comptime id: command.CommandId, comptime back: command.CommandId) Entry {
    return .{
        .title = label,
        .body = "Moves the cursor to the " ++ dir ++ " match of the query the find bar last ran, wrapping " ++ wrap ++ "; the counter on this chip follows it — `3/12`. The query and its highlights are untouched, so stepping can go on as long as you like. With no search yet this session it toasts.",
        .keys = &.{ .{ .command = id, .label = label }, .{ .command = back, .label = "The other way" } },
        .links = &.{ .{ .command = .{ .id = id, .label = "Step " ++ dir } }, .{ .command = .{ .id = .@"find.find", .label = "Start a search" } } },
    };
}

/// The diagnostics chip's two jumps.
fn diagStep(comptime label: []const u8, comptime dir: []const u8, comptime wrap: []const u8, comptime id: command.CommandId, comptime back: command.CommandId) Entry {
    return .{
        .title = label,
        .body = "Jumps the cursor to the " ++ dir ++ " diagnostic in this buffer, wrapping " ++ wrap ++ ", and shows its message where it lands. The filter the chip cycles does not apply here — the jumps step every diagnostic in the file, whatever the panel is listing. A buffer with none toasts and the cursor stays put.",
        .keys = &.{ .{ .command = id, .label = label }, .{ .command = back, .label = "The other way" } },
        .links = &.{ .{ .command = .{ .id = id, .label = "Jump " ++ dir } }, .{ .command = .{ .id = .@"lsp.diagnostics", .label = "The problems panel" } }, .{ .command = .{ .id = .@"lsp.code_action", .label = "Fix the one at the cursor" } } },
    };
}

/// The coverage chip's four modes.
fn coverageMode(comptime label: []const u8, comptime what: []const u8, comptime id: command.CommandId) Entry {
    return .{
        .title = label,
        .body = "Sets what the coverage chip paints — " ++ what ++ " — and writes `ui.coverage_chip_mode` to the home config, so it holds in every workspace. Both numbers are read from the `trends.json` files under `$MNML_SHARED_STATE_DIR` (`feature-coverage/_trends/` and `code-coverage/_trends/`), at most every five minutes; one whose file is not there simply has no figure, and with neither the chip is not painted at all. A click on the chip toasts both whatever the mode.",
        .links = &.{ .{ .command = .{ .id = id, .label = "Show this" } }, .{ .command = .{ .id = .@"coverage.toast", .label = "Toast both numbers" } }, .{ .settings = .{ .row = copy.settingsRow("ui.coverage_chip_mode"), .label = "Coverage chip in Settings" } } },
    };
}

/// The clock chip's two modes.
fn clockMode(comptime label: []const u8, comptime what: []const u8, comptime id: command.CommandId) Entry {
    return .{
        .title = label,
        .body = "Paints the chip beside the bell as " ++ what ++ ", and writes `ui.clock` to the home config as it goes — that key only says whether the clock is shown, so the mode itself is this session's, and a config reload that keeps the clock on keeps the mode with it. The tick marks the one in use.",
        .links = &.{ .{ .command = .{ .id = id, .label = "Use it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.clock"), .label = "Clock in Settings" } } },
    };
}

/// The WRAP chip's one row, whichever way round it reads.
fn wrapToggle(comptime on: bool) Entry {
    return .{
        .title = if (on) "Enable wrap" else "Disable wrap",
        .body = if (on)
            "Wraps the active editor's long lines at the pane's width instead of scrolling sideways; the cursor keys then walk by screen line. It is an override on THIS pane, held for as long as the pane lives — `ui.wrap` is the default every new pane starts from, and the chip's title says which way round this one is."
        else
            "Stops the active editor wrapping: long lines run off the right edge and the horizontal scroll comes back, which is what a wide table or a minified file usually wants. The flip is this pane's own override rather than the config, so a new pane still starts from `ui.wrap`. With no editor active at all the row flips that default instead.",
        .links = &.{ .{ .command = .{ .id = .@"view.toggle_wrap", .label = if (on) "Turn it on" else "Turn it off" } }, .{ .settings = .{ .row = copy.settingsRow("ui.wrap"), .label = "Wrap in Settings" } }, copy.docsSection("The settings overlay") },
    };
}

/// The theme pill's first row — `Toggle → dark`, `Toggle (primary ⇄
/// alt)` or `Toggle (set ui.theme_toggle first)` — the words follow
/// the label's state.
pub fn themeToggle(app: *App, arena: Allocator, label: []const u8) Allocator.Error!?Entry {
    const cur = app.theme.name;
    if (app.cfg.ui.theme_toggle) |alt| {
        if (!std.ascii.eqlIgnoreCase(alt, cur)) return .{
            .title = try arena.dupe(u8, label),
            .body = try std.fmt.allocPrint(arena, "Swaps the theme to `{s}` — the other half of the pair `ui.theme` and `ui.theme_toggle` name, `{s}` being the one painted now — for this session only — nothing is written, so the next launch paints `ui.theme` again, and *Pick theme…* is the row that writes a choice home. The row then reads the other way round. The pill's left click is this same swap; *Auto* below follows the OS appearance instead, re-checked every fifteen seconds.", .{ alt, cur }),
            .keys = &.{.{ .command = .@"theme.toggle", .label = "Toggle the theme" }},
            .links = &.{ .{ .command = .{ .id = .@"theme.toggle", .label = "Swap now" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.theme"), .label = "Theme in Settings" } }, comptime copy.docsSection("Themes") },
        };
        return .{
            .title = try arena.dupe(u8, label),
            .body = try std.fmt.allocPrint(arena, "The theme painted now, `{s}`, is the `ui.theme_toggle` half of the pair, so the swap goes back to the primary `ui.theme`; it holds for this session only, nothing being written either way. The pill's left click is the same swap, and *Pick theme…* below is the way to a third theme.", .{cur}),
            .keys = &.{.{ .command = .@"theme.toggle", .label = "Toggle the theme" }},
            .links = &.{ .{ .command = .{ .id = .@"theme.toggle", .label = "Swap back" } }, .{ .command = .{ .id = .@"theme.pick", .label = "Pick a theme" } }, comptime copy.docsSection("Themes") },
        };
    }
    return .{
        .title = try arena.dupe(u8, label),
        .body = try std.fmt.allocPrint(arena, "`ui.theme_toggle` is not set, so this row and the pill's left click swap to the first bundled theme of the opposite kind — a light one from the dark `ui.theme = {s}`, and back — for this session only. Name the partner there in config.zon to pin which one, and the row reads *Toggle → <name>*. *Pick theme…* below changes the theme outright in the meantime.", .{cur}),
        .links = &.{ .{ .command = .{ .id = .@"file.open_settings", .label = "Open config.zon" } }, .{ .command = .{ .id = .@"theme.pick", .label = "Pick a theme instead" } }, comptime copy.docsSection("Themes") },
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn closeMenu(app: *App) void {
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
}

fn expectCurated(app: *App) !void {
    if (try menus.firstUncovered(app, app.frame.allocator())) |label| {
        std.debug.print("chips: no entry for `{s}` in menu `{s}`\n", .{ label, app.overlay.menu.title });
        return error.Uncovered;
    }
}

test "chips: the theme pill's Toggle row follows its label — no pair, a pair, on the alt half" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const a = app.frame.allocator();
    app.cfg.ui.theme_toggle = null;
    const none = (try themeToggle(&app, a, "Toggle (set ui.theme_toggle first)")).?;
    try t.expect(std.mem.indexOf(u8, none.body, "not set") != null);
    app.cfg.ui.theme_toggle = "solarized-light";
    const pair = (try themeToggle(&app, a, "Toggle → solarized-light")).?;
    try t.expect(std.mem.indexOf(u8, pair.body, "Swaps the theme to `solarized-light`") != null);
    app.cfg.ui.theme_toggle = app.theme.name;
    const back = (try themeToggle(&app, a, "Toggle (primary ⇄ alt)")).?;
    try t.expect(std.mem.indexOf(u8, back.body, "goes back to the primary") != null);
}

test "chips: every row of the statusline chips' menus resolves to a curated entry" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const cm = @import("../../context_menus.zig");
    const now_playing = @import("../../now_playing.zig");
    const ghost_chip = @import("../../ghost_chip.zig");
    const clock = @import("../../clock.zig");
    const coverage = @import("../../coverage.zig");
    // The size / position / language / wrap menus read the active editor.
    _ = try app.openScratch();

    try cm.openBranchMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try now_playing.openMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try cm.openTestMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try cm.openStressMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try ghost_chip.openMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try cm.openFindMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try cm.openDiagnosticsMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try coverage.openModeMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try cm.openLanguageMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try clock.openMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try cm.openWrapMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try cm.openSelMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try cm.openPositionMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try cm.openBellMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try cm.openTransferMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try cm.openSizeMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    // The LSP chip, the Symbol chip and the workspace chip carry rows
    // another module writes (`Find references` / `Rename symbol`,
    // `Outline`, the three workspace verbs), so the rows written here
    // are asserted one by one rather than through the whole menu.
    try t.expectEqualStrings("Status", menus.lookup("LSP", null, "Status").?.title);
    try t.expectEqualStrings("Symbols in file", menus.lookup("LSP", null, "Symbols in file").?.title);
    try t.expectEqualStrings("Symbols in workspace", menus.lookup("LSP", null, "Symbols in workspace").?.title);
    try t.expectEqualStrings("Diagnostics list", menus.lookup("LSP", null, "Diagnostics list").?.title);
    try t.expectEqualStrings("Code actions", menus.lookup("LSP", null, "Code actions").?.title);
    try t.expectEqualStrings("Toggle inlay hints", menus.lookup("LSP", null, "Toggle inlay hints").?.title);
    try t.expectEqualStrings("Format file", menus.lookup("LSP", null, "Format file").?.title);
    try t.expectEqualStrings("Symbols in file…", menus.lookup("Symbol", null, "Symbols in file…").?.title);
    try t.expectEqualStrings("Symbols in workspace…", menus.lookup("Symbol", null, "Symbols in workspace…").?.title);
    try t.expectEqualStrings("Worktrees…", menus.lookup("tmp", null, "Worktrees…").?.title);
    try t.expectEqualStrings("Rescan repos", menus.lookup("tmp", null, "Rescan repos").?.title);
    try t.expectEqualStrings("Switch repo…", menus.lookup("tmp", null, "Switch repo…").?.title);
    try t.expectEqualStrings("Next repo", menus.lookup("tmp", null, "Next repo").?.title);
    try t.expectEqualStrings("Previous repo", menus.lookup("tmp", null, "Previous repo").?.title);

    // The state rows of the LSP chip's menu: a prefix and an action
    // kind tell them from anything else labelled so.
    try t.expectEqualStrings("Install the missing server", menus.lookupItem("LSP", null, "Install zls…", .{ .lsp_install = "zls" }).?.title);
    try t.expect(std.mem.indexOf(u8, menus.lookupItem("LSP", null, "✗ zls — brew install zls", .{ .copy_text = "brew install zls" }).?.body, "Nerd Font mark") != null);
    try t.expect(std.mem.indexOf(u8, menus.lookupItem("LSP", null, "x zls — brew install zls", .{ .copy_text = "brew install zls" }).?.body, "ascii_icons") != null);

    // The PR chip and an integration's chip: neither menu opens
    // without state behind it, so their rows are asserted directly.
    try t.expectEqualStrings("Copy the PR number", menus.lookupItem("PR #17", null, "Copy number (#17)", .{ .copy_text = "17" }).?.title);
    try t.expectEqualStrings("Refresh the PR", menus.lookupItem("PR #17", null, "Refresh", .{ .command = .@"pr.refresh" }).?.title);
    try t.expectEqualStrings("Refresh now", menus.lookupItem("jira_work.assigned", null, "Refresh now", .{ .command = .@"integrations.poll_now" }).?.title);
    try t.expectEqualStrings("Open", menus.lookupItem("jira_work.assigned", null, "Open", .{ .dyn = 0 }).?.title);
    try t.expectEqualStrings("Requests…", menus.lookupItem("jira_work.assigned", null, "Requests…", .{ .requests_for = "jira" }).?.title);
    try t.expectEqualStrings("Integrations…", menus.lookup("jira_work.assigned", null, "Integrations…").?.title);

    // The qualifiers that matter: two menus share `Both`, several
    // share `Refresh`, and the copy rows are matched by their prefix.
    try t.expectEqualStrings("Both", menus.lookupItem("Coverage chip", null, "Both", .{ .command = .@"coverage.chip_show_both" }).?.title);
    try t.expectEqualStrings("Claude chip — Both", menus.lookupItem("Claude", null, "Both", .{ .command = .@"ai.chip_show_both" }).?.title);
    try t.expectEqualStrings("Refresh the git status", menus.lookupItem("Git", null, "Refresh", .{ .command = .@"git.refresh" }).?.title);
    try t.expectEqualStrings("Copy the cursor position", menus.lookup("Cursor", null, "Copy position (12:4)").?.title);
    try t.expectEqualStrings("Copy the size", menus.lookup("Size", null, "Copy size (91 bytes, 4 lines)").?.title);
}
