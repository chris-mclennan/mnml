//! Hover help for the menu bar's dropdowns (`app/menu_bar.zig`): the
//! brand menu and File / Edit / Selection / View / Go / Run / Terminal
//! / Window / Help, keyed by the dropdown's title, plus the `Menu bar`
//! menu a right press on a word or the pin chip opens. The File menu's
//! recent-files submenu is a family: one row per file, named.

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
    // ── the brand menu (`❯_ mnml`), and the gear's shared rows ──
    .{ .menu = "mnml", .label = "About mnml…", .entry = .{
        .title = "About mnml…",
        .body = "Opens the About box: the version, the workspace, how many of the registry's commands are implemented, which keymap profile is live and how many bindings it has, and the zig it was built with. Copy those five lines into a bug report — they are what a maintainer asks for first. Checking for a newer release is a separate command.",
        .links = &.{ .{ .command = .{ .id = .@"view.about", .label = "Open it" } }, .{ .command = .{ .id = .@"app.check_updates", .label = "Check for a newer release" } } },
    } },
    .{ .menu = "mnml", .label = "Settings…", .entry = .{
        .title = "Settings…",
        .body = "Opens the Settings overlay — every everyday switch as a sectioned list: UI, Editor, AI, Integrations. A row's arrows change it, Enter writes the home config, Esc puts the opened state back; `/` filters. The config keys the overlay does not show are edited in `config.zon` by hand.",
        .keys = &.{.{ .command = .@"view.settings", .label = "Settings" }},
        .links = &.{ .{ .command = .{ .id = .@"view.settings", .label = "Open it" } }, copy.docsSection("The settings overlay") },
    } },
    .{ .menu = "mnml", .label = "Quit mnml", .entry = .{
        .title = "Quit mnml",
        .body = "Ends the session: every dirty buffer is listed in one box first — save all, discard all, or cancel — and `ui.confirm_quit` asks once more even when nothing is dirty. Tabs, splits and (with `session.restore_terminals`) terminals are written to the session on the way out and come back on the next launch.",
        .keys = &.{.{ .command = .@"app.quit", .label = "Quit" }},
        .links = &.{ .{ .command = .{ .id = .@"file.save_all", .label = "Save all first" } }, .{ .settings = .{ .row = copy.settingsRow("ui.confirm_quit"), .label = "Confirm on quit" } }, .{ .settings = .{ .row = copy.settingsRow("session.restore"), .label = "Restore the session" } } },
    } },
    // ── File ──
    .{ .menu = "File", .label = "New file", .entry = .{
        .title = "New file",
        .body = "With the tree focused it asks for a path relative to the workspace, makes the folders on the way and opens the file in a new tab; a name that already exists is opened, never overwritten. From anywhere else it asks too, relative to the workspace root; a tree row's own menu asks inside that row's folder. `:enew` is the way to an untitled scratch buffer.",
        .keys = &.{.{ .command = .@"file.new", .label = "New file" }},
        .links = &.{ .{ .command = .{ .id = .@"file.new", .label = "New file" } }, .{ .command = .{ .id = .@"file.new_folder", .label = "New folder" } }, .{ .command = .{ .id = .@"scratch.new", .label = "A scratch buffer instead" } } },
    } },
    .{ .menu = "File", .label = "Open file…", .entry = .{
        .title = "Open file…",
        .body = "Opens the fuzzy file picker over the workspace — type any part of a path and Enter opens the match in the active leaf; the preview column shows the file under the cursor. Ignored files are never listed — the query cannot reach them; the file browser pane shows them.",
        .keys = &.{.{ .command = .@"picker.files", .label = "Open file" }},
        .links = &.{ .{ .command = .{ .id = .@"picker.files", .label = "The file picker" } }, .{ .command = .{ .id = .@"picker.recent", .label = "Recent files" } }, .{ .command = .{ .id = .@"files.open", .label = "A file browser pane" } } },
    } },
    .{ .menu = "File", .label = "Add folder to workspace…", .entry = .{
        .title = "Add folder to workspace…",
        .body = "Asks for a folder and adds it as another root under its own header in the tree, beside the workspace you have — search, grep and the git scan cover both. It lasts only while mnml is running — nothing writes it down, so a restart drops it: Manage workspaces… is where a root is kept for good, and Switch workspace… swaps rather than adds.",
        .links = &.{ .{ .command = .{ .id = .@"view.add_workspace", .label = "Add a folder" } }, .{ .command = .{ .id = .@"view.manage_workspaces", .label = "Manage workspaces" } }, .{ .command = .{ .id = .@"view.switch_workspace", .label = "Switch instead" } } },
    } },
    .{ .menu = "File", .label = "Open recent file", .entry = .{
        .title = "Open recent file",
        .body = "Opens to the right with the ten files opened most recently, newest first — a click opens one in the active leaf. The list is per workspace and survives a restart; Clear recent files at its foot empties it. The same list is a picker with a preview under `picker.recent`.",
        .keys = &.{ .{ .chord = "→ / ←", .label = "Open / close the submenu" }, .{ .command = .@"picker.recent", .label = "Recent files as a picker" } },
        .links = &.{ .{ .command = .{ .id = .@"picker.recent", .label = "The recent-files picker" } }, .{ .command = .{ .id = .@"file.clear_recent", .label = "Clear the list" } } },
    } },
    .{ .menu = "File", .parent = "Open recent file", .label = "Clear recent files", .entry = .{
        .title = "Clear recent files",
        .body = "Empties the recent-files list for this workspace — the submenu, the picker and the welcome screen's rows all read the same list. The files themselves are untouched; the next open starts the list again.",
        .links = &.{ .{ .command = .{ .id = .@"file.clear_recent", .label = "Clear it" } }, .{ .command = .{ .id = .@"picker.recent", .label = "The recent-files picker" } } },
    } },
    .{ .menu = "File", .parent = "Open recent file", .label = "(no recent files)", .entry = .{
        .title = "(no recent files)",
        .body = "A placeholder: nothing has been opened in this workspace yet, so there is nothing to list. Open a file from the tree or the picker and it takes the first row here.",
        .links = &.{ .{ .command = .{ .id = .@"picker.files", .label = "Open a file" } }, .{ .command = .{ .id = .@"view.welcome", .label = "The welcome screen" } } },
    } },
    .{ .menu = "File", .label = "Switch workspace…", .entry = .{
        .title = "Switch workspace…",
        .body = "Opens the workspace picker — the primary, the extras added this session and the ones the config lists — and swaps the tree, the panels and the git chip to the one picked; open tabs stay open. Add folder to workspace… keeps the current root and adds one beside it instead.",
        .keys = &.{.{ .command = .@"view.switch_workspace", .label = "Switch workspace" }},
        .links = &.{ .{ .command = .{ .id = .@"view.switch_workspace", .label = "Pick a workspace" } }, .{ .command = .{ .id = .@"view.manage_workspaces", .label = "Manage the list" } }, .{ .command = .{ .id = .@"git.worktrees", .label = "Open a worktree" } } },
    } },
    .{ .menu = "File", .label = "Save", .entry = .{
        .title = "Save",
        .body = "Writes the active buffer to disk; an untitled scratch buffer opens Save As for a path (vim users are told to use `:w <path>`). `editor.format_on_save`, the trailing-whitespace trim (when `editor.trim_trailing_ws_on_save` is on) and the final-newline rule run on the way out, so the text can change a little under the cursor. A file changed on disk since it was read is overwritten without a question — the watcher's toast beforehand is the only warning.",
        .keys = &.{.{ .command = .@"file.save", .label = "Save" }},
        .links = &.{ .{ .command = .{ .id = .@"file.save", .label = "Save now" } }, .{ .settings = .{ .row = copy.settingsRow("editor.format_on_save"), .label = "Format on save" } }, .{ .settings = .{ .row = copy.settingsRow("editor.trim_trailing_ws_on_save"), .label = "Trim trailing whitespace" } } },
    } },
    .{ .menu = "File", .label = "Save all", .entry = .{
        .title = "Save all",
        .body = "Writes every dirty buffer in one pass — every leaf, every tab page — and the dirty dots on the tabs clear as each lands. Untitled scratch buffers are skipped rather than prompted for a path each; save those one by one. The first file that will not write stops the pass — the ones after it are still dirty.",
        .links = &.{ .{ .command = .{ .id = .@"file.save_all", .label = "Save all now" } }, .{ .command = .{ .id = .@"buffer.next_dirty", .label = "Go to the next unsaved buffer" } }, ask },
    } },
    .{ .menu = "File", .label = "Close tab", .entry = .{
        .title = "Close tab",
        .body = "Closes the active tab of the active leaf; a dirty buffer asks first — save, discard, or cancel. Closing the leaf's last tab collapses the split — the neighbour takes its space. Reopen closed tab brings the buffer back with its cursor where it was.",
        .keys = &.{ .{ .command = .@"buffer.close", .label = "Close tab" }, .{ .command = .@"buffer.reopen", .label = "Reopen the last closed" } },
        .links = &.{ .{ .command = .{ .id = .@"buffer.close", .label = "Close it" } }, .{ .command = .{ .id = .@"buffer.reopen", .label = "Reopen the last closed" } }, .{ .command = .{ .id = .@"buffer.close_others", .label = "Close the others instead" } } },
    } },
    .{ .menu = "File", .label = "Settings…", .entry = .{
        .title = "Settings…",
        .body = "Opens the Settings overlay — the everyday switches as a sectioned list: UI, Editor, AI, Integrations. A row's arrows change it, Enter writes the home config, Esc puts the opened state back; `/` filters. The brand menu's Settings… is the same overlay.",
        .keys = &.{.{ .command = .@"view.settings", .label = "Settings" }},
        .links = &.{ .{ .command = .{ .id = .@"view.settings", .label = "Open it" } }, .{ .command = .{ .id = .@"file.open_settings", .label = "Edit the config file instead" } }, copy.docsSection("The settings overlay") },
    } },
    .{ .menu = "File", .label = "Quit", .entry = .{
        .title = "Quit",
        .body = "Ends the session the way the brand menu's Quit mnml does: dirty buffers are listed in one box first — save all, discard all, or cancel — and `ui.confirm_quit` asks once more even when nothing is dirty. The session is written on the way out and restored on the next launch.",
        .keys = &.{.{ .command = .@"app.quit", .label = "Quit" }},
        .links = &.{ .{ .command = .{ .id = .@"file.save_all", .label = "Save all first" } }, .{ .settings = .{ .row = copy.settingsRow("ui.confirm_quit"), .label = "Confirm on quit" } } },
    } },
    // ── Edit ──
    .{ .menu = "Edit", .label = "Find…", .entry = .{
        .title = "Find…",
        .body = "Opens the find bar under the active editor: the matches highlight as you type, Enter jumps to the next and keeps the highlights behind; Esc backs the search out entirely, highlights and all. Alt+R makes the query a regex, Alt+C matches case, Alt+W whole words only (the vim profile's `/` is always a vim pattern); the statusline's Find chip counts the matches and its menu clears them.",
        .keys = &.{ .{ .command = .@"find.find", .label = "Find" }, .{ .command = .@"find.toggle_regex", .label = "Regex on / off" } },
        .links = &.{ .{ .command = .{ .id = .@"find.find", .label = "Open the find bar" } }, .{ .command = .{ .id = .@"find.replace", .label = "Replace the matches" } }, .{ .command = .{ .id = .@"find.grep", .label = "Search the workspace instead" } } },
    } },
    .{ .menu = "Edit", .label = "Find next", .entry = .{
        .title = "Find next",
        .body = "Moves the cursor to the next match of the last search, wrapping from the end of the buffer to the top; the Find chip's counter reads `3/12` as it goes. With no search yet it toasts — Find… first.",
        .keys = &.{ .{ .command = .@"find.next", .label = "Next match" }, .{ .command = .@"find.prev", .label = "Previous match" } },
        .links = &.{ .{ .command = .{ .id = .@"find.next", .label = "Next match" } }, .{ .command = .{ .id = .@"find.find", .label = "Start a search" } } },
    } },
    .{ .menu = "Edit", .label = "Find previous", .entry = .{
        .title = "Find previous",
        .body = "Moves the cursor to the previous match of the last search, wrapping from the top of the buffer to the end — the reverse of Find next on the same query. With no search yet it toasts.",
        .keys = &.{ .{ .command = .@"find.prev", .label = "Previous match" }, .{ .command = .@"find.next", .label = "Next match" } },
        .links = &.{ .{ .command = .{ .id = .@"find.prev", .label = "Previous match" } }, .{ .command = .{ .id = .@"find.find", .label = "Start a search" } } },
    } },
    .{ .menu = "Edit", .label = "Replace…", .entry = .{
        .title = "Replace…",
        .body = "Opens the find bar with its Replace row, the active search already in the Find field. Tab moves between the two fields; Enter in Replace swaps the current match and moves to the next, one Undo step each; Ctrl+Alt+Enter replaces every match as one edit that Undo takes back whole. Alt+C, Alt+W and Alt+R turn on match case, whole word and regex (`$1` names a group). Esc closes the bar and leaves the current match selected. The vim profile asks for one replacement for every match instead, and `:%s` is its everyday tool. Replace in files… is the workspace-wide twin.",
        .keys = &.{.{ .command = .@"find.replace", .label = "Replace" }},
        .links = &.{ .{ .command = .{ .id = .@"find.replace", .label = "Replace in this buffer" } }, .{ .command = .{ .id = .@"find.find", .label = "Set the search" } }, .{ .command = .{ .id = .@"find.grep_replace", .label = "Replace across files" } } },
    } },
    .{ .menu = "Edit", .label = "Find in files…", .entry = .{
        .title = "Find in files…",
        .body = "Asks for a query and greps the workspace with `rg`, falling back to its own walk when `rg` is not installed, opening the hits as a grep pane — one row per match, Enter opens the file at that line, each row has a tick for Replace in files…. Ignored files follow the tool's rules; the rail's SEARCH section can hand its query to a pane, but the two do not stay in step.",
        .keys = &.{.{ .command = .@"find.grep", .label = "Find in files" }},
        .links = &.{ .{ .command = .{ .id = .@"find.grep", .label = "Grep the workspace" } }, .{ .command = .{ .id = .@"find.live_grep", .label = "Live grep with a preview" } }, .{ .command = .{ .id = .@"find.grep_replace", .label = "Replace in files" } } },
    } },
    .{ .menu = "Edit", .label = "Replace in files…", .entry = .{
        .title = "Replace in files…",
        .body = "Applies a replacement to every ticked hit in the active grep pane, writing each file to disk — the workspace-wide twin of Replace…. Untick the rows to keep before firing: there is no undo across files beyond git, so a dirty tree is worth a look in the status pane first. A hit inside an open buffer with unsaved edits is skipped, and the report's warning toast counts it — save first.",
        .links = &.{ .{ .command = .{ .id = .@"find.grep_replace", .label = "Replace in files" } }, .{ .command = .{ .id = .@"git.status_pane", .label = "Check the tree in git" } }, ask },
    } },
    // ── Selection ──
    .{ .menu = "Selection", .label = "Expand selection", .entry = .{
        .title = "Expand selection",
        .body = "Grows the selection to the next enclosing syntax node — word, expression, statement, block — from the language server's selection ranges; again grows it another step, and Shrink selection walks back down the same steps. With no server for the buffer it does nothing and says which one is missing — the LSP chip in the statusline is where you start it.",
        .links = &.{ .{ .command = .{ .id = .@"lsp.selection_expand", .label = "Expand" } }, .{ .command = .{ .id = .@"lsp.selection_shrink", .label = "Shrink" } }, .{ .command = .{ .id = .@"lsp.status", .label = "Which servers are running" } } },
    } },
    .{ .menu = "Selection", .label = "Shrink selection", .entry = .{
        .title = "Shrink selection",
        .body = "Shrinks the selection back to the node it grew from — the reverse of Expand selection, one step at a time down the same list of ranges. It has nothing to do until Expand selection has grown something.",
        .links = &.{ .{ .command = .{ .id = .@"lsp.selection_shrink", .label = "Shrink" } }, .{ .command = .{ .id = .@"lsp.selection_expand", .label = "Expand" } } },
    } },
    .{ .menu = "Selection", .label = "Add cursor above", .entry = .{
        .title = "Add cursor above",
        .body = "Adds a second cursor on the line above the primary one, in the same column, so the next keystrokes land on both lines; again stacks another line up. Esc or Clear extra cursors goes back to one.",
        .keys = &.{ .{ .command = .@"editor.add_cursor_above", .label = "Cursor above" }, .{ .command = .@"editor.add_cursor_below", .label = "Cursor below" } },
        .links = &.{ .{ .command = .{ .id = .@"editor.add_cursor_above", .label = "Add one above" } }, .{ .command = .{ .id = .@"editor.clear_extra_cursors", .label = "Back to one cursor" } } },
    } },
    .{ .menu = "Selection", .label = "Add cursor below", .entry = .{
        .title = "Add cursor below",
        .body = "Adds a second cursor on the line below the primary one, in the same column, so the next keystrokes land on both lines; again stacks another line down. A short line puts its cursor at its end. Esc or Clear extra cursors goes back to one.",
        .keys = &.{ .{ .command = .@"editor.add_cursor_below", .label = "Cursor below" }, .{ .command = .@"editor.add_cursor_above", .label = "Cursor above" } },
        .links = &.{ .{ .command = .{ .id = .@"editor.add_cursor_below", .label = "Add one below" } }, .{ .command = .{ .id = .@"editor.clear_extra_cursors", .label = "Back to one cursor" } } },
    } },
    .{ .menu = "Selection", .label = "Add cursor at next match", .entry = .{
        .title = "Add cursor at next match",
        .body = "Selects the word under the cursor, and each further press adds a cursor at the next occurrence of it — VS Code's Ctrl+D — so a rename across a few lines is typed once. It searches forward only and does not wrap to the top of the buffer. Select all occurrences takes every one at once; a rename that should follow the code's meaning is the LSP's Rename symbol.",
        .keys = &.{.{ .command = .@"editor.add_cursor_at_next_word", .label = "Next match" }},
        .links = &.{ .{ .command = .{ .id = .@"editor.add_cursor_at_next_word", .label = "Add the next" } }, .{ .command = .{ .id = .@"editor.select_all_occurrences", .label = "Take them all" } }, .{ .command = .{ .id = .@"lsp.rename", .label = "Rename the symbol instead" } } },
    } },
    .{ .menu = "Selection", .label = "Select all occurrences", .entry = .{
        .title = "Select all occurrences",
        .body = "Puts a cursor on every occurrence of the word under the cursor in this buffer at once — the whole-file form of Add cursor at next match — so one edit lands everywhere. It is a plain text match, comments and strings included, and a cursor that is not on a word does nothing; Rename symbol is the one that knows the code.",
        .keys = &.{.{ .command = .@"editor.select_all_occurrences", .label = "Select all occurrences" }},
        .links = &.{ .{ .command = .{ .id = .@"editor.select_all_occurrences", .label = "Select them all" } }, .{ .command = .{ .id = .@"editor.clear_extra_cursors", .label = "Back to one cursor" } }, .{ .command = .{ .id = .@"lsp.rename", .label = "Rename the symbol instead" } } },
    } },
    .{ .menu = "Selection", .label = "Clear extra cursors", .entry = .{
        .title = "Clear extra cursors",
        .body = "Drops every cursor but the primary one and returns to single-cursor editing; the primary keeps its place. Esc does the same in the standard profile.",
        .links = &.{ .{ .command = .{ .id = .@"editor.clear_extra_cursors", .label = "Clear them" } }, .{ .command = .{ .id = .@"find.clear_and_deselect", .label = "Clear the find highlights too" } } },
    } },
    // ── View ──
    .{ .menu = "View", .label = "File browser pane", .entry = .{
        .title = "File browser pane",
        .body = "Opens a Files pane at the workspace root — a file manager as an ordinary tab: arrows and Enter walk the folders, Space marks rows, cut / copy / paste and Delete work on the marks, transfers run in the background. It splits and tab-pages like any pane; the workspace trash is one of its destinations.",
        .links = &.{ .{ .command = .{ .id = .@"files.open", .label = "Open a file browser" } }, .{ .command = .{ .id = .@"files.open_split", .label = "Two, side by side" } }, .{ .command = .{ .id = .@"files.trash", .label = "The workspace trash" } } },
    } },
    .{ .menu = "View", .label = "Dual file panes (commander)", .entry = .{
        .title = "Dual file panes (commander)",
        .body = "Opens two Files panes side by side — the commander layout: mark rows on one side, paste on the other, and the move happens without typing a destination. Each side keeps its own folder, sort and marks; a click moves between them, as between any two splits.",
        .links = &.{ .{ .command = .{ .id = .@"files.open_split", .label = "Open the pair" } }, .{ .command = .{ .id = .@"files.open", .label = "One pane instead" } } },
    } },
    .{ .menu = "View", .label = "Command palette", .entry = .{
        .title = "Command palette",
        .body = "Opens the palette over every registered command — type to fuzzy-match a title or an id, Enter runs it; the ★ rows at the top are the ones run recently. The chord beside a row is its binding in the active profile, so the palette is also where a shortcut is looked up.",
        .keys = &.{.{ .command = .palette, .label = "Command palette" }},
        .links = &.{ .{ .command = .{ .id = .palette, .label = "Open the palette" } }, .{ .command = .{ .id = .@"picker.recent_commands", .label = "Recent commands only" } }, .{ .command = .{ .id = .@"view.cheatsheet", .label = "The cheatsheet" } } },
    } },
    .{ .menu = "View", .label = "Toggle left panel", .entry = .{
        .title = "Toggle left panel",
        .body = "Shows or hides the left column — the tree and whichever rail section sits on that side — and the editor takes the width. Under `ui.sidebar = auto` the column comes back on its own when the pointer reaches the screen edge; hidden is the mode that stays away until asked.",
        .keys = &.{ .{ .command = .@"view.toggle_tree", .label = "Toggle the left column" }, .{ .command = .@"view.focus_tree", .label = "Focus the tree" } },
        .links = &.{ .{ .command = .{ .id = .@"view.toggle_tree", .label = "Toggle it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.sidebar"), .label = "Sidebar mode" } }, .{ .settings = .{ .row = copy.settingsRow("ui.tree_width"), .label = "Tree width" } } },
    } },
    .{ .menu = "View", .label = "Toggle right panel", .entry = .{
        .title = "Toggle right panel",
        .body = "Shows or hides the right column — the outline, the problems list and any rail section moved there with its menu's Move to right side. Its width is `ui.right_panel_width`; showing a section on that side opens the column by itself.",
        .keys = &.{.{ .command = .@"view.toggle_right_panel", .label = "Toggle the right column" }},
        .links = &.{ .{ .command = .{ .id = .@"view.toggle_right_panel", .label = "Toggle it" } }, .{ .command = .{ .id = .@"outline.show", .label = "Show the outline there" } }, .{ .settings = .{ .row = copy.settingsRow("ui.right_panel_width"), .label = "Right column width" } } },
    } },
    .{ .menu = "View", .label = "Toggle bottom panel", .entry = .{
        .title = "Toggle bottom panel",
        .body = "Shows or hides the bottom dock — the rail sections moved down with Move to bottom dock, and the debug console. Its height is `ui.bottom_panel_height`. The scratch terminal is a separate strip with a toggle of its own.",
        .keys = &.{ .{ .command = .@"view.toggle_bottom_panel", .label = "Toggle the bottom dock" }, .{ .command = .@"term.scratch_toggle", .label = "The scratch terminal" } },
        .links = &.{ .{ .command = .{ .id = .@"view.toggle_bottom_panel", .label = "Toggle it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.bottom_panel_height"), .label = "Bottom dock height" } }, .{ .command = .{ .id = .@"dap.repl", .label = "The debug console" } } },
    } },
    .{ .menu = "View", .label = "Cycle menu bar (always / auto / hidden)", .entry = .{
        .title = "Cycle menu bar (always / auto / hidden)",
        .body = "Steps `ui.menu_bar` to its next mode and writes it to the home config: always keeps the words on screen, auto keeps them away until the pointer rests on the top row, hidden keeps them away for good — even Alt+letter and F10 are dead there, so the palette is the way to those rows. Under auto the pin chip keeps the bar up for the session.",
        .links = &.{ .{ .command = .{ .id = .@"view.menu_bar_cycle", .label = "Cycle it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.menu_bar"), .label = "Menu bar in Settings" } }, .{ .command = .{ .id = .@"view.menu_bar_pin", .label = "Pin the bar" } } },
    } },
    .{ .menu = "View", .label = "Toggle line wrap", .entry = .{
        .title = "Toggle line wrap",
        .body = "Wraps long lines at the pane's edge for the active editor — the WRAP chip in the statusline reads the state — for the active editor alone — the next file you open goes back to `ui.wrap`. With no editor focused the row flips `ui.wrap` itself, for this session. Wrapping changes what a screen line is: the vim motions still move by buffer line.",
        .links = &.{ .{ .command = .{ .id = .@"view.toggle_wrap", .label = "Toggle it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.wrap"), .label = "Wrap in Settings" } }, .{ .settings = .{ .row = copy.settingsRow("editor.text_width"), .label = "Text width" } } },
    } },
    .{ .menu = "View", .label = "Enter full screen", .entry = fullScreen("Enter full screen") },
    .{ .menu = "View", .label = "Exit full screen", .entry = fullScreen("Exit full screen") },
    .{ .menu = "View", .label = "Toggle hover-help", .entry = .{
        .title = "Toggle hover-help",
        .body = "Shows or hides this info box at the bottom of the left column — the curated help for whatever the pointer rests on — and flips `ui.hover_help` for this session; it is not written, so the next launch reads the config again and Settings → UI is where the switch is made to stick. The small tooltip beside the pointer is a separate switch (`ui.hover_tooltip`); once the box is off, Settings → UI or this row brings it back.",
        .links = &.{ .{ .command = .{ .id = .@"view.toggle_hover_help", .label = "Toggle it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.hover_help"), .label = "Hover help in Settings" } }, .{ .settings = .{ .row = copy.settingsRow("ui.hover_tooltip"), .label = "The pointer tooltip" } } },
    } },
    .{ .menu = "View", .label = "Toggle workspace dots", .entry = .{
        .title = "Toggle workspace dots",
        .body = "Paints ● on a workspace root's header row when its repo has uncommitted changes and ○ when it is clean, so a multi-root tree says at a glance which one needs a commit. It flips `ui.show_workspace_dots` for this session only — the Settings row is what writes it home. The git chip has the counts for the active repo.",
        .links = &.{ .{ .command = .{ .id = .@"view.toggle_workspace_dots", .label = "Toggle them" } }, .{ .settings = .{ .row = copy.settingsRow("ui.show_workspace_dots"), .label = "Workspace dots in Settings" } }, .{ .command = .{ .id = .@"git.status_pane", .label = "The status pane" } } },
    } },
    .{ .menu = "View", .label = "Pick theme…", .entry = .{
        .title = "Pick theme…",
        .body = "Opens the theme picker over the bundled themes and previews each as the cursor moves over it; Enter keeps it as `ui.theme` in the home config, Esc restores the one you had. A theme only recolours; glyphs and layout stay.",
        .links = &.{ .{ .command = .{ .id = .@"theme.pick", .label = "Pick a theme" } }, .{ .settings = .{ .row = copy.settingsRow("ui.theme"), .label = "Theme in Settings" } }, copy.docsSection("Themes") },
    } },
    .{ .menu = "View", .label = "Toggle theme", .entry = .{
        .title = "Toggle theme",
        .body = "Swaps between `ui.theme` and `ui.theme_toggle` — a light and a dark, usually — for this session only; nothing is written, so the next launch is back on `ui.theme`. With no `theme_toggle` set it picks the first bundled theme of the opposite kind instead. The pill in the top-right cluster is the same swap on a click when `ui.theme_toggle` is set, and opens the theme picker when it is not.",
        .keys = &.{.{ .command = .@"theme.toggle", .label = "Toggle the theme" }},
        .links = &.{ .{ .command = .{ .id = .@"theme.toggle", .label = "Toggle it" } }, .{ .command = .{ .id = .@"theme.pick", .label = "Pick a theme" } }, copy.docsSection("Themes") },
    } },
    .{ .menu = "View", .label = "Reset view to default", .entry = .{
        .title = "Reset view to default",
        .body = "The way back when the frame has gone piece by piece: leaves full screen and the zoom, shows the tree, the menu bar, the bufferline and the statusline, puts the tree width back to `ui.tree_width`, and turns a hidden menu bar or activity bar back on. The open tabs and the split structure stay — only the sizes go back to equal halves.",
        .links = &.{ .{ .command = .{ .id = .@"view.reset_layout", .label = "Reset the view" } }, .{ .command = .{ .id = .@"view.equalize_splits", .label = "Equalize the splits" } }, .{ .settings = .{ .row = copy.settingsRow("ui.tree_width"), .label = "Tree width" } } },
    } },
    // ── View → Layouts (`app/named_layouts.zig`) ──
    .{ .menu = "View", .label = "Layouts", .entry = .{
        .title = "Layouts",
        .body = "Named layouts: this tab page written down under a name in `.mnml/layouts/<name>.zon` — its splits and their ratios, the focus, the zoom, and what reopens each pane (a file, a terminal's cwd and command, an AI session, an `.http` block, a browser URL, a git view, a search). Loading one replaces the current tab page. The same four commands are `:layout save|load|delete|list` and which-key `space W`.",
        .keys = &.{.{ .chord = "→ / ←", .label = "Open / close the submenu" }},
        .links = &.{ .{ .command = .{ .id = .@"layout.save", .label = "Save this page" } }, .{ .command = .{ .id = .@"layout.pick", .label = "Load one" } }, copy.docsSection("Named layouts") },
    } },
    .{ .menu = "View", .parent = "Layouts", .label = "Save this tab page as…", .entry = .{
        .title = "Save this tab page as…",
        .body = "Asks for a name and writes this tab page to `.mnml/layouts/<name>.zon`, workspace paths relative so the file can be committed; the same name again asks before it replaces the file (`:layout save!` does not ask). Scratch buffers and list panes are left out — nothing reopens them. A layout with terminal commands is also recorded as this mnml's own, so it loads its commands even in an untrusted workspace.",
        .links = &.{ .{ .command = .{ .id = .@"layout.save", .label = "Save it" } }, copy.docsSection("Named layouts") },
    } },
    .{ .menu = "View", .parent = "Layouts", .label = "Load layout…", .entry = .{
        .title = "Load layout…",
        .body = "A picker over the saved layouts, each row saying how many panes and splits it holds and what they are; Enter replaces this tab page with it, and Shift+Delete deletes the row after asking. Panes with unsaved changes ask first and then stay open as background tabs, and a terminal command from a file this mnml did not write only runs in a trusted workspace — refused otherwise, with a toast.",
        .links = &.{ .{ .command = .{ .id = .@"layout.pick", .label = "Pick one" } }, .{ .command = .{ .id = .@"tab.reopen", .label = "Bring the replaced page back" } }, .{ .command = .{ .id = .@"workspace.review_trust", .label = "Workspace trust" } } },
    } },
    .{ .menu = "View", .parent = "Layouts", .label = "Delete layout…", .entry = .{
        .title = "Delete layout…",
        .body = "Picks a saved layout and, after asking, deletes its file from `.mnml/layouts/` — a committed copy goes from the next commit too — along with this mnml's record of having written it, so a later file under the same name is treated as someone else's. The panes on screen are untouched. Shift+Delete in Load layout… does the same from that list.",
        .links = &.{ .{ .command = .{ .id = .@"layout.delete", .label = "Delete one" } }, .{ .command = .{ .id = .@"layout.pick", .label = "See the saved ones" } } },
    } },
    // ── Go ──
    .{ .menu = "Go", .label = "Go to file…", .entry = .{
        .title = "Go to file…",
        .body = "Opens the fuzzy file picker over the workspace — type any part of a path and Enter opens the match in the active leaf; the preview column shows the file under the cursor. It is the same picker as File → Open file…, and ignored files are never in it.",
        .keys = &.{.{ .command = .@"picker.files", .label = "Go to file" }},
        .links = &.{ .{ .command = .{ .id = .@"picker.files", .label = "The file picker" } }, .{ .command = .{ .id = .@"picker.buffers", .label = "Open buffers only" } }, .{ .command = .{ .id = .@"picker.workspace_symbol", .label = "A symbol instead" } } },
    } },
    .{ .menu = "Go", .label = "Go to line…", .entry = .{
        .title = "Go to line…",
        .body = "Asks for a line number and puts the cursor at that line's first character, scrolled into view — `12`, or `12:4` for a column; a number past the end lands on the last line. The Ln/Col chip's menu has the same row.",
        .keys = &.{.{ .command = .@"editor.goto_line", .label = "Go to line" }},
        .links = &.{ .{ .command = .{ .id = .@"editor.goto_line", .label = "Go to a line" } }, .{ .command = .{ .id = .@"picker.marks", .label = "Jump to a mark" } } },
    } },
    .{ .menu = "Go", .label = "Go to definition", .entry = .{
        .title = "Go to definition",
        .body = "Jumps to where the symbol under the cursor is defined, opening its file when it is not open; `nav.back` returns to where you were. It needs the buffer's language server — with none running the LSP chip in the statusline says which is missing and how to install it.",
        .keys = &.{ .{ .command = .@"lsp.goto_definition", .label = "Go to definition" }, .{ .command = .@"lsp.peek_definition_overlay", .label = "Peek instead" } },
        .links = &.{ .{ .command = .{ .id = .@"lsp.goto_definition", .label = "Go" } }, .{ .command = .{ .id = .@"lsp.references", .label = "Find the references" } }, .{ .command = .{ .id = .@"lsp.status", .label = "Which servers are running" } } },
    } },
    .{ .menu = "Go", .label = "Previous buffer", .entry = .{
        .title = "Previous buffer",
        .body = "Activates the tab to the left of this one in the active leaf's strip, wrapping from the first to the last. Terminal tabs are stepped over. The palette bar's ← chip runs this same step, and Buffers… lists every open buffer as a picker.",
        .keys = &.{ .{ .command = .@"buffer.prev", .label = "Previous buffer" }, .{ .command = .@"buffer.next", .label = "Next buffer" } },
        .links = &.{ .{ .command = .{ .id = .@"buffer.prev", .label = "Previous" } }, .{ .command = .{ .id = .@"picker.buffers", .label = "Buffers…" } } },
    } },
    .{ .menu = "Go", .label = "Next buffer", .entry = .{
        .title = "Next buffer",
        .body = "Activates the tab to the right of this one in the active leaf's strip, wrapping from the last to the first. Terminal tabs are stepped over. The palette bar's → chip runs this same step, and Buffers… lists every open buffer as a picker.",
        .keys = &.{ .{ .command = .@"buffer.next", .label = "Next buffer" }, .{ .command = .@"buffer.prev", .label = "Previous buffer" } },
        .links = &.{ .{ .command = .{ .id = .@"buffer.next", .label = "Next" } }, .{ .command = .{ .id = .@"picker.buffers", .label = "Buffers…" } } },
    } },
    .{ .menu = "Go", .label = "Last buffer", .entry = .{
        .title = "Last buffer",
        .body = "Switches to the buffer that was active before this one — vim's Ctrl+^ — and again bounces back, so two files can be flipped between with one chord without touching the strip. With only one buffer open it fails with `E23: no alternate buffer`.",
        .keys = &.{.{ .command = .@"buffer.last", .label = "Last buffer" }},
        .links = &.{ .{ .command = .{ .id = .@"buffer.last", .label = "Flip back" } }, .{ .command = .{ .id = .@"picker.buffers", .label = "Buffers…" } } },
    } },
    // ── Run ──
    .{ .menu = "Run", .label = "Start debugging", .entry = .{
        .title = "Start debugging",
        .body = "Starts a debug session for the active buffer's language with the adapter the `dap` config names for it and runs to the first breakpoint; breakpoints set beforehand are sent as the adapter connects. The DEBUG section does not open itself — `dap.toggle_panel` is the way to the variables and the call stack. A language with no adapter configured toasts and stops there.",
        .keys = &.{ .{ .command = .@"dap.continue", .label = "Continue a paused session" }, .{ .command = .@"dap.toggle_panel", .label = "The DEBUG section" } },
        .links = &.{ .{ .command = .{ .id = .@"dap.run", .label = "Start" } }, .{ .command = .{ .id = .@"dap.list_breakpoints", .label = "The breakpoints" } }, ask },
    } },
    .{ .menu = "Run", .label = "Toggle breakpoint", .entry = .{
        .title = "Toggle breakpoint",
        .body = "Sets a breakpoint on the cursor's line — the gutter shows a ● — or removes the one there, before or during a session; a running session takes the change at once. The gutter's own right-click edits its condition, hit count and log message.",
        .keys = &.{.{ .command = .@"dap.toggle_breakpoint", .label = "Toggle breakpoint" }},
        .links = &.{ .{ .command = .{ .id = .@"dap.toggle_breakpoint", .label = "Toggle it" } }, .{ .command = .{ .id = .@"dap.toggle_breakpoint_conditional", .label = "With a condition" } }, .{ .command = .{ .id = .@"dap.list_breakpoints", .label = "List them all" } } },
    } },
    .{ .menu = "Run", .label = "Conditional breakpoint…", .entry = .{
        .title = "Conditional breakpoint…",
        .body = "Asks for an expression and sets a breakpoint on the cursor's line that stops only when it is true — `i > 100`, `name == \"x\"` — in the adapter's own language; the gutter shows it as ◆. On a line that has a breakpoint already the row edits its condition.",
        .keys = &.{.{ .command = .@"dap.toggle_breakpoint_conditional", .label = "Conditional breakpoint" }},
        .links = &.{ .{ .command = .{ .id = .@"dap.toggle_breakpoint_conditional", .label = "Set one" } }, .{ .command = .{ .id = .@"dap.set_breakpoint_hit_count", .label = "A hit count instead" } }, .{ .command = .{ .id = .@"dap.set_breakpoint_log_message", .label = "A log message instead" } } },
    } },
    .{ .menu = "Run", .label = "Step in", .entry = .{
        .title = "Step in",
        .body = "Steps into the call on the current line and pauses at its first statement; a line with no call behaves as a step over. Only while a session is paused — the step toolbar above the editor greys out otherwise.",
        .keys = &.{ .{ .command = .@"dap.step_in", .label = "Step in" }, .{ .command = .@"dap.next", .label = "Step over" } },
        .links = &.{ .{ .command = .{ .id = .@"dap.step_in", .label = "Step in" } }, .{ .command = .{ .id = .@"dap.step_out", .label = "Step out" } }, .{ .command = .{ .id = .@"dap.continue", .label = "Continue" } } },
    } },
    .{ .menu = "Run", .label = "Step out", .entry = .{
        .title = "Step out",
        .body = "Runs until the current function returns and pauses in its caller, on the line after the call. Only while a session is paused; at the top frame it behaves as a continue.",
        .keys = &.{ .{ .command = .@"dap.step_out", .label = "Step out" }, .{ .command = .@"dap.step_in", .label = "Step in" } },
        .links = &.{ .{ .command = .{ .id = .@"dap.step_out", .label = "Step out" } }, .{ .command = .{ .id = .@"dap.continue", .label = "Continue" } } },
    } },
    .{ .menu = "Run", .label = "Step back", .entry = .{
        .title = "Step back",
        .body = "Reverses one step of execution — only an adapter that records and replays (rr, a time-travel debugger) can, and the row does nothing with a toast on the rest, which is most of them. Reverse-continue runs back to the previous breakpoint the same way.",
        .links = &.{ .{ .command = .{ .id = .@"dap.step_back", .label = "Step back" } }, .{ .command = .{ .id = .@"dap.reverse_continue", .label = "Reverse-continue" } }, ask },
    } },
    // ── Terminal ──
    .{ .menu = "Terminal", .label = "New terminal (split below)", .entry = .{
        .title = "New terminal (split below)",
        .body = "Opens a new `$SHELL` in a split under the active leaf, in the workspace directory with mnml's environment, rendered by libghostty-vt — each shell is its own pane with its own scrollback and working directory. Closing the tab ends the shell; the strip's terminal chip places one in a chosen half.",
        .keys = &.{ .{ .command = .@"term.shell_bottom", .label = "New shell below" }, .{ .command = .@"term.shell", .label = "New shell beside" }, .{ .command = .@"term.scratch_toggle", .label = "The scratch terminal" } },
        .links = &.{ .{ .command = .{ .id = .@"term.shell_bottom", .label = "Open a shell below" } }, .{ .command = .{ .id = .@"term.shell", .label = "Beside instead" } }, .{ .settings = .{ .row = copy.settingsRow("session.restore_terminals"), .label = "Restore terminals" } } },
    } },
    .{ .menu = "Terminal", .label = "Toggle scratch terminal", .entry = .{
        .title = "Toggle scratch terminal",
        .body = "One shell that toggles: the first call opens it as a strip at the bottom, the next hides it, the next shows it again with its history intact — the place for a one-off command without a tab per command. It is per workspace and comes back with the session under `session.restore_terminals`.",
        .keys = &.{.{ .command = .@"term.scratch_toggle", .label = "Toggle the scratch terminal" }},
        .links = &.{ .{ .command = .{ .id = .@"term.scratch_toggle", .label = "Toggle it" } }, .{ .command = .{ .id = .@"term.shell", .label = "A full shell pane instead" } }, .{ .settings = .{ .row = copy.settingsRow("session.restore_terminals"), .label = "Restore terminals" } } },
    } },
    .{ .menu = "Terminal", .label = "Rename terminal", .entry = .{
        .title = "Rename terminal",
        .body = "Gives the active terminal pane a name of your own — `tests`, `server` — for its tab, its SESSIONS card and its dock item, instead of the shell and command it shows. The name lives in the session, so it comes back with the tab. With an editor active there is nothing to rename and it toasts.",
        .links = &.{ .{ .command = .{ .id = .@"term.rename", .label = "Rename it" } }, .{ .command = .{ .id = .@"term.focus_or_open_shell", .label = "Focus a shell first" } } },
    } },
    // ── Window ──
    .{ .menu = "Window", .label = "Reopen closed tab", .entry = .{
        .title = "Reopen closed tab",
        .body = "Brings back the most recently closed buffer with its cursor and scroll where they were, into the active leaf; again walks further back through what was closed. A file deleted since it was closed reopens empty.",
        .keys = &.{.{ .command = .@"buffer.reopen", .label = "Reopen the last closed" }},
        .links = &.{ .{ .command = .{ .id = .@"buffer.reopen", .label = "Reopen it" } }, .{ .command = .{ .id = .@"picker.recent", .label = "Recent files" } } },
    } },
    .{ .menu = "Window", .label = "Close other tabs", .entry = .{
        .title = "Close other tabs",
        .body = "Closes every other pane, across every tab page, and the layout collapses to one leaf. A dirty buffer is kept rather than closed — the toast counts how many — and pinned tabs are kept too. Save all first if you meant to clear them.",
        .keys = &.{ .{ .command = .@"view.close_others", .label = "Close the others" }, .{ .command = .@"buffer.reopen", .label = "Reopen the last closed" } },
        .links = &.{ .{ .command = .{ .id = .@"view.close_others", .label = "Close them" } }, .{ .command = .{ .id = .@"buffer.pin_toggle", .label = "Pin this one first" } }, .{ .command = .{ .id = .@"buffer.close_others", .label = "Only this leaf's tabs" } } },
    } },
    .{ .menu = "Window", .label = "Pin / unpin tab", .entry = .{
        .title = "Pin / unpin tab",
        .body = "Pins the active tab so it stays at the front of the strip, survives Close others and is never taken by a preview; again unpins it. The pin is per tab and comes back with the session. The tab's own menu has the same row, worded for its state.",
        .links = &.{ .{ .command = .{ .id = .@"buffer.pin_toggle", .label = "Toggle the pin" } }, .{ .settings = .{ .row = copy.settingsRow("ui.preview_tabs"), .label = "Preview tabs" } } },
    } },
    .{ .menu = "Window", .label = "Split right", .entry = .{
        .title = "Split right",
        .body = "Splits the active leaf side by side and opens the same buffer in the new right half, focused, so two places in one file scroll independently; the strip's split chip does the same on a click. Whether the sizes are re-shared afterwards is the Auto-equalize row below.",
        .keys = &.{ .{ .command = .@"view.split_right", .label = "Split right" }, .{ .command = .@"view.split_down", .label = "Split down" } },
        .links = &.{ .{ .command = .{ .id = .@"view.split_right", .label = "Split right" } }, .{ .command = .{ .id = .@"view.equalize_splits", .label = "Equalize the splits" } }, .{ .command = .{ .id = .@"view.focus_right", .label = "Focus the right split" } } },
    } },
    .{ .menu = "Window", .label = "Split down", .entry = .{
        .title = "Split down",
        .body = "Splits the active leaf top and bottom and opens the same buffer in the new lower half, focused, so two places in one file scroll independently; the strip's split chip does the same on a click. A terminal pane splits too — the shell stays in the original half and the new one gets a scratch editor.",
        .keys = &.{ .{ .command = .@"view.split_down", .label = "Split down" }, .{ .command = .@"view.split_right", .label = "Split right" } },
        .links = &.{ .{ .command = .{ .id = .@"view.split_down", .label = "Split down" } }, .{ .command = .{ .id = .@"view.equalize_splits", .label = "Equalize the splits" } }, .{ .command = .{ .id = .@"view.focus_down", .label = "Focus the lower split" } } },
    } },
    .{ .menu = "Window", .label = "Close split", .entry = .{
        .title = "Close split",
        .body = "Closes the active split and hands its space to the neighbour; the tabs the leaf held stay open in the background, and only a second window on a document open elsewhere closes. With one split left it closes the active buffer instead — a dirty one asks first.",
        .links = &.{ .{ .command = .{ .id = .@"view.close_split", .label = "Close it" } }, .{ .command = .{ .id = .@"view.toggle_zoom", .label = "Zoom instead of closing" } }, .{ .command = .{ .id = .@"buffer.reopen", .label = "Reopen the last closed" } } },
    } },
    .{ .menu = "Window", .label = "Equalize splits", .entry = .{
        .title = "Equalize splits",
        .body = "Resizes every split in this tab page back to an equal share in one go — vim's Ctrl+W = — undoing the grow and shrink rows and any divider drag. Auto-equalize below does it by itself after every split and close.",
        .links = &.{ .{ .command = .{ .id = .@"view.equalize_splits", .label = "Equalize now" } }, .{ .command = .{ .id = .@"view.toggle_auto_equalize_splits", .label = "Do it automatically" } } },
    } },
    .{ .menu = "Window", .label = "Auto-equalize on split / close (toggle)", .entry = .{
        .title = "Auto-equalize on split / close (toggle)",
        .body = "On, every split and every close re-shares the sizes equally, so a leaf never ends up a sliver; off, a new split takes half of the pane it came from and the rest keep their ratios. The row carries no tick — a toast says which way it went; Equalize splits is the one-shot form.",
        .links = &.{ .{ .command = .{ .id = .@"view.toggle_auto_equalize_splits", .label = "Toggle it" } }, .{ .command = .{ .id = .@"view.equalize_splits", .label = "Equalize once" } } },
    } },
    .{ .menu = "Window", .label = "Grow split width", .entry = .{
        .title = "Grow split width",
        .body = "Widens the active split by a few columns at its neighbours' expense — vim's Ctrl+W > — and again widens it more; the divider can also be dragged. Equalize splits puts every size back.",
        .links = &.{ .{ .command = .{ .id = .@"view.split_grow_width", .label = "Grow width" } }, .{ .command = .{ .id = .@"view.split_shrink_width", .label = "Shrink width" } }, .{ .command = .{ .id = .@"view.equalize_splits", .label = "Equalize" } } },
    } },
    .{ .menu = "Window", .label = "Grow split height", .entry = .{
        .title = "Grow split height",
        .body = "Makes the active split a few rows taller at its neighbours' expense — vim's Ctrl+W + — and again taller still; the divider can also be dragged. Equalize splits puts every size back.",
        .links = &.{ .{ .command = .{ .id = .@"view.split_grow_height", .label = "Grow height" } }, .{ .command = .{ .id = .@"view.split_shrink_height", .label = "Shrink height" } }, .{ .command = .{ .id = .@"view.equalize_splits", .label = "Equalize" } } },
    } },
    .{ .menu = "Window", .label = "Focus split left", .entry = focusSplit("left", "to the left of", "h", "From the leftmost split it steps into the sidebar instead.", .@"view.focus_left", .@"view.focus_right") },
    .{ .menu = "Window", .label = "Focus split right", .entry = focusSplit("right", "to the right of", "l", "With no split that way the focus stays where it is.", .@"view.focus_right", .@"view.focus_left") },
    .{ .menu = "Window", .label = "Focus split up", .entry = focusSplit("up", "above", "k", "With no split above the focus stays where it is.", .@"view.focus_up", .@"view.focus_down") },
    .{ .menu = "Window", .label = "Focus split down", .entry = focusSplit("down", "below", "j", "From the lowest split it steps into the bottom dock instead.", .@"view.focus_down", .@"view.focus_up") },
    .{ .menu = "Window", .label = "Restart mnml", .entry = .{
        .title = "Restart mnml",
        .body = "Exits with the code `run.sh`'s loop reads as rebuild-and-relaunch, so a fresh build comes up on the same workspace with the config re-read from disk; the session is written first and restored after. With a buffer dirty a *Restart mnml?* box names it first; clean, nothing asks. Outside the loop it simply quits.",
        .links = &.{ .{ .command = .{ .id = .@"app.restart", .label = "Restart" } }, .{ .command = .{ .id = .@"file.save_all", .label = "Save all first" } }, ask },
    } },
    // ── Help ──
    .{ .menu = "Help", .label = "Welcome", .entry = .{
        .title = "Welcome",
        .body = "Shows the start surface — the page mnml opens on with nothing open: this window's workspaces, the recent files, the sessions to resume, and the chords to start with in YOUR profile (NvChad's under vim, VS Code's under standard). With something open it comes up on a fresh empty tab page, with the keys. With `ui.welcome = off` the cheatsheet stands in.",
        .links = &.{ .{ .command = .{ .id = .@"view.welcome", .label = "Open it" } }, .{ .command = .{ .id = .@"first_launch.show", .label = "The setup wizard" } } },
    } },
    .{ .menu = "Help", .label = "Keybindings & help", .entry = .{
        .title = "Keybindings & help",
        .body = "Opens the keymap reference as an overlay — every chord in the active profile with the command it runs, your rebinds included, generated from the live keymap rather than a page that can drift. `/` filters and `c` / `e` collapse and expand the sections; it is a reference, not a launcher — the palette is where a row is run, and the cheatsheet pane is the same list as a tab.",
        .keys = &.{ .{ .command = .@"view.help", .label = "Keybindings & help" }, .{ .command = .@"view.cheatsheet", .label = "The cheatsheet pane" } },
        .links = &.{ .{ .command = .{ .id = .@"view.help", .label = "Open it" } }, .{ .command = .{ .id = .@"keys.edit", .label = "Rebind a key" } }, .{ .command = .{ .id = .@"keys.doctor", .label = "The keyboard doctor" } } },
    } },
    .{ .menu = "Help", .label = "About mnml", .entry = .{
        .title = "About mnml",
        .body = "Opens the About box — the version, the workspace, the implemented-commands count, the live keymap profile with its binding count, the zig it was built with — the same five lines as the brand menu's row. Paste them into a bug report; a newer release is a separate check.",
        .links = &.{ .{ .command = .{ .id = .@"view.about", .label = "Open it" } }, .{ .command = .{ .id = .@"app.check_updates", .label = "Check for a newer release" } } },
    } },
    // ── the `Menu bar` menu: a word's right press, and the pin chip ──
    .{ .menu = "Menu bar", .label = "Open", .kind = .menu_bar, .entry = .{
        .title = "Open",
        .body = "Drops this word's menu, the way a left click on it does — the right press opened this list instead so the bar's own rows could sit under it. Alt with the word's letter opens the same menu from the keyboard while the bar is `always` or `auto`; under `hidden` the keys are dead and the palette has the rows.",
        .keys = &.{.{ .chord = "→ / ←", .label = "The next / previous menu" }},
        .links = &.{ .{ .command = .{ .id = .@"view.menu_bar_open", .label = "Open the File menu" } }, .{ .command = .{ .id = .palette, .label = "The command palette" } } },
    } },
    .{ .label = "Pin menu bar", .entry = .{
        .title = "Pin menu bar",
        .body = "Keeps an auto-hiding bar on screen for this session: the words stay up wherever the pointer goes and the chip reads pinned. Nothing is written to the config — the next launch reads `ui.menu_bar` again — so unpinning is one click. Under `always` there is nothing to pin and the row says so.",
        .links = &.{ .{ .command = .{ .id = .@"view.menu_bar_pin", .label = "Pin it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.menu_bar"), .label = "Menu bar in Settings" } } },
    } },
    .{ .label = "Unpin menu bar", .entry = .{
        .title = "Unpin menu bar",
        .body = "Lets the bar hide again under `ui.menu_bar = auto`: the words go when the pointer leaves the top row and come back when it rests there again. The pin was for this session only, so nothing in the config changes.",
        .links = &.{ .{ .command = .{ .id = .@"view.menu_bar_pin", .label = "Unpin it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.menu_bar"), .label = "Menu bar in Settings" } } },
    } },
    .{ .label = "Menu bar: always → auto", .entry = menuBarCycle("always", "auto", "the words leave the top row until the pointer rests on the screen's top edge, and the editor gains the row") },
    .{ .label = "Menu bar: auto → hidden", .entry = menuBarCycle("auto", "hidden", "the words never appear, and Alt+letter and F10 are dead with them — the palette has every row") },
    .{ .label = "Menu bar: hidden → always", .entry = menuBarCycle("hidden", "always", "the words sit on the top row all the time, and a click or Alt+letter opens a menu") },
};

fn fullScreen(comptime label: []const u8) Entry {
    return .{
        .title = label,
        .body = if (std.mem.eql(u8, label, "Enter full screen"))
            "Hides the tree, the bufferline, the menu bar and the statusline and gives the whole terminal to the panes; the same row reads Exit full screen while inside, and Esc Esc leaves too. The zoom on the strip's maximize chip is the other way to one big pane — it keeps the chrome."
        else
            "Brings the chrome back — the tree, the bufferline, the menu bar and the statusline — around the panes as they are; Esc Esc does the same. The row reads Enter full screen again once outside, and Reset view to default is the way back from any hiding at once.",
        .keys = &.{ .{ .command = .@"view.fullscreen", .label = "Full screen" }, .{ .command = .@"view.toggle_zoom", .label = "Zoom one pane" } },
        .links = &.{ .{ .command = .{ .id = .@"view.fullscreen", .label = "Toggle full screen" } }, .{ .command = .{ .id = .@"view.toggle_zoom", .label = "Zoom the split instead" } }, .{ .command = .{ .id = .@"view.reset_layout", .label = "Reset the view" } } },
    };
}

fn focusSplit(comptime dir: []const u8, comptime where: []const u8, comptime letter: []const u8, comptime beyond: []const u8, comptime id: command.CommandId, comptime back: command.CommandId) Entry {
    return .{
        .title = "Focus split " ++ dir,
        .body = "Moves the keyboard focus to the split " ++ where ++ " the active one, leaving the layout as it is; the cursor and the statusline follow the focus. " ++ beyond ++ " The vim profile's Ctrl+W " ++ letter ++ " is the same move.",
        .keys = &.{ .{ .command = id, .label = "Focus " ++ dir }, .{ .command = back, .label = "And back" } },
        .links = &.{ .{ .command = .{ .id = id, .label = "Focus " ++ dir } }, .{ .command = .{ .id = .@"view.focus_next_split", .label = "The next split, any direction" } } },
    };
}

fn menuBarCycle(comptime from: []const u8, comptime to: []const u8, comptime what: []const u8) Entry {
    return .{
        .title = "Menu bar: " ++ from ++ " → " ++ to,
        .body = "Steps `ui.menu_bar` from " ++ from ++ " to " ++ to ++ " and writes it to the home config: " ++ what ++ ". The row's label always names the step it will take, so it reads differently after each press; Settings → UI picks a mode outright.",
        .links = &.{ .{ .command = .{ .id = .@"view.menu_bar_cycle", .label = "Cycle it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.menu_bar"), .label = "Menu bar in Settings" } }, .{ .command = .{ .id = .@"view.menu_bar_pin", .label = "Pin it for the session" } } },
    };
}

/// A `file.open_recent_N` id — the File menu's recent-files rows.
pub fn isRecentId(id: command.CommandId) bool {
    return std.mem.startsWith(u8, command.name(id), "file.open_recent_");
}

/// One recent file's row, named: the label is its basename, the body
/// has the path it opens.
pub fn recentFile(app: *App, arena: Allocator, label: []const u8) Allocator.Error!Entry {
    var path: []const u8 = label;
    var i = app.recent.items.len;
    while (i > 0) : (i -= 1) {
        const p = app.recent.items[i - 1];
        if (std.mem.eql(u8, std.fs.path.basename(p), label)) {
            path = app.relPath(p);
            break;
        }
    }
    return .{
        .title = try std.fmt.allocPrint(arena, "Open recent — {s}", .{label}),
        .body = try std.fmt.allocPrint(arena, "Opens `{s}` in the active leaf — one of the ten files opened most recently in this workspace, newest at the top. A file moved or deleted since it was here opens empty; Clear recent files at the foot drops the list.", .{path}),
        .keys = &.{.{ .command = .@"picker.recent", .label = "Recent files as a picker" }},
        .links = &.{ .{ .command = .{ .id = .@"picker.recent", .label = "The recent-files picker" } }, .{ .command = .{ .id = .@"file.clear_recent", .label = "Clear the list" } } },
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
        std.debug.print("menu_bar: no entry for `{s}` in menu `{s}`\n", .{ label, app.overlay.menu.title });
        return error.Uncovered;
    }
}

test "menu_bar: every row of every dropdown, each word's own menu and the pin's resolves to a curated entry" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const cm = @import("../../context_menus.zig");
    const menu_bar = @import("../../menu_bar.zig");
    _ = try app.openScratch();
    inline for (comptime std.enums.values(menu_bar.Menu)) |m| {
        closeMenu(&app);
        try menu_bar.open(&app, m, 5, 5, false);
        try expectCurated(&app);
        closeMenu(&app);
        _ = try cm.openButtonMenu(&app, menu_bar.button_base + @intFromEnum(m), 5, 5);
        try expectCurated(&app);
    }
    closeMenu(&app);
    try cm.openMenuBarPinMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    // The qualifiers that matter: `New file` is the File menu's row,
    // not a tree row's; `Go to definition` under Go and on the editor
    // body are two entries; the recent-files rows are a family named
    // after the file.
    try t.expectEqualStrings("New file", menus.lookup("File", null, "New file").?.title);
    try t.expect(std.mem.indexOf(u8, menus.lookup("File", null, "New file").?.body, "With the tree focused") != null);
    try t.expect(menus.lookup("Go", null, "Go to definition") != null);
    try t.expect(!std.mem.eql(u8, menus.lookup("Go", null, "Go to definition").?.body, menus.lookup("Editor", null, "Go to definition").?.body));
    try t.expect(isRecentId(.@"file.open_recent_1"));
    try t.expect(!isRecentId(.@"file.new"));
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const recent = try recentFile(&app, arena_state.allocator(), "notes.md");
    try t.expectEqualStrings("Open recent — notes.md", recent.title);
    try t.expect(std.mem.indexOf(u8, recent.body, "notes.md") != null);
}
