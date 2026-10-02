//! Hover help for the menus a pane's body and the tree open
//! (`context_menus.zig`): the editor body, the gutter's breakpoint
//! menu, a tree row's file verbs, a workspace header's, a breadcrumb
//! segment's, a welcome-screen recent row's, a link's, a toast's, an
//! AI pane's and a terminal pane's body.

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
    // ── the editor body (`openEditorMenu`, titled `Editor`) ──
    // Cut / Copy / Paste are on a tree row too, running the FILE
    // clipboard, and the pty body's Paste runs the terminal's — the
    // command tells the three apart.
    .{ .label = "Cut", .command = .@"editor.cut", .entry = .{
        .title = "Cut",
        .body = "Takes the selection out of the buffer and onto the clipboard; with nothing selected it takes the whole line the cursor is on, as Ctrl+X does in VS Code. The buffer goes dirty and the undo history keeps the removal as one step. `editor.clipboard` decides whether the text reaches the OS clipboard or stays inside mnml.",
        .links = &.{ .{ .command = .{ .id = .@"editor.cut", .label = "Cut it" } }, .{ .command = .{ .id = .@"editor.undo", .label = "Undo that" } }, .{ .settings = .{ .row = copy.settingsRow("editor.clipboard"), .label = "Clipboard in Settings" } } },
    } },
    .{ .label = "Copy", .command = .@"editor.copy", .entry = .{
        .title = "Copy",
        .body = "Puts the selection on the clipboard and leaves the buffer as it is; with nothing selected it takes the cursor's whole line, newline included, so a paste lands as a line of its own. Nothing goes dirty and no undo step is made. Under `editor.clipboard = internal` the text never leaves mnml, so another app cannot paste it.",
        .links = &.{ .{ .command = .{ .id = .@"editor.copy", .label = "Copy it" } }, .{ .command = .{ .id = .@"editor.paste", .label = "Paste it back" } }, .{ .settings = .{ .row = copy.settingsRow("editor.clipboard"), .label = "Clipboard in Settings" } } },
    } },
    .{ .label = "Paste", .command = .@"editor.paste", .entry = .{
        .title = "Paste",
        .body = "Drops the clipboard in at the cursor, replacing the selection when there is one; the text lands exactly at the cursor, even a line yanked whole — vim's `p` / `P` are the keys that put a whole line on its own row. Pasted text is not re-indented, so a block from elsewhere keeps the indentation it was copied with. A terminal pane's own *Paste* writes to the shell instead, and is a different row.",
        .links = &.{ .{ .command = .{ .id = .@"editor.paste", .label = "Paste" } }, .{ .command = .{ .id = .@"editor.undo", .label = "Undo that" } }, .{ .settings = .{ .row = copy.settingsRow("editor.clipboard"), .label = "Clipboard in Settings" } } },
    } },
    .{ .menu = "Editor", .label = "Undo", .entry = .{
        .title = "Undo",
        .body = "Steps the active buffer back one edit and moves the cursor to where that edit happened, so what is being undone is on screen. The history is per buffer and goes when the tab closes — a file closed and reopened starts clean unless `editor.persistent_undo` is on. A save is not an edit, so undoing past one makes the file dirty again.",
        .keys = &.{.{ .command = .@"editor.redo", .label = "Redo" }},
        .links = &.{ .{ .command = .{ .id = .@"editor.undo", .label = "Undo" } }, .{ .command = .{ .id = .@"editor.redo", .label = "Redo" } } },
    } },
    .{ .menu = "Editor", .label = "Redo", .entry = .{
        .title = "Redo",
        .body = "Puts back the edit the last undo took away, one step at a time, following the cursor to it. Typing after an undo abandons the redo branch — from there the undone edits cannot be reached again. There is nothing to redo until something has been undone.",
        .keys = &.{.{ .command = .@"editor.redo", .label = "Redo" }},
        .links = &.{ .{ .command = .{ .id = .@"editor.redo", .label = "Redo" } }, .{ .command = .{ .id = .@"editor.undo", .label = "Undo again" } } },
    } },
    .{ .menu = "Editor", .label = "Select all", .entry = .{
        .title = "Select all",
        .body = "Selects the whole buffer, first byte to last, and the Sel chip in the statusline counts it. The next Cut, Copy or typed character then acts on all of it, which is what makes this the row before a wholesale replace. Esc or a click in the text drops the selection again.",
        .links = &.{ .{ .command = .{ .id = .@"editor.select_all", .label = "Select it all" } }, .{ .command = .{ .id = .@"editor.copy", .label = "Copy the buffer" } }, .{ .command = .{ .id = .@"lsp.format", .label = "Format it instead" } } },
    } },
    // Unqualified: the words are about the cursor in this editor,
    // true wherever the row sits. The menu bar's Go and Selection
    // dropdowns have their own rows, written for those menus, and
    // come first in lookup order.
    .{ .label = "Go to definition", .entry = .{
        .title = "Go to definition",
        .body = "Follows the symbol the cursor sits in to where it is defined, opening that file in this leaf when it is not already open. The right press placed the cursor first, so the jump is about the word under the pointer. With no language server for this buffer it says so and stays put; the peek form shows the definition in a box without moving the cursor at all.",
        .keys = &.{ .{ .command = .@"lsp.goto_definition", .label = "Go to definition" }, .{ .command = .@"lsp.peek_definition_overlay", .label = "Peek instead" } },
        .links = &.{ .{ .command = .{ .id = .@"lsp.goto_definition", .label = "Go" } }, .{ .command = .{ .id = .@"lsp.peek_definition_overlay", .label = "Peek without moving" } }, .{ .command = .{ .id = .@"lsp.status", .label = "Which servers are running" } } },
    } },
    .{ .label = "Find references", .entry = .{
        .title = "Find references",
        .body = "Asks the language server for every use of the symbol at the cursor across the project, the declaration included, and lists the hits in a picker with the line each is on; Enter jumps to one. It is the server's answer rather than a grep, so a project it has not finished indexing answers short — the LSP chip says when it is still loading.",
        .keys = &.{ .{ .command = .@"lsp.references", .label = "Find references" }, .{ .command = .@"lsp.goto_definition", .label = "Go to the definition" } },
        .links = &.{ .{ .command = .{ .id = .@"lsp.references", .label = "Find them" } }, .{ .command = .{ .id = .@"lsp.incoming_calls", .label = "Who calls this" } }, .{ .command = .{ .id = .@"find.grep", .label = "Grep for the word instead" } } },
    } },
    .{ .menu = "Editor", .label = "Hover info", .entry = .{
        .title = "Hover info",
        .body = "Shows the language server's documentation for the word at the cursor — its type, its signature, its doc comment — in a box anchored to that word; Esc closes it. While a debug session is stopped the same verb evaluates the word in the stopped frame instead, so the box holds a value rather than a doc. A buffer with no server has nothing to show.",
        .keys = &.{ .{ .command = .@"lsp.hover", .label = "Hover info" }, .{ .command = .@"lsp.signature_help", .label = "Signature help" } },
        .links = &.{ .{ .command = .{ .id = .@"lsp.hover", .label = "Show it" } }, .{ .command = .{ .id = .@"lsp.status", .label = "Which servers are running" } }, .{ .settings = .{ .row = copy.settingsRow("ui.hover_tooltip"), .label = "The pointer tooltip" } } },
    } },
    .{ .label = "Rename symbol", .entry = .{
        .title = "Rename symbol",
        .body = "Asks for a new name, seeded with the word at the cursor, and has the language server rewrite every binding of that symbol across the project in one edit — definition, uses, other files. It follows the code's meaning, so a string or a comment that happens to spell the same word is left alone. Nothing is written to disk: the buffers it touched go dirty and want a Save all.",
        .keys = &.{.{ .command = .@"lsp.rename", .label = "Rename symbol" }},
        .links = &.{ .{ .command = .{ .id = .@"lsp.rename", .label = "Rename it" } }, .{ .command = .{ .id = .@"file.save_all", .label = "Save the buffers it changed" } }, .{ .command = .{ .id = .@"lsp.references", .label = "See the uses first" } } },
    } },
    .{ .label = "Select all occurrences", .entry = .{
        .title = "Select all occurrences",
        .body = "Puts a cursor on every occurrence of the word the cursor is in, throughout this buffer, so one set of keystrokes edits them all at once; the Sel chip counts the cursors. The match is textual — a comment or a string spelling the same word gets a cursor too — and it stops at this buffer's end. Esc drops back to one cursor.",
        .keys = &.{.{ .command = .@"editor.select_all_occurrences", .label = "Select all occurrences" }},
        .links = &.{ .{ .command = .{ .id = .@"editor.select_all_occurrences", .label = "Take them all" } }, .{ .command = .{ .id = .@"editor.clear_extra_cursors", .label = "Back to one cursor" } }, .{ .command = .{ .id = .@"lsp.rename", .label = "Rename the symbol instead" } } },
    } },
    .{ .label = "Expand selection", .entry = .{
        .title = "Expand selection",
        .body = "Grows the selection outwards from the cursor to the next syntax node enclosing it — the word, then the call, then the statement, then the block — from the language server's ranges. Run it again for another step out, and shrink walks the same steps back in. Without a language server there is nothing to ask and the row says so.",
        .links = &.{ .{ .command = .{ .id = .@"lsp.selection_expand", .label = "Expand" } }, .{ .command = .{ .id = .@"lsp.selection_shrink", .label = "Shrink again" } }, .{ .command = .{ .id = .@"lsp.status", .label = "Which servers are running" } } },
    } },
    .{ .menu = "Editor", .label = "Toggle fold", .entry = .{
        .title = "Toggle fold",
        .body = "Closes the block the cursor is inside into a single summary line, or opens the closed fold it is sitting on. Folds live in the buffer rather than on disk, so they go when the tab closes; the arrow in the gutter is the mouse's way to the same flip. Unfold all is the way out once several nested folds are shut.",
        .keys = &.{ .{ .command = .@"editor.toggle_fold", .label = "Toggle fold" }, .{ .command = .@"editor.unfold_all", .label = "Unfold everything" } },
        .links = &.{ .{ .command = .{ .id = .@"editor.toggle_fold", .label = "Toggle it" } }, .{ .command = .{ .id = .@"editor.unfold_all", .label = "Unfold all" } }, .{ .settings = .{ .row = copy.settingsRow("ui.always_show_fold_arrows"), .label = "Fold arrows in the gutter" } } },
    } },
    .{ .menu = "Editor", .label = "Explain with Claude", .entry = .{
        .title = "Explain with Claude",
        .body = "Sends the selection — or the whole file when nothing is selected — to Claude asking what it does, and the answer streams into an AI pane beside the code. That pane's own menu re-asks, cancels, or promotes it to a session you can talk back to. Routed off (`ai.routing.claude.backend = off`) the row fails with that line instead of asking.",
        .links = &.{ .{ .command = .{ .id = .@"ai.explain", .label = "Explain it" } }, .{ .command = .{ .id = .@"ai.fix", .label = "Find and fix bugs in it" } }, .{ .settings = .{ .row = copy.settingsRow("ai.routing.claude.backend"), .label = "Claude backend in Settings" } } },
    } },
    .{ .menu = "Editor", .label = "Ask Claude\u{2026}", .entry = .{
        .title = "Ask Claude…",
        .body = "Opens a prompt for a question of your own and answers it in an AI pane — a bare question, with none of the buffer attached. *Explain with Claude* is the row that carries the code; `ai.chat` is the middle ground, sending the question with the active file and selection as context. The answer is a one-shot, so a follow-up wants Promote.",
        .links = &.{ .{ .command = .{ .id = .@"ai.ask", .label = "Ask" } }, .{ .command = .{ .id = .@"ai.chat", .label = "Ask with the file as context" } }, .{ .command = .{ .id = .@"ai.claude_code", .label = "A full Claude Code session" } } },
    } },
    // Unqualified: the editor body's row and the tab menu's
    // dirty-tab row are the same act. The File dropdown's own Save
    // is written for that menu and comes first.
    .{ .label = "Save", .entry = .{
        .title = "Save",
        .body = "Writes this buffer to disk and clears the dirty dot on its tab. `editor.format_on_save`, the trailing-whitespace trim (off unless `editor.trim_trailing_ws_on_save` is on) and the final-newline rule all run first, so the text can shift a little under the cursor as it lands. A buffer with no path asks for one — the standard profile opens Save As; vim is told `no file name — use :w <path>` — and a file changed on disk since it was read is overwritten without a question.",
        .keys = &.{.{ .command = .@"file.save", .label = "Save" }},
        .links = &.{ .{ .command = .{ .id = .@"file.save", .label = "Save now" } }, .{ .settings = .{ .row = copy.settingsRow("editor.format_on_save"), .label = "Format on save" } }, .{ .settings = .{ .row = copy.settingsRow("editor.trim_trailing_ws_on_save"), .label = "Trim trailing whitespace" } } },
    } },

    // ── the gutter (`openGutterMenu`, titled `Breakpoint`) ──
    // The press put the cursor on the line first, so every row is
    // about THAT line. The first two pairs read by state.
    .{ .menu = "Breakpoint", .label = "Add breakpoint", .entry = .{
        .title = "Add breakpoint",
        .body = "Marks the line the pointer landed on with a ● so a running program stops there; a session already attached is told at once, with no restart. Breakpoints are kept per file for the session and can be set long before any adapter exists. The row reads *Remove breakpoint* on a line that already has one.",
        .keys = &.{.{ .command = .@"dap.toggle_breakpoint", .label = "Toggle breakpoint" }},
        .links = &.{ .{ .command = .{ .id = .@"dap.toggle_breakpoint", .label = "Set it" } }, .{ .command = .{ .id = .@"dap.toggle_breakpoint_conditional", .label = "With a condition" } }, .{ .command = .{ .id = .@"dap.list_breakpoints", .label = "Every breakpoint" } } },
    } },
    .{ .menu = "Breakpoint", .label = "Remove breakpoint", .entry = .{
        .title = "Remove breakpoint",
        .body = "Clears the ● from this line and drops its condition, hit count and log message with it — the toast names the line, so a mis-click is obvious. A live session stops honouring it immediately. To keep what was typed into it and only stop stopping, *Disable breakpoint* is the row below.",
        .keys = &.{.{ .command = .@"dap.toggle_breakpoint", .label = "Toggle breakpoint" }},
        .links = &.{ .{ .command = .{ .id = .@"dap.toggle_breakpoint", .label = "Remove it" } }, .{ .command = .{ .id = .@"dap.toggle_breakpoint_enabled", .label = "Disable it instead" } }, .{ .command = .{ .id = .@"dap.list_breakpoints", .label = "Every breakpoint" } } },
    } },
    .{ .menu = "Breakpoint", .label = "Disable breakpoint", .entry = .{
        .title = "Disable breakpoint",
        .body = "Leaves the breakpoint on the line with its condition and hit count intact but takes it out of the adapter's list, so the program runs straight past; the sign is drawn muted. This is how one breakpoint is silenced for a run without losing what was typed into it. The same row then reads *Enable breakpoint*.",
        .links = &.{ .{ .command = .{ .id = .@"dap.toggle_breakpoint_enabled", .label = "Disable it" } }, .{ .command = .{ .id = .@"dap.list_breakpoints", .label = "Every breakpoint" } } },
    } },
    .{ .menu = "Breakpoint", .label = "Enable breakpoint", .entry = .{
        .title = "Enable breakpoint",
        .body = "Puts the disabled breakpoint on this line back into the adapter's list — condition, hit count and log message exactly as they were — and the sign stops being muted. A session already running takes it without a restart. It stays unverified until the adapter confirms this is a line it can stop on.",
        .links = &.{ .{ .command = .{ .id = .@"dap.toggle_breakpoint_enabled", .label = "Enable it" } }, .{ .command = .{ .id = .@"dap.continue", .label = "Continue and hit it" } } },
    } },
    .{ .menu = "Breakpoint", .label = "Edit condition\u{2026}", .entry = .{
        .title = "Edit condition…",
        .body = "Opens a prompt — seeded with whatever condition the line already carries — for an expression in the debuggee's own language, such as `i > 100`, and the program then stops here only when it is true. Accepting an empty box turns it back into a plain breakpoint rather than removing it. On a line with no breakpoint, this makes one.",
        .keys = &.{.{ .command = .@"dap.toggle_breakpoint_conditional", .label = "Conditional breakpoint" }},
        .links = &.{ .{ .command = .{ .id = .@"dap.toggle_breakpoint_conditional", .label = "Edit it" } }, .{ .command = .{ .id = .@"dap.set_breakpoint_hit_count", .label = "A hit count instead" } }, ask },
    } },
    .{ .menu = "Breakpoint", .label = "Edit hit count\u{2026}", .entry = .{
        .title = "Edit hit count…",
        .body = "Asks how many times the line must be reached before it stops — `>= 5` to skip the first four passes, `% 10` for every tenth — with the prompt seeded from the count already set. The adapter is what counts, so the syntax an adapter accepts is the syntax that works. Clearing the box drops the count and the breakpoint stops on every pass again.",
        .links = &.{ .{ .command = .{ .id = .@"dap.set_breakpoint_hit_count", .label = "Set a count" } }, .{ .command = .{ .id = .@"dap.toggle_breakpoint_conditional", .label = "A condition instead" } }, ask },
    } },
    .{ .menu = "Breakpoint", .label = "Add log message\u{2026}", .entry = .{
        .title = "Add log message…",
        .body = "Turns the line into a logpoint: the adapter prints the message and carries on rather than stopping, with `{expr}` in the text replaced by that expression's value — `x is {x}`. Printing without editing the source is the whole point of it. Clearing the box makes it an ordinary stopping breakpoint again.",
        .keys = &.{.{ .command = .@"dap.set_breakpoint_log_message", .label = "Log message" }},
        .links = &.{ .{ .command = .{ .id = .@"dap.set_breakpoint_log_message", .label = "Write one" } }, .{ .command = .{ .id = .@"dap.toggle_panel", .label = "The DEBUG section" } }, ask },
    } },
    // Unqualified: the gutter's row and the rail's DEBUG section both
    // run `dap.run`. The Run dropdown's own row comes first.
    .{ .label = "Start debugging", .entry = .{
        .title = "Start debugging",
        .body = "Launches the active file under the adapter the `dap` config names for its language, hands over every breakpoint set so far as the adapter connects, and runs to the first one it reaches. The DEBUG section does not open itself — `dap.toggle_panel` is the way to the variables, call stack and watches. A language with no adapter configured says so and starts nothing — the table is re-read on each try, so one written after launch still counts.",
        .keys = &.{ .{ .command = .@"dap.continue", .label = "Continue (or start)" }, .{ .command = .@"dap.toggle_panel", .label = "The DEBUG section" } },
        .links = &.{ .{ .command = .{ .id = .@"dap.run", .label = "Start it" } }, .{ .command = .{ .id = .@"dap.list_breakpoints", .label = "The breakpoints" } }, ask },
    } },
    .{ .menu = "Breakpoint", .label = "Continue", .entry = .{
        .title = "Continue",
        .body = "Lets a stopped program run on to the next breakpoint, exception or exit — the DEBUG section's values go stale until it stops again. With no session running it starts one instead, which is what makes it the single key for the whole cycle. A run that never stops again wants Terminate rather than another Continue.",
        .keys = &.{.{ .command = .@"dap.continue", .label = "Continue" }},
        .links = &.{ .{ .command = .{ .id = .@"dap.continue", .label = "Continue" } }, .{ .command = .{ .id = .@"dap.terminate", .label = "Stop the session" } }, ask },
    } },
    .{ .menu = "Breakpoint", .label = "Evaluate word under cursor", .entry = .{
        .title = "Evaluate word under cursor",
        .body = "Sends the word the press landed on to the adapter as an `evaluate` in the stopped frame and shows `name: type = value` in a box anchored to that word. It needs a session that is stopped: running, or not started, it says so. The REPL is the place for an expression rather than a bare name.",
        .keys = &.{.{ .command = .@"dap.evaluate_hover", .label = "Evaluate at the cursor" }},
        .links = &.{ .{ .command = .{ .id = .@"dap.evaluate_hover", .label = "Evaluate it" } }, .{ .command = .{ .id = .@"dap.repl", .label = "The debug REPL" } }, .{ .settings = .{ .row = copy.settingsRow("editor.inline_values"), .label = "Inline values" } } },
    } },
    .{ .menu = "Breakpoint", .label = "Peek change", .entry = .{
        .title = "Peek change",
        .body = "Opens this file's diff in a pane and lands the cursor on the hunk the pointer's line belongs to, so the change the gutter marked can be read in full. It is the working tree against the index — the unstaged change only; what is already staged does not show. A file with nothing changed opens an empty diff; outside a repo the row says there is none.",
        .links = &.{ .{ .command = .{ .id = .@"git.peek_change", .label = "Peek it" } }, .{ .command = .{ .id = .@"git.diff_file", .label = "The whole file's diff" } }, .{ .command = .{ .id = .@"git.status_pane", .label = "The status pane" } } },
    } },
    .{ .menu = "Breakpoint", .label = "Toggle blame", .entry = .{
        .title = "Toggle blame",
        .body = "Puts a column beside the gutter naming the commit, author and age of every line, computed in the background — the toast says it is working before the column appears. A second call takes it away and frees what it held. It needs a saved file inside a repo: an unsaved scratch buffer has nothing to blame.",
        .keys = &.{.{ .command = .@"git.blame_toggle", .label = "Toggle blame" }},
        .links = &.{ .{ .command = .{ .id = .@"git.blame_toggle", .label = "Toggle it" } }, .{ .command = .{ .id = .@"git.peek_change", .label = "The change at this line" } }, .{ .command = .{ .id = .@"git.graph", .label = "The commit graph" } } },
    } },
    .{ .menu = "Breakpoint", .label = "Open on remote", .entry = .{
        .title = "Open on remote",
        .body = "Builds the forge's URL for this file at this line — GitHub, GitLab, Bitbucket or Azure DevOps, read off the repo's `origin` — and hands it to the OS browser, which is the link a review wants pasted into it. It points at what the remote knows, so a line that only exists in an unpushed commit lands on the wrong text. A repo with no recognised remote says so instead.",
        .links = &.{ .{ .command = .{ .id = .@"git.browse", .label = "Open it" } }, .{ .command = .{ .id = .@"git.status_pane", .label = "What is unpushed" } }, ask },
    } },

    // ── a tree row (`openTreeMenu`) — the menu is titled by the row's
    // own file or folder name, so none of these can be qualified by
    // their menu. `New file…` / `New folder…` / `Expand all` /
    // `Collapse all` / `Paste here` / `Refresh tree` are shared with
    // the workspace header (and `Refresh tree` with the rail's
    // Explorer menu): one row each, true in all of them.
    .{ .label = "New file\u{2026}", .entry = .{
        .title = "New file…",
        .body = "Asks for a path prefilled with the folder this menu was opened on, so a bare name lands right there; folders named on the way that do not exist are made. The file opens in a tab of the active leaf as soon as it is written. A name already taken is opened rather than overwritten.",
        .keys = &.{.{ .command = .@"file.new", .label = "New file" }},
        .links = &.{ .{ .command = .{ .id = .@"file.new", .label = "Make one" } }, .{ .command = .{ .id = .@"file.new_folder", .label = "A folder instead" } }, .{ .command = .{ .id = .@"scratch.new", .label = "An unsaved scratch buffer" } } },
    } },
    .{ .label = "New folder\u{2026}", .entry = .{
        .title = "New folder…",
        .body = "Asks for a path prefilled with this row's folder and creates the directory, parents included, then refreshes the tree onto it. Nothing opens — a folder has nothing to show until something is put in it. *New file…* with a path in it does both in one go.",
        .links = &.{ .{ .command = .{ .id = .@"file.new_folder", .label = "Make one" } }, .{ .command = .{ .id = .@"file.new", .label = "A file instead" } }, .{ .command = .{ .id = .@"tree.refresh", .label = "Refresh the tree" } } },
    } },
    .{ .label = "Collapse all", .entry = .{
        .title = "Collapse all",
        .body = "Folds every open directory back to the workspace roots, so a deep hunt can start again from the top; the cursor stays on the nearest row that survives. Which folders are open is session state rather than config, and this forgets all of it at once. *Expand all* is the other extreme.",
        .links = &.{ .{ .command = .{ .id = .@"tree.collapse_all", .label = "Collapse them" } }, .{ .command = .{ .id = .@"tree.expand_all", .label = "Expand them instead" } }, .{ .command = .{ .id = .@"picker.files", .label = "Find a file by name" } } },
    } },
    .{ .label = "Expand all", .entry = .{
        .title = "Expand all",
        .body = "Opens every directory, walking outwards until nothing new appears, so the whole workspace is one scrollable list. Noisy folders — `node_modules`, `target` and their kin — stay shut, which is what keeps this from taking minutes on a real project. It is still a long list on a large repo: the file picker is usually the faster way to one file.",
        .links = &.{ .{ .command = .{ .id = .@"tree.expand_all", .label = "Expand them" } }, .{ .command = .{ .id = .@"tree.collapse_all", .label = "Collapse them again" } }, .{ .command = .{ .id = .@"picker.files", .label = "Find a file by name" } } },
    } },
    .{ .label = "Show git-ignored files", .command = .@"tree.toggle_ignored", .entry = .{
        .title = "Show git-ignored files",
        .body = "Lists what the `.gitignore`s leave out — a `.env.local`, a failing test's `*.log`, a generated `dist/` — dim, beside everything else, and lets Ctrl+P find them too. Outside a git repo the build folders (`node_modules`, `target`, `build`…) are what it brings back. `I` in the focused tree flips it too (nvim-tree's key); the tick says it is on, and the switch lasts the session.",
        .links = &.{ .{ .command = .{ .id = .@"tree.toggle_ignored", .label = "Toggle it" } }, .{ .command = .{ .id = .@"view.toggle_hidden", .label = "Dot files instead" } }, .{ .command = .{ .id = .@"picker.files", .label = "Find a file by name" } } },
    } },
    .{ .label = "Open", .command = .@"tree.open_selected", .entry = .{
        .title = "Open",
        .body = "Opens this row in the active leaf — a file in an editor tab, a markdown file rendered when `ui.markdown_opens_rendered` says so, a directory by folding it open in place. Enter on the row does the same thing. *Open in split* is the row for putting it beside what is already on screen.",
        .keys = &.{.{ .chord = "Enter", .label = "Open the row" }},
        .links = &.{ .{ .command = .{ .id = .@"tree.open_selected", .label = "Open it" } }, .{ .command = .{ .id = .@"tree.open_in_split", .label = "Open in a split" } }, .{ .settings = .{ .row = copy.settingsRow("ui.preview_tabs"), .label = "Preview tabs" } } },
    } },
    .{ .label = "Open in split", .entry = .{
        .title = "Open in split",
        .body = "Splits the active leaf and opens this file in the new side, next to what you were already reading; the new split takes the focus. A directory has nothing to put there and the row says so. An already-open file is re-used; when it is the file already active, nothing splits.",
        .links = &.{ .{ .command = .{ .id = .@"tree.open_in_split", .label = "Open it beside" } }, .{ .command = .{ .id = .@"tree.open_selected", .label = "Open it here instead" } }, .{ .command = .{ .id = .@"view.equalize_splits", .label = "Equalize the splits" } } },
    } },
    .{ .label = "Cut", .command = .@"file.cut", .entry = .{
        .title = "Cut",
        .body = "Stages this row — or every marked row of a focused Files pane — on mnml's own file clipboard, marked as a move, and the toast names what was taken. Nothing has moved yet: *Paste here* on the destination folder is what does it, and the clipboard clears afterwards. The OS clipboard is untouched, so another app cannot receive this.",
        .links = &.{ .{ .command = .{ .id = .@"file.cut", .label = "Cut it" } }, .{ .command = .{ .id = .@"file.paste", .label = "Paste it somewhere" } }, .{ .command = .{ .id = .@"file.move_to", .label = "Move to a folder instead" } } },
    } },
    .{ .label = "Copy", .command = .@"file.copy", .entry = .{
        .title = "Copy",
        .body = "Stages this row on the file clipboard for copying rather than moving — the original stays where it is, however many times it is pasted. A copy pasted back into its own folder takes a `-copy` name instead of clashing with itself. *Duplicate* is the one-step form of exactly that.",
        .links = &.{ .{ .command = .{ .id = .@"file.copy", .label = "Copy it" } }, .{ .command = .{ .id = .@"file.paste", .label = "Paste it somewhere" } }, .{ .command = .{ .id = .@"file.duplicate", .label = "Duplicate it in place" } } },
    } },
    .{ .label = "Paste here", .entry = .{
        .title = "Paste here",
        .body = "Puts what the file clipboard holds into this row's folder — the folder itself when the menu was opened on one, otherwise the folder the file sits in. The work runs as a background transfer, so pasting a huge tree does not freeze the frame and the transfer chip counts it down. A name already in the destination is skipped rather than overwritten, and a folder pasted into itself is refused.",
        .links = &.{ .{ .command = .{ .id = .@"file.paste", .label = "Paste them" } }, .{ .command = .{ .id = .@"transfer.cancel_all", .label = "Cancel the transfers" } }, ask },
    } },
    .{ .label = "Duplicate", .entry = .{
        .title = "Duplicate",
        .body = "Makes a second copy beside this row, named `name-copy.ext` — `-copy-2`, `-copy-3` when those are taken — without touching the clipboard at all. A directory is copied whole on the background transfer, so a big one takes a moment. The name chosen is never one that already exists, so nothing is overwritten.",
        .links = &.{ .{ .command = .{ .id = .@"file.duplicate", .label = "Duplicate it" } }, .{ .command = .{ .id = .@"file.rename", .label = "Rename the copy" } } },
    } },
    .{ .label = "Move to\u{2026}", .entry = .{
        .title = "Move to…",
        .body = "Asks for a destination folder, seeded with the one this row is in, and moves the row there on accept; Tab completes folder names and `~` is home. A path that ends in a name rather than a folder renames as it moves. It is the prompt-driven twin of *Cut* followed by *Paste here*.",
        .links = &.{ .{ .command = .{ .id = .@"file.move_to", .label = "Move it" } }, .{ .command = .{ .id = .@"file.cut", .label = "Cut and paste instead" } }, .{ .command = .{ .id = .@"file.rename", .label = "Just rename it" } } },
    } },
    .{ .label = "Rename\u{2026}", .command = .@"file.rename", .entry = .{
        .title = "Rename…",
        .body = "Opens a prompt seeded with this row's name alone, so the common case is typing over it; a name with a `/` in it moves the file to that path as well. Open tabs follow the file to its new name. Renaming a folder renames everything under it, and the tree puts the cursor back on the row afterwards.",
        .links = &.{ .{ .command = .{ .id = .@"file.rename", .label = "Rename it" } }, .{ .command = .{ .id = .@"file.move_to", .label = "Move it to a folder" } }, .{ .command = .{ .id = .@"lsp.rename", .label = "Rename a symbol instead" } } },
    } },
    .{ .label = "Delete\u{2026}", .entry = .{
        .title = "Delete…",
        .body = "Asks first, naming the row — a folder's question carries how many entries go with it — and the buttons say where it goes: Delete moves it to the workspace trash, Delete permanently does not. Cancel is the focused button, so Enter on that box keeps the file. Something already in the trash can only go permanently.",
        .keys = &.{.{ .command = .@"file.delete", .label = "Delete the row" }},
        .links = &.{ .{ .command = .{ .id = .@"file.delete", .label = "Delete it" } }, .{ .command = .{ .id = .@"files.trash", .label = "Open the trash" } }, .{ .command = .{ .id = .@"files.restore_from_trash", .label = "Restore from the trash" } } },
    } },
    .{ .label = "Copy path", .command = .@"file.copy_path", .entry = .{
        .title = "Copy path",
        .body = "Puts the workspace-relative path of whatever this menu was opened on — the tree row, the tab's file, the file chip's buffer — on the clipboard, and the toast repeats what it took. Relative is the form a commit message, an issue or a grep wants. A buffer that has never been saved has no name to copy and says so.",
        .links = &.{ .{ .command = .{ .id = .@"file.copy_path", .label = "Copy it" } }, .{ .command = .{ .id = .@"view.reveal_active", .label = "Reveal it in the OS" } }, .{ .command = .{ .id = .@"view.reveal_in_tree", .label = "Reveal it in the tree" } } },
    } },
    // ── the statusline file chip's own rows (`openFileChipMenu`, titled `Buffer`) ──
    .{ .menu = "Buffer", .label = "Copy absolute path", .kind = .copy_text, .entry = .{
        .title = "Copy absolute path",
        .body = "Puts the buffer's full path — from the filesystem root, not the workspace — on the clipboard, and the toast repeats it. It is the form a terminal outside the workspace, another editor or a bug report wants; *Copy path* above is the workspace-relative one.",
        .links = &.{ .{ .command = .{ .id = .@"file.copy_path", .label = "The relative path instead" } }, .{ .command = .{ .id = .@"view.reveal_active", .label = "Reveal it in the OS" } } },
    } },
    .{ .menu = "Buffer", .label = "Copy file name", .kind = .copy_text, .entry = .{
        .title = "Copy file name",
        .body = "Puts the buffer's file name alone — `cart.ts`, no folders — on the clipboard, and the toast repeats it. Handy for a commit message, a search box or an import line.",
        .links = &.{.{ .command = .{ .id = .@"file.copy_path", .label = "The path instead" } }},
    } },
    .{ .menu = "Buffer", .label = "Close buffer", .command = .@"buffer.close", .entry = .{
        .title = "Close buffer",
        .body = "Closes this buffer's tab. Unsaved changes are asked about first — save, discard or cancel — so nothing is lost by the click.",
        .keys = &.{.{ .command = .@"buffer.close", .label = "Close it" }},
        .links = &.{ .{ .command = .{ .id = .@"buffer.close", .label = "Close it" } }, .{ .command = .{ .id = .@"file.save", .label = "Save it first" } } },
    } },
    .{ .label = "Refresh tree", .entry = .{
        .title = "Refresh tree",
        .body = "Re-reads every open folder from disk and rebuilds the rows, which is the fix when something done outside mnml — a `git checkout`, a build, another editor — is not showing. Folds, the cursor and the hidden-file state all survive it. The tree keeps itself up to date on most changes, so needing this row often is worth reporting.",
        .links = &.{ .{ .command = .{ .id = .@"tree.refresh", .label = "Refresh it" } }, .{ .command = .{ .id = .@"git.refresh", .label = "Refresh git too" } } },
    } },

    // ── a workspace header (`openWorkspaceHeaderMenu`, titled by the
    // root's basename): root 0 gets the fold and new-file rows, an
    // extra root the three rows about itself, both the tail below ──
    .{ .label = "Collapse / expand section", .entry = .{
        .title = "Collapse / expand section",
        .body = "Folds the whole workspace section shut so its header alone is left, or opens it again with the folders that were open still open. It is how a multi-root tree stays readable: shut the roots that are not in play. Opening it also brings the Explorer back to the column when another section had taken it.",
        .links = &.{ .{ .command = .{ .id = .@"view.toggle_tree_section", .label = "Fold it" } }, .{ .command = .{ .id = .@"view.activity_explorer", .label = "The Explorer section" } }, .{ .settings = .{ .row = copy.settingsRow("ui.tree_width"), .label = "Tree width" } } },
    } },
    .{ .label = "Switch to this workspace", .entry = .{
        .title = "Switch to this workspace",
        .body = "Switches the tree to this added root — it opens, every other root folds and the cursor lands on its header, with the keys in the tree; open tabs stay open. The row is only on an added root's header, because the primary one is already current. *Remove workspace…* is the row for dropping a root rather than moving to it.",
        .keys = &.{.{ .command = .@"view.switch_workspace", .label = "Switch workspace" }},
        .links = &.{ .{ .command = .{ .id = .@"view.switch_workspace", .label = "Switch" } }, .{ .command = .{ .id = .@"view.remove_workspace", .label = "Remove it instead" } } },
    } },
    .{ .label = "Open in file browser", .kind = .open_path, .entry = .{
        .title = "Open in file browser",
        .body = "Opens this folder as a Files pane inside mnml — a browser with marks, a trash and the same file verbs as the tree — rather than handing it to the desktop. It is a tab like any other, so it can be split beside the code. *Reveal in Finder* is the row that leaves mnml for the OS file manager's own window.",
        .links = &.{ .{ .command = .{ .id = .@"files.open", .label = "A Files pane here" } }, .{ .command = .{ .id = .@"view.reveal_active", .label = "Reveal it in the OS" } }, .{ .command = .{ .id = .@"files.destinations", .label = "Go to… home, trash, workspace" } } },
    } },
    .{ .label = "Remove workspace\u{2026}", .entry = .{
        .title = "Remove workspace…",
        .body = "Opens a picker of the roots added beside the primary one and drops the chosen one from the tree, so search, grep and the git scan stop covering it. Nothing on disk is touched and no open file is closed: only the tree forgets it. Added roots live in the session anyway, so the next launch reads the config's list either way.",
        .links = &.{ .{ .command = .{ .id = .@"view.remove_workspace", .label = "Remove one" } }, .{ .command = .{ .id = .@"view.add_workspace", .label = "Add one back" } }, ask },
    } },
    .{ .label = "Switch workspace\u{2026}", .entry = .{
        .title = "Switch workspace…",
        .body = "Lists the primary root and every extra one, each with its path in the second column, and switches the tree to the chosen one — it opens, the others fold and the cursor lands on its header, while open tabs stay open. With only one root open there is nothing to switch to and the row says so. The workspace chip's menu in the statusline has this row too.",
        .keys = &.{.{ .command = .@"view.switch_workspace", .label = "Switch workspace" }},
        .links = &.{ .{ .command = .{ .id = .@"view.switch_workspace", .label = "Pick one" } }, .{ .command = .{ .id = .@"view.add_workspace", .label = "Add another root" } }, .{ .command = .{ .id = .@"git.worktrees", .label = "A worktree instead" } } },
    } },
    .{ .label = "Add workspace\u{2026}", .entry = .{
        .title = "Add workspace…",
        .body = "Asks for a folder — Tab completes as you type — and hangs it in the tree as another root under its own header, so two projects are browsed, searched and grepped side by side. The root lasts for this session only; `.workspaces` in the config file is where one is kept for good. A folder already open is refused with a toast rather than doubled.",
        .links = &.{ .{ .command = .{ .id = .@"view.add_workspace", .label = "Add a folder" } }, .{ .command = .{ .id = .@"view.manage_workspaces", .label = "Keep it for good" } }, copy.docsSection("Workspace trust") },
    } },
    .{ .label = "Manage workspaces\u{2026}", .entry = .{
        .title = "Manage workspaces…",
        .body = "Opens the config file in an editor with the cursor already on the `.workspaces` list, because that list is the one place a root is named, reordered or grouped for good. There is no overlay for it — the Settings UI deliberately leaves arrays of things to the file. Save the buffer and the next launch reads the new list.",
        .links = &.{ .{ .command = .{ .id = .@"view.manage_workspaces", .label = "Edit the list" } }, .{ .command = .{ .id = .@"file.open_settings", .label = "The whole config file" } }, copy.docsSection("The complete file") },
    } },
    .{ .label = "Copy path", .kind = .copy_text, .entry = .{
        .title = "Copy path",
        .body = "Copies the path this row itself names — a workspace header's own root, the directory a breadcrumb segment stands for, the workspace-relative name on a welcome-screen recent row — and toasts what it took. The string is the label's own, so the label is the preview of what lands on the clipboard. It copies text and opens nothing.",
        .links = &.{ .{ .command = .{ .id = .@"files.open", .label = "Open it as a Files pane" } }, .{ .command = .{ .id = .@"view.reveal_active", .label = "Reveal in the OS" } } },
    } },
    .{ .label = "Show workspace dots", .entry = .{
        .title = "Show workspace dots",
        .body = "Paints ● on the primary root's header and ○ on each added root's, so a tree of several roots says which one is the primary at a glance; the tick marks the state now. The row flips it for this run only; the Settings row is what writes `ui.show_workspace_dots` to the home config. The git chip has the counts for the active repo either way.",
        .links = &.{ .{ .command = .{ .id = .@"view.toggle_workspace_dots", .label = "Toggle them" } }, .{ .settings = .{ .row = copy.settingsRow("ui.show_workspace_dots"), .label = "Workspace dots in Settings" } }, .{ .command = .{ .id = .@"git.status_pane", .label = "The status pane" } } },
    } },

    // ── a welcome-screen recent row (`openWelcomeRecentMenu`, titled
    // by the file's basename) ──
    .{ .label = "Open", .kind = .open_path, .entry = .{
        .title = "Open",
        .body = "Opens the file this row names in the active leaf, the same as a click on the row itself — the menu is here for the two verbs under it. A file moved or deleted since it was last opened cannot be read and says so. The recent list is per workspace, and the welcome screen and `picker.recent` both read it.",
        .keys = &.{.{ .command = .@"picker.recent", .label = "Recent files as a picker" }},
        .links = &.{ .{ .command = .{ .id = .@"picker.recent", .label = "The recent-files picker" } }, .{ .command = .{ .id = .@"picker.files", .label = "Any file in the workspace" } }, .{ .command = .{ .id = .@"file.clear_recent", .label = "Clear the list" } } },
    } },
    .{ .label = "Recent files\u{2026}", .entry = .{
        .title = "Recent files…",
        .body = "Leaves the welcome screen's handful of rows for the full recent-files picker, with a preview column and fuzzy typing over the whole list. It is per workspace and survives a restart. The File menu's *Open recent file* submenu is the newest ten of the same list, without the preview.",
        .keys = &.{.{ .command = .@"picker.recent", .label = "Recent files" }},
        .links = &.{ .{ .command = .{ .id = .@"picker.recent", .label = "Open the picker" } }, .{ .command = .{ .id = .@"file.clear_recent", .label = "Clear the list" } }, .{ .command = .{ .id = .@"picker.buffers", .label = "Open buffers instead" } } },
    } },

    // ── a link (`openLinkMenu`, titled `Link`): a URL or an
    // integration-declared key in painted text — a session card, the
    // sessions table's summary. The same two rows a terminal pane's
    // right-click on a link has, written for where they are ──
    .{ .menu = "Link", .label = "Copy link", .kind = .copy_link, .entry = .{
        .title = "Copy link",
        .body = "Puts the link's whole address on the clipboard and toasts *link copied* — the register a `p` in an editor pastes, and the system clipboard. For a key an integration links (`ENG-123`), that is the page it opens, not the key's own text; for a URL cut short on a card, the whole URL.",
        .links = &.{.{ .settings = .{ .row = copy.settingsRow("editor.clipboard"), .label = "Clipboard in Settings" } }},
    } },
    .{ .menu = "Link", .label = "Open link", .kind = .open_url, .entry = .{
        .title = "Open link",
        .body = "Opens the link in the OS browser, or the one `ui.external_browser` names — what a left click on it does. Only `http` and `https` addresses go out. A key links because an installed integration declares its shape and its page; mnml itself knows no key.",
        .links = &.{.{ .command = .{ .id = .@"integrations.show_installed", .label = "The installed integrations" } }},
    } },
    // ── the PR chip's menu (`openPrMenu`) — not qualified by menu ──
    .{ .label = "Open in browser", .kind = .open_url, .entry = .{
        .title = "Open in browser",
        .body = "Hands the URL this row carries to the OS's default browser — or the one `ui.external_browser` names — and mnml keeps the focus it had. It is the whole of what a left click on the link does — the menu exists for the copy beside it. An address the OS has no handler for silently does nothing, which is what a missing browser looks like from here.",
        .links = &.{ .{ .command = .{ .id = .@"browser.open_url", .label = "Open a URL in mnml's browser" } }, copy.docsSection("Workspace trust"), ask },
    } },
    .{ .label = "Copy URL", .kind = .copy_text, .entry = .{
        .title = "Copy URL",
        .body = "Puts the address on the clipboard instead of opening it, and toasts what it took — the row for a link that belongs in a message or a commit rather than a browser tab. It is the URL exactly as the pane holds it, with nothing shortened or stripped. `editor.clipboard = internal` keeps it inside mnml, where another app cannot paste it.",
        .links = &.{ .{ .settings = .{ .row = copy.settingsRow("editor.clipboard"), .label = "Clipboard in Settings" } }, .{ .command = .{ .id = .@"browser.open_url", .label = "Open a URL in Chrome" } } },
    } },

    // ── a toast (`openToastMenu`, titled `Toast`) — the rows a failed
    // git op's toast and the 0.2-manifests notice add lead their
    // lists, so they are written first ──
    .{ .menu = "Toast", .label = "Show in the command log", .entry = .{
        .title = "Show in the command log",
        .body = "Opens the git command log — every git the worker ran, newest first, with its directory, exit code, duration and first line of stderr — which is where a failed operation says what actually went wrong. Only a toast raised by a git failure leads with this row. Enter re-runs a read-only entry there and `y` copies one.",
        .links = &.{ .{ .command = .{ .id = .@"git.command_log", .label = "Open the log" } }, .{ .command = .{ .id = .@"git.status_pane", .label = "The status pane" } }, ask },
    } },
    .{ .menu = "Toast", .label = "Don't show again", .entry = .{
        .title = "Don't show again",
        .body = "Silences the notice about integrations left over from mnml 0.2, whose `.toml` manifests this version never reads, by writing the flag to the home config — it does not come back on the next launch. The integrations are unaffected: they are simply not loaded, and the Marketplace is where 0.3 ones come from. *Dismiss* clears only this showing.",
        .links = &.{ .{ .command = .{ .id = .@"integrations.dismiss_toml_notice", .label = "Never again" } }, .{ .command = .{ .id = .@"integrations.show_marketplace", .label = "The Marketplace" } }, copy.docsSection("Coming from 0.2.x (TOML)") },
    } },
    .{ .menu = "Toast", .label = "Dismiss", .entry = .{
        .title = "Dismiss",
        .body = "Takes this one card off the screen now instead of waiting for it to time out, and the stack below closes up. It acts on the toast the menu was opened on rather than the newest one, so a right press on the right card matters. Nothing is remembered: an operation that toasted once will toast again.",
        .links = &.{ .{ .command = .{ .id = .@"toast.dismiss_clicked", .label = "Dismiss it" } }, .{ .command = .{ .id = .@"toast.copy_clicked", .label = "Copy it first" } } },
    } },
    .{ .menu = "Toast", .label = "Copy text", .entry = .{
        .title = "Copy text",
        .body = "Puts this card's whole message on the clipboard, which is how an error gets out of something about to vanish and into a bug report. The card stays up afterwards — *Dismiss* is the row that clears it. It copies the words alone, not the operation behind them.",
        .links = &.{ .{ .command = .{ .id = .@"toast.copy_clicked", .label = "Copy it" } }, .{ .command = .{ .id = .@"toast.dismiss_clicked", .label = "Then dismiss it" } }, ask },
    } },
    .{ .menu = "Toast", .label = "Dismiss all", .entry = .{
        .title = "Dismiss all",
        .body = "Expires every ephemeral card at once, for when a batch of them has buried the corner. One that carries an identity — the git command-log notice, the 0.2-manifests one — is deliberately left standing, because those are the ones with a row worth pressing; each goes with its own *Dismiss*. The message history keeps what scrolled past either way.",
        .links = &.{ .{ .command = .{ .id = .@"toast.dismiss_all", .label = "Clear them" } }, .{ .command = .{ .id = .@"messages.show", .label = "The message history" } } },
    } },

    // ── an AI pane's body (`openAiPaneMenu`, titled `AI`) ──
    .{ .menu = "AI", .label = "Re-ask (fresh session)", .entry = .{
        .title = "Re-ask (fresh session)",
        .body = "Sends this pane's prompt again with no memory of the first attempt, closing the pane and putting the new answer in its place — the row for an answer that went astray rather than a question that was wrong. A job still running is cancelled first. The prompt cannot be edited here: a changed question wants *Ask Claude…*.",
        .links = &.{ .{ .command = .{ .id = .@"ai.reask", .label = "Ask again" } }, .{ .command = .{ .id = .@"ai.ask", .label = "Ask something else" } }, .{ .command = .{ .id = .@"ai.session_view", .label = "The transcript" } } },
    } },
    .{ .menu = "AI", .label = "Cancel running job", .entry = .{
        .title = "Cancel running job",
        .body = "Tells the worker behind this pane to stop and marks the pane failed with `cancelled`; a confirmation the job was waiting on is answered no, so nothing is left parked. Whatever had already streamed in stays readable. With nothing running the row says so — a finished pane has no job left to cancel.",
        .links = &.{ .{ .command = .{ .id = .@"ai.cancel", .label = "Cancel it" } }, .{ .command = .{ .id = .@"ai.reask", .label = "Start over" } }, ask },
    } },
    .{ .menu = "AI", .label = "Promote to interactive (claude --resume)", .entry = .{
        .title = "Promote to interactive (claude --resume)",
        .body = "Opens a terminal tab running `claude --resume` on this pane's session, so the one-shot answer becomes a conversation to follow up in with everything already said still in context. It needs a CLI session to resume: a pane answered over the API backend has no session id and the row says so. The pane itself is left as it is.",
        .links = &.{ .{ .command = .{ .id = .@"ai.promote", .label = "Promote it" } }, .{ .command = .{ .id = .@"ai.session_view", .label = "Read the transcript instead" } }, .{ .settings = .{ .row = copy.settingsRow("ai.routing.claude.backend"), .label = "Claude backend in Settings" } } },
    } },
    .{ .menu = "AI", .label = "Apply suggested change", .entry = .{
        .title = "Apply suggested change",
        .body = "Takes the first code block out of the answer and opens it as a proposal against the range the question was asked about — the selection that was explained, or the whole buffer — to be accepted hunk by hunk before a byte of it reaches the editor. An answer with no fenced block has nothing to apply. Nothing is written: the buffer goes dirty and waits for a Save.",
        .links = &.{ .{ .command = .{ .id = .@"ai.apply", .label = "Review the change" } }, .{ .command = .{ .id = .@"file.save", .label = "Save afterwards" } }, .{ .command = .{ .id = .@"editor.undo", .label = "Undo it" } } },
    } },

    // ── a terminal pane's body (`openPtyPaneMenu`, titled by the
    // pane's own name). Clear, Restart, Rename…, Color and Equalize
    // splits are written where the tab menu's rows are ──
    .{ .label = "Copy link", .kind = .copy_link, .entry = .{
        .title = "Copy link",
        .body = "Shown when the right-click lands on a link — one the program printed as a hyperlink, or a plain `https://…` in the output. Copies the whole URL to the clipboard (the register a `p` in an editor pastes, and the system clipboard), wherever on it the click landed.",
        .links = &.{.{ .command = .{ .id = .@"term.paste", .label = "Paste it back" } }},
    } },
    .{ .label = "Open link", .kind = .open_url, .entry = .{
        .title = "Open link",
        .body = "Shown when the right-click lands on a link. Opens the URL in the OS browser — what Ctrl+click (Cmd+click) on the link does.",
        .links = &.{.{ .command = .{ .id = .@"term.copy", .label = "Copy the selection instead" } }},
    } },
    .{ .label = "Copy", .command = .@"term.copy", .entry = .{
        .title = "Copy",
        .body = "Copies the text selected in the terminal to the clipboard — the register a `p` in an editor pastes, and the system clipboard. Drag across the output to select it, double-click for a word or a path, triple-click for the line; a release copies on its own, so this row is for copying the same selection again. Hold Shift to select in a program that takes the mouse. Nothing selected says so.",
        .links = &.{ .{ .command = .{ .id = .@"term.copy", .label = "Copy the selection" } }, .{ .command = .{ .id = .@"term.paste", .label = "Paste it back" } } },
    } },
    .{ .label = "Paste", .command = .@"term.paste", .entry = .{
        .title = "Paste",
        .body = "Writes the clipboard to the child process as typed input, wrapped in bracketed-paste markers when the program asked for them, so an editor running inside the terminal takes it as a paste rather than a burst of keys. A program that did not ask gets newlines as carriage returns, which means a multi-line paste runs its lines. An empty clipboard says so and sends nothing.",
        .links = &.{ .{ .command = .{ .id = .@"term.paste", .label = "Paste it" } }, .{ .command = .{ .id = .@"term.clear", .label = "Clear the screen" } } },
    } },
    .{ .label = "Dock left", .entry = dockPane("left", "the left edge", .@"view.move_split_left") },
    .{ .label = "Dock right", .entry = dockPane("right", "the right edge", .@"view.move_split_right") },
    .{ .label = "Dock top", .entry = dockPane("top", "the top", .@"view.move_split_up") },
    .{ .label = "Dock bottom", .entry = dockPane("bottom", "the bottom", .@"view.move_split_down") },
    .{ .label = "Maximize width", .entry = maximizePane("width", "columns", "one long line", .@"view.maximize_width") },
    .{ .label = "Maximize height", .entry = maximizePane("height", "rows", "one long log", .@"view.maximize_height") },
    .{ .label = "Full screen", .entry = .{
        .title = "Full screen",
        .body = "Gives the whole terminal window to the panes, hiding the tree, the bufferline, the menu bar and the statusline — the most rows a long build log will ever get. Esc Esc comes back, and while inside, the editor body's and a tab's menus grow an *Exit full screen* row because the chrome that usually offers it is gone; this pane's does not. The splits are untouched: this hides chrome, it does not zoom one pane.",
        .keys = &.{.{ .command = .@"view.fullscreen", .label = "Full screen" }},
        .links = &.{ .{ .command = .{ .id = .@"view.fullscreen", .label = "Go full screen" } }, .{ .command = .{ .id = .@"view.toggle_zoom", .label = "Zoom the split instead" } }, .{ .command = .{ .id = .@"view.reset_layout", .label = "Reset the view" } } },
    } },
    .{ .label = "Close pane", .entry = .{
        .title = "Close pane",
        .body = "Closes this pane's tab and, for a terminal, ends the child running in it — a shell exits, a session stops. The leaf goes with it when that was its only tab and the neighbours take the room back. A terminal cannot be reopened the way a file can, so a long-running command is worth a look first.",
        .keys = &.{.{ .command = .@"buffer.close", .label = "Close the tab" }},
        .links = &.{ .{ .command = .{ .id = .@"buffer.close", .label = "Close it" } }, .{ .command = .{ .id = .@"term.restart", .label = "Restart it instead" } }, .{ .settings = .{ .row = copy.settingsRow("session.restore_terminals"), .label = "Restore terminals" } } },
    } },

    // ── a request pane's field (`openRequestFieldMenu`, titled URL /
    // Body / Headers / Response by the field the press landed on, so
    // the rows are not qualified by their menu) ──
    .{ .label = "Send", .entry = .{
        .title = "Send",
        .body = "Fires the request this pane holds — method, URL, headers and body as they stand, with the environment's `{{VAR}}` references resolved — and fills the response block with the status, timing and body when the answer lands. It goes out on a worker, so a slow endpoint never freezes the frame and a second Send is refused while one is in flight. A `{{VAR}}` nothing defines is toasted rather than blocking the send, so the URL goes out with the braces still in it.",
        .links = &.{ .{ .command = .{ .id = .@"http.send", .label = "Send it" } }, .{ .command = .{ .id = .@"http.history", .label = "Past responses" } }, ask },
    } },
    // Unqualified: the rail's HTTP section has this row too.
    .{ .label = "Paste curl from clipboard", .entry = .{
        .title = "Paste curl from clipboard",
        .body = "Reads a `curl` command off the clipboard — the one a browser's network tab copies — and fills the request's method, URL, headers and body from it, replacing what was there. It is the shortest route from a call you watched happen to one you can re-fire and edit. A `.http` request is read too; text with no URL, or with an unterminated quote, is refused rather than half-parsed.",
        .links = &.{ .{ .command = .{ .id = .@"http.paste_curl", .label = "Paste it" } }, .{ .command = .{ .id = .@"http.copy_curl", .label = "Copy back out as curl" } }, .{ .command = .{ .id = .@"http.send", .label = "Send it" } } },
    } },
    .{ .label = "Copy as curl", .entry = .{
        .title = "Copy as curl",
        .body = "Writes this request out as one `curl` command on the clipboard — method, headers, body and the resolved URL — ready to paste into a shell, a ticket or a colleague's message. Variables are written as the current environment's values, so read the line before sharing it: a token in the environment ends up in the text. Pasting one back in is the row above.",
        .links = &.{ .{ .command = .{ .id = .@"http.copy_curl", .label = "Copy it" } }, .{ .command = .{ .id = .@"http.paste_curl", .label = "Paste one in" } }, .{ .settings = .{ .row = copy.settingsRow("http.collection_root"), .label = "Where requests live" } } },
    } },
    .{ .label = "Cycle method", .entry = .{
        .title = "Cycle method",
        .body = "Steps the request's verb round the ring — GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS — without the cursor having to enter the field. The URL, headers and body are left exactly as they are, so a GET turned POST keeps a body it was already carrying. Press again to keep going; there is no way back except round.",
        .links = &.{ .{ .command = .{ .id = .@"http.cycle_method", .label = "Cycle it" } }, .{ .command = .{ .id = .@"http.send", .label = "Send it" } } },
    } },
    .{ .label = "Format body as JSON", .entry = .{
        .title = "Format body as JSON",
        .body = "Pretty-prints the Body field at two-space indent, one key to a line, which is what makes a payload pasted as one long string readable. The body has to parse as JSON: anything else is left untouched and answers `body: not JSON`, which makes this a quick syntax check before sending. It replaces the field outright and marks the request edited, so the text as it was typed is gone.",
        .links = &.{ .{ .command = .{ .id = .@"http.format_body", .label = "Format it" } }, .{ .command = .{ .id = .@"http.send", .label = "Send it" } } },
    } },
    .{ .label = "Insert header\u{2026}", .entry = .{
        .title = "Insert header…",
        .body = "Offers the headers a request usually wants — Accept, Content-Type, Authorization and the rest — and puts the chosen one into the Headers field with a value to fill in. It saves the spelling, not the value. A secret belongs in the environment file as a variable reference rather than typed here, where *Copy as curl* would carry it out.",
        .links = &.{ .{ .command = .{ .id = .@"http.insert_header", .label = "Insert one" } }, .{ .command = .{ .id = .@"http.send", .label = "Send it" } }, .{ .settings = .{ .row = copy.settingsRow("http.collection_root"), .label = "Where requests live" } } },
    } },
    .{ .label = "Switch Request \u{21c4} Response", .entry = .{
        .title = "Switch Request ⇄ Response",
        .body = "Jumps the focus down to the response block and, from there, back up to the URL field — both live in this one pane, so nothing is hidden and no second tab is opened. The response shown is the most recent send's, and editing the request does not discard it. A pane that has never been sent has an empty block to land in.",
        .links = &.{ .{ .command = .{ .id = .@"http.toggle_view", .label = "Flip it" } }, .{ .command = .{ .id = .@"http.copy_response_body", .label = "Copy the response body" } }, .{ .command = .{ .id = .@"http.history", .label = "Past responses" } } },
    } },
    .{ .label = "Copy response body", .entry = .{
        .title = "Copy response body",
        .body = "Puts the body of the last response on the clipboard on its own — no status line, no headers — ready for a file, a diff or a JSON tool. It is the bytes as they arrived, pretty-printed only if the server sent them that way. A request not yet sent has no body to take.",
        .links = &.{ .{ .command = .{ .id = .@"http.copy_response_body", .label = "Copy it" } }, .{ .command = .{ .id = .@"http.toggle_view", .label = "Back to the request" } }, .{ .command = .{ .id = .@"http.history", .label = "Past responses" } } },
    } },
    .{ .label = "Save request", .entry = .{
        .title = "Save request",
        .body = "Writes this request back to its file so it is still there tomorrow; one that came from nowhere is asked for a name and lands under `http.collection_root`. The file is plain text — a `.http` or a `.curl` — so it belongs in the repo beside the code it calls. The response is not saved with it: the history pane is where past answers live.",
        .links = &.{ .{ .command = .{ .id = .@"http.save", .label = "Save it" } }, .{ .command = .{ .id = .@"http.new_request", .label = "A new request" } }, .{ .settings = .{ .row = copy.settingsRow("http.collection_root"), .label = "Collection root" } } },
    } },

    // ── a commit row of the graph (`openGraphMenu`, titled `Commit`) ──
    .{ .menu = "Commit", .label = "Checkout this commit (detached HEAD)\u{2026}", .entry = .{
        .title = "Checkout this commit (detached HEAD)\u{2026}",
        .body = "Asks first, then runs `git checkout <sha>` on the row's commit: the working tree becomes that commit and HEAD is on no branch — the statusline and the status pane then read `HEAD detached at …`. Commits made there belong to no branch until you create one, which *New branch from here…* does. Uncommitted changes the checkout would overwrite make git refuse, with a `log` link in the toast.",
        .links = &.{ .{ .command = .{ .id = .@"git.checkout_commit", .label = "Checkout the selected commit" } }, .{ .command = .{ .id = .@"git.new_branch_from", .label = "New branch from it instead" } }, .{ .command = .{ .id = .@"git.checkout", .label = "Back onto a branch" } } },
    } },

    // ── the git graph's detail-column file rows (`git.openDetailRowMenu`,
    // titled with the file's name, so qualified by what each row runs) ──
    .{ .label = "Open diff (Enter)", .command = .@"git.graph_detail_open", .entry = .{
        .title = "Open diff",
        .body = "Opens this working-tree file's diff in a tab: the unstaged changes for an unstaged file, the staged ones for a staged file. Enter on the row does the same; a click on the row opens it too.",
        .keys = &.{.{ .chord = "Enter", .label = "Open the diff" }},
        .links = &.{.{ .command = .{ .id = .@"git.graph_detail_open", .label = "Open the diff" } }},
    } },
    .{ .label = "Open file", .command = .@"git.open_file", .entry = .{
        .title = "Open the file",
        .body = "Opens the file itself in an editor tab, as it is in the working tree now — not the diff. A deleted file has nothing to open and says so.",
        .links = &.{.{ .command = .{ .id = .@"git.open_file", .label = "Open it" } }},
    } },
    .{ .label = "Stage", .command = .@"git.stage", .entry = .{
        .title = "Stage the file",
        .body = "Adds all of this file's changes to the index, so the next commit takes them; the row moves to Staged. The row's `[+]` does the same.",
        .links = &.{ .{ .command = .{ .id = .@"git.stage", .label = "Stage it" } }, .{ .command = .{ .id = .@"git.stage_all", .label = "Stage everything" } } },
    } },
    .{ .label = "Unstage", .command = .@"git.unstage", .entry = .{
        .title = "Unstage the file",
        .body = "Takes this file's changes back out of the index; the edits stay in the file and the row moves to Unstaged. The row's `[−]` does the same.",
        .links = &.{ .{ .command = .{ .id = .@"git.unstage", .label = "Unstage it" } }, .{ .command = .{ .id = .@"git.unstage_all", .label = "Unstage everything" } } },
    } },
    .{ .label = "Discard changes\u{2026}", .command = .@"git.discard", .entry = .{
        .title = "Discard the file's changes",
        .body = "Throws away this file's uncommitted changes (`git checkout -- <file>`) after a confirm — the edits are not stashed anywhere, so the confirm is the last word. An untracked file is removed (`git clean`).",
        .links = &.{ .{ .command = .{ .id = .@"git.discard", .label = "Discard" } }, .{ .command = .{ .id = .@"git.stash_file", .label = "Stash it instead" } } },
    } },
    .{ .label = "Stash this file\u{2026}", .command = .@"git.stash_file", .entry = .{
        .title = "Stash this file",
        .body = "Stashes this file's changes alone, asking for an optional message; the rest of the working tree is untouched. The STASHES section lists the entry and Pop brings it back.",
        .links = &.{ .{ .command = .{ .id = .@"git.stash_file", .label = "Stash it" } }, .{ .command = .{ .id = .@"git.stash_pop", .label = "Pop the newest stash" } } },
    } },
    .{ .label = "Copy path (", .prefix = true, .kind = .copy_text, .entry = .{
        .title = "Copy the file's path",
        .body = "Copies the path in brackets — relative to the repository's root, as git names it — to the clipboard. Nothing else changes.",
    } },
    .{ .label = "Open the file's diff in this commit (Enter)", .command = .@"git.graph_detail_open", .entry = .{
        .title = "Open the file's diff in this commit",
        .body = "Opens what this commit changed in the file, as a diff against its parent, in a tab. Enter on the row does the same.",
        .keys = &.{.{ .chord = "Enter", .label = "Open the diff" }},
        .links = &.{.{ .command = .{ .id = .@"git.graph_detail_open", .label = "Open the diff" } }},
    } },
    .{ .label = "Open file at this revision", .command = .@"git.graph_file_at_rev", .entry = .{
        .title = "Open the file at this revision",
        .body = "Opens the file as it was in this commit (`git show <commit>:<path>`) in a buffer of its own — the working tree's copy is not touched.",
        .links = &.{.{ .command = .{ .id = .@"git.graph_file_at_rev", .label = "Open it" } }},
    } },
    .{ .label = "Browse commit on remote", .command = .@"git.browse_commit", .entry = .{
        .title = "Browse the commit on the remote",
        .body = "Opens the selected commit's page on the repository's web host in the OS browser, built from the `origin` remote's URL. A repository with no `origin` says so in a toast instead.",
        .links = &.{.{ .command = .{ .id = .@"git.browse_commit", .label = "Browse it" } }},
    } },
    .{ .label = "Copy commit hash (", .prefix = true, .kind = .copy_text, .entry = .{
        .title = "Copy the commit's hash",
        .body = "Copies the full hash of the selected commit to the clipboard; the short form is the one in brackets.",
    } },
    // ── sessiondiff: a SESSIONS card's row menu (titled `Session`) ──
    .{ .menu = "Session", .label = "What did this session change", .command = .@"sessions.changes", .entry = .{
        .title = "What did this session change",
        .body = "Opens the files this session changed since its pane started, as a git status pane scoped to them: what is still uncommitted (unstaged and staged) and what it committed since. Enter diffs a file, `s` / `u` stage it, the Commit… row commits with the session's title as the message. A file another session also touched names that session.",
        .links = &.{ .{ .command = .{ .id = .@"sessions.changes", .label = "Open it" } }, .{ .command = .{ .id = .@"sessions.refresh", .label = "Read git again" } } },
    } },
    // ── a SESSIONS card's (or the table's) links: one `Open <words>`
    // row per address the session shows ──
    .{ .menu = "Session", .label = "Open ", .prefix = true, .kind = .open_url, .entry = .{
        .title = "Open a link the session shows",
        .body = "Opens one of the links on this session — a URL in its output or its name, or a key an installed integration declares (a ticket such as `ENG-123` opens that integration's page for it) — in the OS browser, or the one `ui.external_browser` names. One row per address, at most six; the same as clicking the underlined words on the card. A key links only when an integration's manifest declares its shape, so with none installed only URLs are listed.",
        .keys = &.{.{ .command = .@"view.context_menu_at_focus", .label = "This menu, on the focused card" }},
        .links = &.{.{ .command = .{ .id = .@"integrations.show_installed", .label = "The installed integrations" } }},
    } },
    // ── sessiondiff: the changes view's row menu (`Session changes`) ──
    .{ .menu = "Session changes", .label = "Open diff", .entry = .{
        .title = "Open the file's diff",
        .body = "The row's change as a diff pane: an unstaged file against the index, a staged one the index against HEAD, and a file the session committed from the session's starting HEAD to now. An untracked file has no diff yet — stage it first. The same as Enter on the row.",
        .links = &.{ .{ .command = .{ .id = .@"git.diff_file", .label = "Open it" } }, .{ .command = .{ .id = .@"git.diff_toggle_view", .label = "Split / unified" } } },
    } },
    .{ .menu = "Session changes", .label = "Open file", .entry = .{
        .title = "Open the file",
        .body = "Opens the row's file in an editor, from the session's own checkout — a session in a worktree opens the worktree's copy, not the workspace's. Nothing is staged or changed by opening it.",
        .links = &.{.{ .command = .{ .id = .@"git.open_file", .label = "Open it" } }},
    } },
    .{ .menu = "Session changes", .label = "Stage", .entry = .{
        .title = "Stage the file",
        .body = "Adds the row's file to the index of the session's repo, as `s` does; it moves from Unstaged to Staged when the worker answers. A committed row has nothing to stage — the view says so.",
        .links = &.{ .{ .command = .{ .id = .@"git.stage", .label = "Stage it" } }, .{ .command = .{ .id = .@"git.unstage", .label = "Unstage it" } } },
    } },
    .{ .menu = "Session changes", .label = "Unstage", .entry = .{
        .title = "Unstage the file",
        .body = "Takes the row's file back out of the index of the session's repo, as `u` does; the edit stays in the working tree. A row that is not staged only says so.",
        .links = &.{ .{ .command = .{ .id = .@"git.unstage", .label = "Unstage it" } }, .{ .command = .{ .id = .@"git.stage", .label = "Stage it" } } },
    } },
    .{ .menu = "Session changes", .label = "Commit\u{2026}", .entry = .{
        .title = "Commit the session's work",
        .body = "Opens the commit prompt for the session's repo with the session's title already in it — Enter keeps it, typing replaces it. It commits what is staged there, so stage the session's rows first; anything else staged in that repo goes in too.",
        .links = &.{.{ .command = .{ .id = .@"git.commit", .label = "Commit" } }},
    } },
    .{ .menu = "Session changes", .label = "Refresh", .entry = .{
        .title = "Read git again",
        .body = "Recomputes what every session changed through the git worker — the status, the commits since each session's HEAD, the mtimes. The view also follows the repo's status on its own; this is for a change git's status cannot see, such as a file touched again while already dirty.",
        .links = &.{.{ .command = .{ .id = .@"sessions.refresh", .label = "Refresh" } }},
    } },
};

/// The pty body's four `Dock <edge>` rows: where the pane is moved to
/// inside the split it lives in.
fn dockPane(comptime edge: []const u8, comptime where: []const u8, comptime id: command.CommandId) Entry {
    return .{
        .title = "Dock " ++ edge,
        .body = "Moves this pane to " ++ where ++ " of the whole window, rebuilding the layout around it — vim's Ctrl+W move, from a menu. The pane keeps its contents, its scrollback and its focus; only where it sits changes. With only one pane there is nowhere to move to: it says so and the layout stays as it was.",
        .links = &.{ .{ .command = .{ .id = id, .label = "Dock it " ++ edge } }, .{ .command = .{ .id = .@"view.equalize_splits", .label = "Equalize the splits" } }, .{ .command = .{ .id = .@"view.reset_layout", .label = "Reset the view" } } },
    };
}

/// Its two `Maximize <axis>` rows: this pane takes the room on that
/// axis and its neighbours keep a sliver.
fn maximizePane(comptime axis: []const u8, comptime unit: []const u8, comptime what_for: []const u8, comptime id: command.CommandId) Entry {
    return .{
        .title = "Maximize " ++ axis,
        .body = "Gives this pane as many " ++ unit ++ " as the layout will spare, squeezing its neighbours on that axis down to a sliver rather than closing them — the view for " ++ what_for ++ ", with everything else still on screen. The other axis is untouched. Equalize splits shares the room out evenly again, and the divider can be dragged instead.",
        .links = &.{ .{ .command = .{ .id = id, .label = "Maximize the " ++ axis } }, .{ .command = .{ .id = .@"view.equalize_splits", .label = "Equalize the splits" } }, .{ .command = .{ .id = .@"view.toggle_zoom", .label = "Zoom the split instead" } } },
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
        std.debug.print("panes: no entry for `{s}` in menu `{s}`\n", .{ label, app.overlay.menu.title });
        return error.Uncovered;
    }
}

test "panes: every row of the editor, gutter, tree, workspace, breadcrumb, welcome, link, toast, AI and request menus resolves to a curated entry" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const cm = @import("../../context_menus.zig");
    _ = try app.openScratch();

    try cm.openEditorMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try cm.openGutterMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    // The tree rows. `/tmp` normally has entries; an empty one is not
    // a failure of the dictionary, so the walk is skipped then.
    try app.tree.refresh(&app);
    if (app.tree.rows.items.len > 0) {
        try cm.openTreeMenu(&app, 0, 5, 5);
        try expectCurated(&app);
        closeMenu(&app);
        // A file row carries `Open` / `Open in split` where a folder
        // row carries the two fold rows.
        for (app.tree.rows.items, 0..) |row, i| {
            if (row.is_dir or row.header) continue;
            try cm.openTreeMenu(&app, i, 5, 5);
            try expectCurated(&app);
            closeMenu(&app);
            break;
        }
    }

    // Root 0 gets the fold and new-file rows; a root past it gets the
    // three rows about itself.
    try cm.openWorkspaceHeaderMenu(&app, 0, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);
    try cm.openWorkspaceHeaderMenu(&app, 1, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try cm.openBreadcrumbMenu(&app, "src", 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try cm.openWelcomeRecentMenu(&app, "README.md", 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try cm.openLinkMenu(&app, "https://example.com/", 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    app.toast("x", .{});
    try cm.openToastMenu(&app, 0, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    try cm.openAiPaneMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    // The request-field menu needs no request pane: its rows are
    // static and the field only titles the menu.
    try cm.openRequestFieldMenu(&app, .url, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);
    try cm.openRequestFieldMenu(&app, .response, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    // A pty is too costly to spawn here, so its own rows are checked
    // by label instead (the menu is titled by the pane's name).
    try t.expectEqualStrings("Dock left", menus.lookup("bash", null, "Dock left").?.title);
    try t.expectEqualStrings("Maximize height", menus.lookup("bash", null, "Maximize height").?.title);
    try t.expectEqualStrings("Close pane", menus.lookup("bash", null, "Close pane").?.title);

    // The shared labels tell each other apart by what the row runs.
    try t.expect(std.mem.indexOf(u8, menus.lookupItem("Editor", null, "Cut", .{ .command = .@"editor.cut" }).?.body, "out of the buffer") != null);
    try t.expect(std.mem.indexOf(u8, menus.lookupItem("src", null, "Cut", .{ .command = .@"file.cut" }).?.body, "file clipboard") != null);
    try t.expect(std.mem.indexOf(u8, menus.lookupItem("Editor", null, "Paste", .{ .command = .@"editor.paste" }).?.body, "at the cursor") != null);
    try t.expect(std.mem.indexOf(u8, menus.lookupItem("bash", null, "Paste", .{ .command = .@"term.paste" }).?.body, "child process") != null);
    // `Copy path` is a command on a tree row and a carried string on a
    // workspace header, a breadcrumb and a welcome row.
    try t.expect(std.mem.indexOf(u8, menus.lookupItem("src", null, "Copy path", .{ .command = .@"file.copy_path" }).?.body, "workspace-relative path") != null);
    try t.expect(std.mem.indexOf(u8, menus.lookupItem("mnml", null, "Copy path", .{ .copy_text = "/x" }).?.body, "this row itself names") != null);
    // `Open` is the tree's command and the welcome row's carried path.
    try t.expect(std.mem.indexOf(u8, menus.lookupItem("src", null, "Open", .{ .command = .@"tree.open_selected" }).?.body, "in the active leaf") != null);
    try t.expect(std.mem.indexOf(u8, menus.lookupItem("README.md", null, "Open", .{ .open_path = "/x" }).?.body, "recent list") != null);
}
