//! Hover help for the statusline: the five fixed segments, every
//! `SegId` the app paints, and a host's dynamic segment.
//!
//! Each entry names the state the chip is in — the branch and what
//! its dirty counts are, how many diagnostics, whether the ghost text
//! is failing — because the chip is a figure and the reader wants to
//! know what it counts. The click and the right-click are the ones
//! `app/dispatch.zig`'s `.statusline_seg` arm runs; `askContext` is
//! the same state, spelled for the AI session.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../../app.zig");
const App = app_mod.App;
const copy = @import("../info_view_copy.zig");
const Entry = copy.Entry;
const Link = copy.Link;
const context_menus = @import("../context_menus.zig");
const sl = @import("../../ui/statusline.zig");
const statusline_app = @import("../statusline.zig");
const SegId = statusline_app.SegId;
const discovery = @import("../discovery.zig");
const ghost_chip = @import("../ghost_chip.zig");
const lsp_app = @import("../lsp.zig");
const syntax = @import("../syntax.zig");

const ask = copy.ask_link;

pub fn entry(app: *App, arena: Allocator, seg: u32) Allocator.Error!?Entry {
    switch (seg) {
        sl.seg_mode => return .{
            .title = if (App.profileOf(app.input_style) == .vim) "Mode chip — vim keymap" else "Mode chip — standard keymap",
            .body = "The leftmost chip is the keymap's state: under vim it reads NORMAL / INSERT / VISUAL / REPLACE as you edit, and under either profile it names the surface the keys go to when that is not an editor (TREE, a section, a terminal). Click swaps the profile — vim to standard and back — and right-click lists both plus the cheatsheet. The swap rebuilds every chord at once, so a chord you learned under one profile may not exist under the other.",
            .keys = &.{.{ .command = .@"focus.cycle", .label = "Cycle keyboard focus" }},
            .links = &.{ .{ .command = .{ .id = .@"editor.toggle_keymap", .label = "Swap vim ↔ standard" } }, .{ .settings = .{ .row = comptime copy.settingsRow("editor.input_style"), .label = "Input style in Settings" } }, .{ .command = .{ .id = .@"keys.doctor", .label = "Keymap doctor" } } },
        },
        sl.seg_file => return .{
            .title = "File chip",
            .body = "The active buffer's name, with ● in front while it has unsaved edits and nothing while it is clean. A left click does nothing — the chip is words — and right-click offers the buffer's own rows: copy its path, reveal it in the tree, close it. The chip follows the focused pane, so with a terminal focused it reads `[no file]` rather than name a file the keys are not in.",
            .keys = &.{.{ .command = .@"file.save", .label = "Save" }},
            .links = &.{ .{ .command = .{ .id = .@"view.reveal_in_tree", .label = "Reveal in the tree" } }, .{ .command = .{ .id = .@"file.copy_path", .label = "Copy the path" } } },
        },
        sl.seg_position => return .{
            .title = "Cursor position",
            .body = "Line and column of the cursor in the active editor, one-based, the column counted in characters rather than bytes. Click opens the go-to-line prompt (`:42` does the same from the command line); right-click offers Go to line… and a copy of the position as `line:col`. A selection adds its own chip further right with the character count.",
            .keys = &.{.{ .command = .@"editor.goto_line", .label = "Go to line" }},
            .links = &.{.{ .command = .{ .id = .@"editor.goto_line", .label = "Go to line…" } }},
        },
        sl.seg_language => return .{
            .title = "Language chip",
            .body = "The language mnml picked for the active file, by its name, its extension or a shebang — this is what chooses the highlighter and which LSP server is asked. Click says how in a toast; right-click copies the language's name, lists the file's symbols or formats it. There is no picker here: the file's name decides.",
            .links = &.{ .{ .command = .{ .id = .@"editor.highlight_this_file", .label = "Highlight this file as…" } }, .{ .command = .{ .id = .@"editor.lsp_this_file", .label = "Ask an LSP for this file" } } },
        },
        sl.seg_restricted => return if (app.workspace_toml != null and (app.loaded == null or app.loaded.?.trust_prompt == null)) .{
            .title = "RESTRICTED — an mnml 0.2 config.toml",
            .body = "This workspace carries a `.mnml/config.toml` from mnml 0.2, which this build does not read — the chip is here so the silence is not mistaken for the settings being applied. Run `mnml export-config-zon --out .mnml/config.zon` from the 0.2.22 binary in the workspace to convert it, then reopen. Click opens the trust review, which explains the same thing in place.",
            .links = &.{ .{ .command = .{ .id = .@"workspace.review_trust", .label = "Review the workspace's trust" } }, comptime copy.docsSection("Coming from 0.2.x (TOML)"), ask },
        } else .{
            .title = "RESTRICTED — exec-bearing settings are off",
            .body = "This workspace's `.mnml/config.zon` names things that would run a program — a formatter, a task, an LSP command — and you have not trusted it yet, so those settings are held back while the rest apply. Click opens the review: it lists exactly what the file wants to run, and Trust turns it on for this workspace and remembers the choice. A file you did not write deserves the read before the click.",
            .links = &.{ .{ .command = .{ .id = .@"workspace.review_trust", .label = "Review what it wants to run" } }, comptime copy.docsSection("Workspace trust"), ask },
        },
        else => {},
    }
    if (seg >= sl.seg_dyn_base) return try dynamic(app, arena, seg - sl.seg_dyn_base);
    const id = SegId.of(seg) orelse return null;
    return switch (id) {
        .branch => try branch(app, arena),
        .pr => .{
            .title = "Pull request on this branch",
            .body = "An open pull request whose head is the checked-out branch, found by the integration that publishes PRs for this repo (Bitbucket, GitHub) — the chip shows its number and state. Click opens it in the browser; right-click lists the PR rows: open, copy the URL, refresh. The chip is only as fresh as the last poll, so a PR merged a minute ago may still read open until the next refresh.",
            .links = &.{ .{ .command = .{ .id = .@"pr.picker", .label = "Pick a pull request" } }, .{ .command = .{ .id = .@"pr.refresh", .label = "Refresh" } }, ask },
        },
        .diagnostics => try diagnostics(app, arena),
        .symbol => .{
            .title = "Enclosing symbol",
            .body = "The function, type or block the cursor is inside, from the language server's document symbols — the breadcrumb's last word, kept in the statusline so it is there when the breadcrumb row is off. Click opens the outline pane; right-click offers the outline and the two symbol pickers. It goes blank between symbols and while the server is still indexing the file.",
            .keys = &.{.{ .command = .@"lsp.symbols", .label = "Symbols in this file" }},
            .links = &.{ .{ .command = .{ .id = .@"outline.show", .label = "Open the outline" } }, .{ .command = .{ .id = .@"lsp.workspace_symbols", .label = "Search workspace symbols" } } },
        },
        .macro => .{
            .title = "Recording a macro",
            .body = "vim's `q<register>` is recording: every key from here until the next `q` goes into that register, and `@<register>` replays it. The chip is the only sign the recording is on, so a run of keys that seems to do nothing extra is being written down. Click stops the recording where it is.",
            .links = &.{.{ .command = .{ .id = .@"vim.macro_toggle", .label = "Stop recording" } }},
        },
        .find => .{
            .title = "Find — the last query",
            .body = "The find bar's query and which of its matches the cursor is on, `3/12`. It stays after the bar closes because `n` / `N` and the find-next commands keep stepping through the same matches. Click reopens the bar with the query in it; right-click offers next, previous and clear. A regex query is matched as one — toggle the mode in the bar if the dots mean dots.",
            .keys = &.{ .{ .command = .@"find.next", .label = "Next match" }, .{ .command = .@"find.prev", .label = "Previous match" } },
            .links = &.{ .{ .command = .{ .id = .@"find.find", .label = "Reopen find" } }, .{ .command = .{ .id = .@"find.replace", .label = "Replace" } } },
        },
        .test_run => .{
            .title = "Test run",
            .body = "The last test run's tally — passed, failed, still running — from whichever runner mnml drove (cargo, pytest, go, npm, the e2e corpus). Click focuses the tests pane, where each failure has its output and a jump to the line; right-click runs all, the file, the test at the cursor, or re-runs the failed ones. A red count is the thing to click on: the pane's failure text is what to read, not the number.",
            .links = &.{ .{ .command = .{ .id = .@"test.rerun_failed", .label = "Rerun the failures" } }, .{ .command = .{ .id = .@"test.run_all", .label = "Run everything" } }, ask },
        },
        .ai_claude => try aiChip(app, arena, .claude),
        .ai_codex => try aiChip(app, arena, .codex),
        .ghost => try ghost(app, arena),
        .jobs => try jobsChip(app, arena),
        .coverage => .{
            .title = "Coverage chip",
            .body = "Feature coverage (F) and code coverage (C) from the workspace's trends files, each with the move since last week or the last commit — a number that goes down is the one to look at. Click toasts both figures in full; right-click picks what the chip shows: both, feature only, code only, or a ticker that alternates. The chip only appears when the trends files exist, so a workspace without them never shows it.",
            .links = &.{ .{ .command = .{ .id = .@"coverage.toast", .label = "Show both figures" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.coverage_chip_mode"), .label = "Coverage chip mode" } } },
        },
        .np_brand => .{
            .title = "Now playing — the player",
            .body = "The music app mnml is talking to (`ui.preferred_music_app`): mixr, Music or Spotify. Click opens mixr's pane, or brings Music or Spotify forward; right-click is the player menu — pick the player, play a random chart, open mixr's views, copy the track title.",
            .links = &.{ .{ .command = .{ .id = .@"mixr.show", .label = "Open the player" } }, .{ .command = .{ .id = .@"sonos.status", .label = "Sonos status" } } },
        },
        .np_play => .{
            .title = "Play / pause",
            .body = "Starts or pauses the player mnml is driving — the glyph flips with the player's own state, so it reads as what the next click does. Music and Spotify get the command through osascript; mixr's transport is cut in this build, so on mixr a playing track only toasts that, and an idle mixr starts a random chart. Right-click opens the player menu.",
            .links = &.{.{ .command = .{ .id = .@"sonos.play_pause", .label = "Play / pause" } }},
        },
        .np_next => .{
            .title = "Next track",
            .body = "Skips to the next track on Music or Spotify, through osascript; on mixr the skip is cut in this build and the click toasts that. Right-click opens the player menu. The track chip beside it updates when the player reports the change.",
            .links = &.{ .{ .command = .{ .id = .@"sonos.next", .label = "Next" } }, .{ .command = .{ .id = .@"sonos.previous", .label = "Previous" } } },
        },
        .np_track => .{
            .title = "Now playing — the track",
            .body = "The track and artist the player reports, cut to the width the statusline can spare. Click opens the player's pane; right-click is the player menu. Copy the track name from that menu when you want it in a note — the chip itself does not select text.",
            .links = &.{ .{ .command = .{ .id = .@"sonos.copy_track", .label = "Copy the track name" } }, .{ .command = .{ .id = .@"mixr.show", .label = "Open the player" } } },
        },
        .transfer => .{
            .title = "File transfers",
            .body = "The copies and moves the Files pane started are still running — the chip carries the overall percentage, and its hover lists each job with its own. Right-click cancels all of them; a cancelled copy leaves the partial file where it was writing, so check the destination before retrying. The chip goes away on its own when the last job finishes.",
            .links = &.{ .{ .command = .{ .id = .@"transfer.cancel_all", .label = "Cancel every transfer" } }, .{ .command = .{ .id = .@"files.open", .label = "Open the Files pane" } } },
        },
        .lsp => try lsp(app, arena),
        .wrap => .{
            .title = "WRAP — soft wrap is on",
            .body = "Lines longer than the pane fold at its right edge instead of scrolling sideways, and the horizontal scroll is pinned to 0 while they do. Click turns wrapping off for the active editor only and saves nothing (`ui.wrap` is the default for new buffers); right-click has the same toggle and Editor settings…. Wrapping is visual only — the file's line breaks are untouched — and `:set wrap` / `:set nowrap` do the same from the command line.",
            .links = &.{ .{ .command = .{ .id = .@"view.toggle_wrap", .label = "Turn wrapping off" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.wrap"), .label = "Soft wrap in Settings" } } },
        },
        .autosave => .{
            .title = try std.fmt.allocPrint(arena, "Autosave every {d}s", .{app.cfg.editor.autosave_secs}),
            .body = "`editor.autosave_secs` is set, so a dirty buffer is written to disk that many seconds after the last keystroke — the ● on the file chip clears by itself. Click restates the interval in a toast; there is no menu because the number lives in config.zon. An autosave skips format-on-save, so the text never moves under the cursor; `editor.autosave_on_focus_loss` also writes everything when the terminal loses focus.",
            .links = &.{ .{ .command = .{ .id = .@"file.open_settings", .label = "Open config.zon" } }, .{ .settings = .{ .row = comptime copy.settingsRow("editor.format_on_save"), .label = "Format on save" } } },
        },
        .highlight => try highlight(app, arena),
        .filesize => .{
            .title = "File size",
            .body = "The active buffer's size in memory, bytes rather than the on-disk size, so unsaved edits count. Click toasts the exact bytes and the line count; right-click copies the size. Past `editor.highlight_max_bytes` the highlighter stands down for the file and the highlight chip says so — this chip is where the number that tripped it comes from.",
            .links = &.{ .{ .command = .{ .id = .@"editor.file_stats", .label = "Show the stats" } }, .{ .settings = .{ .row = comptime copy.settingsRow("editor.highlight_max_bytes"), .label = "Highlight size limit" } } },
        },
        .sel => .{
            .title = "Selection",
            .body = "How many characters the active editor's selection covers, counted in characters rather than bytes so a CJK run counts once per glyph. The chip appears with the selection and goes with it. Right-click offers copy and cut; the editing chords are the profile's own.",
            .links = &.{.{ .command = .{ .id = .@"editor.copy", .label = "Copy the selection" } }},
        },
        .stress => try stress(app, arena),
        .bell => try bell(app, arena),
        .clock => .{
            .title = if (app.clock.mode == .utc) "Clock — UTC" else "Clock — local time",
            .body = "Wall-clock time, redrawn with the frame so it lags a render tick at most. A trailing Z means it is UTC. Click flips local ↔ UTC for this session; right-click is the clock's menu. `ui.clock` in Settings only shows or hides it — local or UTC is not saved.",
            .links = if (app.clock.mode == .utc) &.{ .{ .command = .{ .id = .@"clock.local", .label = "Show local time" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.clock"), .label = "Clock in Settings" } } } else &.{ .{ .command = .{ .id = .@"clock.utc", .label = "Show UTC" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.clock"), .label = "Clock in Settings" } } },
        },
        .workspace => .{
            .title = try std.fmt.allocPrint(arena, "Workspace — {s}", .{std.fs.path.basename(app.workspace)}),
            .body = if (app.git.repos.items.len > 1)
                "The folder mnml is rooted at, and with several repos discovered under it the click switches the ACTIVE REPO — the one the branch chip and the git panels follow — rather than the workspace. Right-click has the repo rows (switch, next, previous), worktrees, switch / add / manage workspace and a rescan. Switching workspace reloads the tree and the session for that root."
            else
                "The folder mnml is rooted at — the tree's root, where `.mnml/` lives and what a relative path in a command means. Click opens the workspace picker (the roots from `workspaces` in config.zon, recent ones first); right-click adds or manages workspaces. Switching reloads the tree and restores that workspace's own session, so the tabs you see now come back when you switch back.",
            .keys = &.{.{ .command = .@"view.switch_workspace", .label = "Switch workspace" }},
            .links = &.{ .{ .command = .{ .id = .@"view.switch_workspace", .label = "Switch workspace" } }, .{ .command = .{ .id = .@"view.add_workspace", .label = "Add a workspace root" } } },
        },
        .zoom => .{
            .title = "Zoomed split",
            .body = "This tab page is zoomed: the focused split fills the body and the tab strip shows only its tabs, while the other splits are hidden rather than closed — their ratios, their tabs and the focus are kept exactly. Click puts the layout back as it was. A split, a close or a move un-zooms first, and each tab page keeps its own zoom across a restart.",
            .keys = &.{.{ .command = .@"view.toggle_zoom", .label = "Zoom the split / restore" }},
            .links = &.{ .{ .command = .{ .id = .@"view.toggle_zoom", .label = "Restore the layout" } }, .{ .command = .{ .id = .@"view.fullscreen", .label = "Full screen as well" } } },
        },
        .dev_profile => .{
            .title = "dev profile",
            .body = "This is a build run from a source tree (`./run.sh`), not the installed mnml: its config, session and IPC live under a separate data root so a development build cannot rewrite the daily driver's settings. Click toasts where that root is. `mnml profile seed` copies the stable profile into it when you want the same settings on both.",
            .links = &.{ .{ .command = .{ .id = .@"app.choose_data_layout", .label = "Choose the data layout" } }, .{ .command = .{ .id = .@"app.restart", .label = "Rebuild and relaunch" } } },
        },
        .sandbox => if (app.sandboxState() == .unsafe) .{
            .title = "sandbox? — NOT isolated",
            .body = "`MNML_SANDBOX` says this is a sandbox, but `HOME` is not a throwaway directory or the data root lies outside it, so this session CAN read and write your real config and state. Quit, and launch with `mnml --sandbox` from a normal shell: it makes a fresh temp home and re-runs itself inside it. Click toasts the HOME and data root in play.",
            .links = &.{ comptime copy.docsSection("Sandbox"), ask },
        } else .{
            .title = "sandbox",
            .body = "A `--sandbox` run: `HOME`, `XDG_CONFIG_HOME` and the data root are a fresh `mnml-sandbox-*` directory under the temp root, so this is what a brand-new user sees and nothing here reaches your real config, sessions or credentials — nor does anything a shell pane or an integration started from here does. The session is neither restored nor autosaved, and the running-instance marker is left to your real mnml. The directory is removed when this mnml exits (`--sandbox-keep` keeps it). Click toasts where it is.",
            .links = &.{ comptime copy.docsSection("Sandbox"), ask },
        },
        _ => null,
    };
}

fn branch(app: *App, arena: Allocator) Allocator.Error!Entry {
    const name = app.git.headLabel() orelse "?";
    var body: std.ArrayListUnmanaged(u8) = .empty;
    if (app.git.branchName()) |b| {
        try body.print(arena, "The branch checked out in the active repo — `{s}`", .{b});
    } else if (app.git.status) |st| {
        try body.print(arena, "HEAD in the active repo is on no branch — detached at `{s}`, as after checking out a tag or a commit. Commits made here belong to no branch until you create one", .{st.detachedAt()});
    } else try body.appendSlice(arena, "The branch checked out in the active repo");
    if (app.git.status) |st| {
        const c = statusline_app.fileCounts(st);
        const dirty = c.added + c.changed + c.removed;
        if (st.ahead > 0 or st.behind > 0) try body.print(arena, ", {d} commit{s} ahead and {d} behind its upstream", .{ st.ahead, if (st.ahead == 1) "" else "s", st.behind });
        if (dirty > 0) try body.print(arena, ", with {d} changed file{s} not yet committed", .{ dirty, if (dirty == 1) "" else "s" });
        if (c.conflicts > 0) try body.print(arena, " and {d} in conflict", .{c.conflicts});
        try body.appendSlice(arena, ". ");
    } else try body.appendSlice(arena, " — the status has not been read yet. ");
    try body.appendSlice(arena, "The numbers after the name are the dirty counts: added, changed, removed; ⇡ and ⇣ are ahead and behind. Click opens the status pane, where each file can be staged and the commit written; right-click is the git menu — switch branch, fetch, pull, push, stash. With several repos under the workspace the chip follows the active repo, not the file you are looking at.");
    return .{
        .title = try std.fmt.allocPrint(arena, "Branch {s}", .{name}),
        .body = body.items,
        .keys = &.{ .{ .command = .@"git.status_pane", .label = "Status pane" }, .{ .command = .@"git.commit", .label = "Commit" } },
        .links = &.{ .{ .command = .{ .id = .@"git.status_pane", .label = "Open the status pane" } }, .{ .command = .{ .id = .@"git.branch_menu", .label = "Switch branch" } }, ask },
    };
}

fn diagnostics(app: *App, arena: Allocator) Allocator.Error!Entry {
    var errs: usize = 0;
    var warns: usize = 0;
    if (app.activeEditor()) |e| if (e.buf.doc.path) |pth| for (lsp_app.diagnosticsFor(app, pth)) |d| switch (d.severity) {
        .err => errs += 1,
        .warning => warns += 1,
        else => {},
    };
    return .{
        .title = if (errs + warns == 0) "Diagnostics — none in this file" else try std.fmt.allocPrint(arena, "Diagnostics — {d} error{s}, {d} warning{s}", .{ errs, if (errs == 1) "" else "s", warns, if (warns == 1) "" else "s" }),
        .body = "The language server's problems in the active file, errors then warnings; the hover lists each with its line, worst first. Click opens the diagnostics panel, which is the same list for every open file with a jump on Enter; right-click steps to the next or previous one in the buffer or filters by severity. The count is the server's opinion of the file as last saved-or-typed, so it can lag a keystroke while the server catches up.",
        .keys = &.{ .{ .command = .@"lsp.next_diagnostic", .label = "Next problem" }, .{ .command = .@"lsp.prev_diagnostic", .label = "Previous problem" }, .{ .command = .@"lsp.quick_fix", .label = "Quick fix" } },
        .links = &.{ .{ .command = .{ .id = .@"lsp.diagnostics", .label = "Open the diagnostics panel" } }, .{ .command = .{ .id = .@"lsp.quick_fix", .label = "Quick fix at the cursor" } }, ask },
    };
}

fn aiChip(app: *App, arena: Allocator, product: enum { claude, codex }) Allocator.Error!Entry {
    _ = arena;
    const detail = app.ai.chip_detail;
    return switch (product) {
        .claude => .{
            .title = "Claude usage meter",
            .body = switch (detail) {
                .session => "How much of the current five-hour Claude window the active account has used, with the time until it resets. Click opens the usage pane, which has the weekly window and every linked account; right-click picks what the chip shows — the session window, the weekly one, or both — and can turn all AI chips off or make them a ticker. At 100% the sessions keep running but new turns queue until the reset, so a stalled session and a full chip usually go together.",
                .weekly => "How much of the current WEEKLY Claude allowance the active account has used, with the time until it resets. Click opens the usage pane, which has the five-hour window too and every linked account; right-click picks what the chip shows. At 100% the sessions keep running but new turns queue until the reset, so a stalled session and a full chip usually go together.",
                .both => "The active account's Claude usage — the five-hour window and the weekly one, each as a percentage with its reset time. Click opens the usage pane, which has every linked account; right-click picks the session window, the weekly one, or both, and can turn all AI chips off or make them a ticker. At 100% the sessions keep running but new turns queue until the reset, so a stalled session and a full chip usually go together.",
            },
            .aside = "The figures come from the account's own usage endpoint; a chip stuck at 0% on a linked account wants a token re-link. When the worst watched account is in warning or critical — the endpoint's own grade — the figures sit in a dark pill in yellow or red. Hovering lists every account with its two percents and the next reset.",
            .links = &.{ .{ .command = .{ .id = .@"ai.claude_usage", .label = "Open the usage pane" } }, .{ .command = .{ .id = .@"ai.link_claude_token", .label = "Re-link the Claude token" } }, ask },
        },
        .codex => .{
            .title = "Codex usage chip",
            .body = "The Codex CLI's tokens spent today for the account it is signed in as — `…` until the first scan. Click opens the Codex usage pane; right-click opens that pane, refreshes the usage, shows the last response, or picks session, weekly or both for the chip. Codex has no API route in this build, so the chip is empty until a Codex CLI session has run at least once.",
            .links = &.{ .{ .command = .{ .id = .@"ai.codex_usage", .label = "Open the usage pane" } }, .{ .command = .{ .id = .@"ai.dashboard", .label = "The sessions dashboard" } } },
        },
    };
}

fn jobsChip(app: *App, arena: Allocator) Allocator.Error!Entry {
    const tip = try @import("../jobs.zig").tip(app, arena);
    return .{
        .title = tip.title,
        .body = "What mnml is doing in the background — a language server starting or indexing, a git fetch / pull / push, a test run, an HTTP send, chain or bench, a linter, a search walk, Chrome coming up, a session spawning. A spinner and a count while any runs; for ten seconds after one fails, its words, dimmed — only the kind (`✗ tests`) when another chip already states that failure, and on a row too narrow for the file name as well; nothing when idle. `space j` (either profile; `Ctrl+K j` too under standard) or either click opens the JOBS list: the running ones with a Cancel row where they can be stopped, the last fifty finished with how they ended.",
        .links = &.{ .{ .command = .{ .id = .@"jobs.show", .label = "Open the jobs list" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.jobs_chip"), .label = "Jobs chip in Settings" } }, .{ .command = .{ .id = .@"messages.show", .label = "The messages log" } } },
    };
}

fn ghost(app: *App, arena: Allocator) Allocator.Error!Entry {
    _ = arena;
    const ph = ghost_chip.phase(app);
    return .{
        .title = ghost_chip.hoverTitle(ph),
        .body = switch (ph) {
            .idle => "Inline AI suggestions are on and quiet: nothing is pending and nothing is showing. The chip appears only when there is something to say — a request in flight, an empty answer, an error — so an idle editor paints no chip at all. Click opens the suggestion setup; right-click is the chip's menu.",
            .armed => "An edit landed and the debounce (`ai.suggest_idle_ms`) is counting down before the suggestion request goes out. Keep typing and it re-arms; pause and the request is sent. Click opens the suggestion setup, where the backend and the idle delay live.",
            .inflight => "A suggestion request is out to the backend and the editor is waiting for the ghost text. A request that takes longer than `ai.suggest_timeout_ms` is dropped and the chip says so. Click opens the suggestion setup; the backend named there is the first thing to check when this state lasts.",
            .shown => "Ghost text is on screen after the cursor — Tab accepts it, any other key dismisses it. The suggestion came from the backend `ai.suggest_backend` names. Click opens the suggestion setup; right-click shows the request statistics.",
            .empty => "The backend answered with nothing to suggest — not an error, just no completion for this spot. The chip clears on its own after a moment. Click opens the suggestion setup if empty answers are the rule rather than the exception.",
            .err => "The last suggestion request FAILED — the backend is unreachable, the key is missing, or the CLI is not on PATH. Nothing else in the editor is affected: the `!` holds for five seconds and the next pause sends a request as usual. Click opens the suggestion setup, which names the backend and where its credential comes from.",
        },
        .links = &.{ .{ .command = .{ .id = .@"ai.setup_suggestions", .label = "Suggestion setup" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ai.suggest_backend"), .label = "Suggestion backend" } }, ask },
    };
}

fn lsp(app: *App, arena: Allocator) Allocator.Error!Entry {
    var live: usize = 0;
    for (app.lsp.servers.items) |srv| if (!srv.transport.isDead()) {
        live += 1;
    };
    return .{
        .title = if (live == 0) "Language servers — none running" else try std.fmt.allocPrint(arena, "Language servers — {d} running", .{live}),
        .body = "How many language servers mnml has started for the open files, each on the root it found the project at; the hover lists them by name and root. Click opens the status pane with the same list and each server's state; right-click is the LSP menu — status, an install row for each missing server, then symbols, references, rename, format, code actions and inlay hints. A server that is installed but not running usually means the file's language is not one `lsp` in config.zon names.",
        .keys = &.{ .{ .command = .@"lsp.hover", .label = "Hover at the cursor" }, .{ .command = .@"lsp.goto_definition", .label = "Go to definition" } },
        .links = &.{ .{ .command = .{ .id = .@"lsp.status", .label = "Open the status pane" } }, .{ .settings = .{ .row = comptime copy.settingsRow("editor.lsp_missing_defaults"), .label = "Missing-server defaults" } }, ask },
    };
}

fn highlight(app: *App, arena: Allocator) Allocator.Error!Entry {
    const e = app.activeEditor() orelse return .{
        .title = "Highlighting",
        .body = "Whether syntax highlighting is on for the active file — the chip paints when it is off, by hand or because the file is larger than `editor.highlight_max_bytes`. Click toggles it for that buffer only; the setting itself is untouched. Focus an editor to see which of the two this is.",
        .links = &.{.{ .settings = .{ .row = comptime copy.settingsRow("editor.highlight_max_bytes"), .label = "Highlight size limit" } }},
    };
    var size_buf: [24]u8 = undefined;
    var limit_buf: [24]u8 = undefined;
    const size = syntax.Syntax.sizeLabel(&size_buf, e.syntax.size_bytes);
    const limit = syntax.Syntax.sizeLabel(&limit_buf, e.syntax.limit_bytes);
    return .{
        .title = if (e.syntax.off) try std.fmt.allocPrint(arena, "Highlighting off for this file ({s})", .{size}) else try std.fmt.allocPrint(arena, "Highlighting on for this file ({s})", .{size}),
        .body = if (e.syntax.over_limit)
            try std.fmt.allocPrint(arena, "This file is over `editor.highlight_max_bytes` ({s}), so the highlighter stood down for it — a tree-sitter parse of a file this size costs more per keystroke than the colours are worth. Click turns highlighting on for this buffer anyway, just for this session; raise the limit in Settings if your files are routinely this size. Colours in a file over the limit can make the editor stutter on every edit.", .{limit})
        else
            "Highlighting was switched off for this buffer by hand (the chip, or `editor.highlight_toggle_file`). The file is under the size limit, so nothing forces this; click puts the colours back. `ui.syntax` in Settings is the switch for every file.",
        .links = &.{ .{ .command = .{ .id = .@"editor.highlight_toggle_file", .label = "Toggle for this buffer" } }, .{ .settings = .{ .row = comptime copy.settingsRow("editor.highlight_max_bytes"), .label = "Highlight size limit" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.syntax"), .label = "Syntax highlighting" } } },
    };
}

fn stress(app: *App, arena: Allocator) Allocator.Error!Entry {
    const st = app.stress.stats();
    return .{
        .title = if (st) |s| try std.fmt.allocPrint(arena, "Frame time — p50 {d}.{d}ms · p95 {d}.{d}ms", .{ s.p50_us / 1000, (s.p50_us % 1000) / 100, s.p95_us / 1000, (s.p95_us % 1000) / 100 }) else "Frame time — no frames sampled yet",
        .body = "A four-block meter that fills as the 95th-percentile frame time climbs — a full bar means a redraw is taking longer than the terminal's own frame, which you feel as typing lag. The usual causes are a very large buffer with highlighting on, a pane painting a big terminal, or an integration republishing every tick. Click toasts the numbers; right-click copies them, resets the samples, or hides the meter (`ui.stress_meter`).",
        .links = &.{ .{ .command = .{ .id = .@"perf.copy_stress", .label = "Copy the numbers" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.stress_meter"), .label = "Stress meter in Settings" } }, ask },
    };
}

fn bell(app: *App, arena: Allocator) Allocator.Error!Entry {
    const u = app.messages.unread();
    return .{
        .title = if (u.err + u.warn == 0) "Messages — nothing unread" else try std.fmt.allocPrint(arena, "Messages — {d} unread ({d} error{s})", .{ u.err + u.warn, u.err, if (u.err == 1) "" else "s" }),
        .body = "Every toast is also kept in a history, so a message that scrolled past is not lost. The bell is quiet when there is nothing, carries a count in yellow for warnings and in red for errors — the colour is the level, so the number does not have to be. Click opens the history; right-click shows it or clears it. The list holds the last 200 entries.",
        .links = &.{ .{ .command = .{ .id = .@"messages.show", .label = "Open the history" } }, .{ .command = .{ .id = .@"messages.clear", .label = "Clear the messages" } }, ask },
    };
}

/// A host's own segment — a chip an integration (or a script over the
/// IPC channel) publishes. With a `tooltip`, its first line is the
/// title and the rest opens the body; without one, the entry names the
/// segment by its id. Either way the rest is read off the segment: what
/// its left click runs, and the rows its right-click menu really has
/// (`context_menus.openIntegrationSegmentMenu`).
fn dynamic(app: *App, arena: Allocator, slot: u32) Allocator.Error!?Entry {
    const segs = app.ipc_fx.segments.items;
    if (slot >= segs.len) return null;
    const seg = segs[slot];
    const polled = app.integration_poll.jobForSegment(seg.id) != null;
    var title: []const u8 = undefined;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    if (seg.tooltip) |tip| {
        var it = std.mem.splitScalar(u8, tip, '\n');
        title = try arena.dupe(u8, it.first());
        while (it.next()) |l| {
            if (body.items.len > 0) try body.append(arena, ' ');
            try body.appendSlice(arena, l);
        }
        if (body.items.len > 0) try body.appendSlice(arena, " ");
    } else {
        title = try std.fmt.allocPrint(arena, "Chip `{s}`", .{seg.id});
        try body.print(arena, "A chip published to the statusline as `{s}`, sent without hover text of its own, so its figure is all it says. ", .{seg.id});
    }
    if (seg.click_command) |c| try body.print(arena, "Click runs `{s}`. ", .{c}) else try body.appendSlice(arena, "The chip is passive — a click runs nothing. ");
    try body.appendSlice(arena, "Right-click lists ");
    if (polled) try body.appendSlice(arena, "Refresh now (every integration polls at once), ");
    if (seg.click_command != null) try body.appendSlice(arena, "Open (the click's command), ");
    try body.print(arena, "Requests… (the request log filtered to `{s}`) and Integrations…. ", .{context_menus.serviceOfSegment(seg.id)});
    try body.appendSlice(arena, if (polled) "It is as fresh as that integration's last poll." else "Nothing here polls it; it is as fresh as the publisher's last send.");
    const links: []const Link = if (polled) &.{ .{ .command = .{ .id = .@"integrations.poll_now", .label = "Poll the integrations now" } }, ask } else &.{ .{ .command = .{ .id = .@"integrations.show_installed", .label = "The installed integrations" } }, ask };
    return .{ .title = title, .body = body.items, .links = links };
}

// ─── the state, spelled for the AI ──────────────────────────────────────

/// The same figures the hover lists, as text the session can read:
/// the diagnostics with their lines, the branch and its files, the
/// unread messages, the servers, the ghost phase.
pub fn askContext(app: *App, arena: Allocator, seg: u32) Allocator.Error!?[]const u8 {
    const tip = (try discovery.describe(app, arena, .{ .statusline_seg = seg })) orelse return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.print(arena, "- chip: {s}", .{tip.title});
    if (tip.detail) |d| try out.print(arena, " ({s})", .{d});
    try out.append(arena, '\n');
    for (tip.lines) |l| try out.print(arena, "  {s}\n", .{l});
    for (tip.rows) |r| try out.print(arena, "- {s}{s}{s}\n", .{ r.text, if (r.sub.len > 0) " — " else "", r.sub });
    if (tip.more > 0) try out.print(arena, "- … and {d} more\n", .{tip.more});
    if (SegId.of(seg)) |id| switch (id) {
        .ghost => {
            const g = &app.ai.ghost;
            try out.print(arena, "- ghost-text backend: {s}; requests: {d} settled, mean latency {d}ms\n", .{ @tagName(@import("../ai.zig").suggestBackend(app)), g.latency_n, if (g.latency_n == 0) 0 else g.latency_total_ms / g.latency_n });
        },
        .diagnostics => if (app.activeEditor()) |e| if (e.buf.doc.path) |p| {
            try out.print(arena, "- file: {s}\n", .{app.relPath(p)});
        },
        else => {},
    };
    return out.items;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "every fixed segment and every SegId has an entry; the branch entry names the branch" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const a = app.frame.allocator();
    for ([_]u32{ sl.seg_mode, sl.seg_file, sl.seg_position, sl.seg_language, sl.seg_restricted }) |seg| try t.expect((try entry(&app, a, seg)) != null);
    inline for (comptime std.enums.values(SegId)) |id| {
        const e = (try entry(&app, a, id.raw())) orelse return error.MissingEntry;
        try t.expect(e.body.len >= 40);
    }
    try t.expect(std.mem.startsWith(u8, (try entry(&app, a, SegId.branch.raw())).?.title, "Branch "));
    // A dynamic segment past the end has nothing; one without a tooltip
    // is curated by its id and the rows its menu really has.
    try t.expect((try entry(&app, a, sl.seg_dyn_base)) == null);
    try app.ipc_fx.setSegment(app.gpa, .{ .id = "demo_prs.open", .text = " 3 " });
    const plain = (try entry(&app, a, sl.seg_dyn_base)).?;
    try t.expectEqualStrings("Chip `demo_prs.open`", plain.title);
    try t.expect(std.mem.indexOf(u8, plain.body, "a click runs nothing") != null);
    try t.expect(std.mem.indexOf(u8, plain.body, "Requests… (the request log filtered to `demo`)") != null);
    // Nothing polls it, so no Refresh now row is promised.
    try t.expect(std.mem.indexOf(u8, plain.body, "Refresh now") == null);
}
