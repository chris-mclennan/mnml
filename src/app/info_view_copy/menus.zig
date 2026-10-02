//! Hover help for a context menu's rows, keyed by the open menu's title
//! and the row's label (and the parent row's label for a submenu's
//! rows). A row without an entry falls back to `Menu: <label>` and
//! the command's title — the audit lists every such row, menu by menu.
//!
//! The rows are split by the surface that opens the menu, one module
//! each under `menus/` — the menu bar's dropdowns, the rail's section
//! menus, the chrome's chip menus, the statusline chips, the panes and
//! the tree, the curated `+` menu — and concatenated here in the order
//! `lookupItem` searches: a row qualified by its menu, its command or
//! its action kind comes before a bare label, so a label two menus
//! share (`Rename…` on a terminal tab and on a tree row) resolves to
//! the entry written for the menu it is in. Rows whose label carries
//! state (`Show Explorer`, `Move to right side`, a recent file's name,
//! `Toggle → dark`) are `family` entries built at lookup time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../../app.zig");
const App = app_mod.App;
const copy = @import("../info_view_copy.zig");
const Entry = copy.Entry;
const command = @import("../../core/command.zig");

const ask = copy.ask_link;

/// One curated row: `menu` null matches any menu; `parent` is the
/// submenu's parent row when the row is in one. `prefix` matches a
/// label that carries a value (`Copy position (12:4)`) by its start.
/// `command` and `kind` tell two menus' same-labelled rows apart by
/// what the row does — a row that names one is skipped for an item
/// that runs something else.
pub const Row = struct {
    menu: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    label: []const u8,
    prefix: bool = false,
    command: ?command.CommandId = null,
    kind: ?ActionKind = null,
    entry: Entry,
};

pub const ActionKind = std.meta.Tag(command.MenuAction);

pub const menu_bar = @import("menus/menu_bar.zig");
pub const rail = @import("menus/rail.zig");
pub const chrome = @import("menus/chrome.zig");
pub const chips = @import("menus/chips.zig");
pub const panes = @import("menus/panes.zig");
pub const plus = @import("menus/plus.zig");

/// Every curated row, in lookup order.
pub const rows = phase_one ++ menu_bar.rows ++ rail.rows ++ chrome.rows ++ chips.rows ++ plus.rows ++ panes.rows;

/// Phase one: the menus the chrome's chips open — the Claude and Codex
/// chips on the tab strip and in the statusline, the terminal chip,
/// the two `Icon ▸` submenus, the keymap chip, the tab menu and the
/// info panel's own kebab.
const phase_one = [_]Row{
    // ── the info panel's own kebab ──
    .{ .menu = "Sidebar", .label = "Turn off info panel (Settings → UI to bring back)", .entry = .{
        .title = "Turn off the info panel",
        .body = "Removes this help box from the bottom of the left column and gives its rows to the section above; the tooltip near the pointer (`ui.hover_tooltip`) is unaffected. Settings → UI → Hover help, or `view.toggle_hover_help`, brings it back — the kebab goes with the panel, so this row cannot undo itself.",
        .links = &.{ .{ .command = .{ .id = .@"view.toggle_hover_help", .label = "Turn it off" } }, .{ .settings = .{ .row = copy.settingsRow("ui.hover_help"), .label = "Hover help in Settings" } } },
    } },
    // ── the keymap chip ──
    .{ .menu = "Keymap", .label = "vim keymap", .entry = .{
        .title = "vim keymap",
        .body = "Switches the input style to the vim profile: modal editing — NORMAL, INSERT, VISUAL, REPLACE — with the NvChad chords and Space as the leader; the mode chip reads the mode. The switch is written to `editor.input_style` in the home config and every chord is rebuilt at once. The standard profile's Ctrl chords are gone under it, so learn the leader menu (Space) first.",
        .keys = &.{.{ .command = .@"whichkey.leader", .label = "The leader menu" }},
        .links = &.{ .{ .command = .{ .id = .@"editor.use_vim", .label = "Switch to vim" } }, .{ .command = .{ .id = .@"view.cheatsheet", .label = "The cheatsheet" } } },
    } },
    .{ .menu = "Keymap", .label = "standard keymap", .entry = .{
        .title = "standard keymap",
        .body = "Switches the input style to the standard profile: modeless editing with VS Code's chords — Ctrl+S, Ctrl+P, Ctrl+Shift+P, F12. The switch is written to `editor.input_style` in the home config and every chord is rebuilt at once; the mode chip then names the focused surface rather than a mode.",
        .keys = &.{.{ .command = .palette, .label = "The command palette" }},
        .links = &.{ .{ .command = .{ .id = .@"editor.use_standard", .label = "Switch to standard" } }, .{ .command = .{ .id = .@"view.cheatsheet", .label = "The cheatsheet" } } },
    } },
    .{ .menu = "Keymap", .label = "Open the cheatsheet", .entry = .{
        .title = "The cheatsheet",
        .body = "A pane listing every chord in the active profile with the command it runs, grouped by area, your rebinds included — the reference for the keymap you have rather than the one the docs describe. `/` filters, Enter runs the row. F1 opens the same list as an overlay.",
        .keys = &.{ .{ .command = .@"view.cheatsheet", .label = "The cheatsheet" }, .{ .command = .@"view.help", .label = "The keymap reference" } },
        .links = &.{ .{ .command = .{ .id = .@"view.cheatsheet", .label = "Open it" } }, .{ .command = .{ .id = .@"keys.edit", .label = "Rebind keys" } } },
    } },
    // ── the Claude / Codex chips on the tab strip ──
    .{ .menu = "Claude Code launcher", .label = "Toggle existing Claude Code pane", .entry = .{
        .title = "Toggle the Claude Code pane",
        .body = "Goes to the running Claude Code session — the one you were in last, on whichever tab holds it — and, chosen again while you are in it, back to the pane you came from. Only when none is running does it start one; it never opens a second. The session is the `claude` CLI in a terminal pane, in the workspace, on the account it is signed in as.",
        .links = &.{ .{ .command = .{ .id = .@"ai.claude_code_focus", .label = "Toggle it" } }, .{ .command = .{ .id = .@"view.activity_sessions", .label = "The sessions section" } } },
    } },
    .{ .menu = "Claude Code launcher", .label = "New Claude Code session in left half", .entry = newSession(.claude, "left") },
    .{ .menu = "Claude Code launcher", .label = "New Claude Code session in right half", .entry = newSession(.claude, "right") },
    .{ .menu = "Claude Code launcher", .label = "New Claude Code session in top half", .entry = newSession(.claude, "top") },
    .{ .menu = "Claude Code launcher", .label = "New Claude Code session in bottom half", .entry = newSession(.claude, "bottom") },
    .{ .menu = "Claude Code launcher", .label = "New Claude Code session in a new tab", .entry = newSessionTab(.claude, false) },
    .{ .menu = "Claude Code launcher", .label = "New Claude Code session in a new tab page", .entry = newSessionTab(.claude, true) },
    .{ .menu = "Codex launcher", .label = "Toggle existing Codex pane", .entry = .{
        .title = "Go to the Codex pane",
        .body = "Brings the running Codex session's pane forward and focuses it, and starts a session when there is none — it never hides the pane. The session is the `codex` CLI in a terminal pane, in the workspace; Codex has no API route in this build, so the CLI must be on PATH.",
        .links = &.{ .{ .command = .{ .id = .@"ai.codex", .label = "Go to it" } }, .{ .command = .{ .id = .@"view.activity_sessions", .label = "The sessions section" } } },
    } },
    .{ .menu = "Codex launcher", .label = "New Codex session in left half", .entry = newSession(.codex, "left") },
    .{ .menu = "Codex launcher", .label = "New Codex session in right half", .entry = newSession(.codex, "right") },
    .{ .menu = "Codex launcher", .label = "New Codex session in top half", .entry = newSession(.codex, "top") },
    .{ .menu = "Codex launcher", .label = "New Codex session in bottom half", .entry = newSession(.codex, "bottom") },
    .{ .menu = "Codex launcher", .label = "New Codex session in a new tab", .entry = newSessionTab(.codex, false) },
    .{ .menu = "Codex launcher", .label = "New Codex session in a new tab page", .entry = newSessionTab(.codex, true) },
    .{ .label = "Layout: Grid (splits)", .entry = .{
        .title = "AI layout — grid",
        .body = "Several sessions at once as a grid of splits — two side by side, four in a two-by-two — each visible, with the `+ Add Claude Code` card in an empty slot. `ui.ai_layout_mode = grid`. The alternative stacks them as tabs in one leaf, which suits a narrow terminal.",
        .links = &.{ .{ .command = .{ .id = .@"view.ai_layout_grid", .label = "Use the grid" } }, .{ .settings = .{ .row = copy.settingsRow("ui.ai_layout_mode"), .label = "AI session layout" } } },
    } },
    .{ .label = "Layout: Tabs (stack in leaf)", .entry = .{
        .title = "AI layout — tabs",
        .body = "Several sessions stacked as tabs in one leaf, one visible at a time — the SESSIONS cards and the dock's terminal items switch between them. `ui.ai_layout_mode = tabs`. The grid shows them all at once instead, which wants a wide terminal.",
        .keys = &.{.{ .command = .@"view.activity_sessions", .label = "Sessions" }},
        .links = &.{ .{ .command = .{ .id = .@"view.ai_layout_tabs", .label = "Use tabs" } }, .{ .settings = .{ .row = copy.settingsRow("ui.ai_layout_mode"), .label = "AI session layout" } } },
    } },
    .{ .label = "Show side by side", .entry = .{
        .title = "Sessions side by side",
        .body = "How many sessions the sessions mode stands side by side — the Sessions row of the activity bar enters it: the layout is put aside, every Claude Code and Codex session goes into a column, the first ones on the rail on show and the rest stacked behind them. 1 is one session maximised. Picking a count writes `ai.session_columns` home and, in the mode, deals the sessions again.",
        .links = &.{ .{ .command = .{ .id = .@"sessions.mode", .label = "The sessions mode" } }, .{ .settings = .{ .row = copy.settingsRow("ai.session_columns"), .label = "Sessions side by side" } } },
    } },
    .{ .parent = "Show side by side", .label = "1 — one maximised", .entry = columns(1) },
    .{ .parent = "Show side by side", .label = "2 side by side", .entry = columns(2) },
    .{ .parent = "Show side by side", .label = "3 side by side", .entry = columns(3) },
    .{ .parent = "Show side by side", .label = "4 side by side", .entry = columns(4) },
    .{ .label = "Sessions side by side (the sessions mode)", .entry = .{
        .title = "The sessions mode",
        .body = "Puts the editor layout aside and shows only the Claude Code and Codex sessions, `ai.session_columns` of them side by side, the rest stacked behind as tabs. Ctrl+Tab steps the focused column's stack, Ctrl+1…9 shows the rail's Nth session there, Ctrl+N starts a new one in it. Run it again — or click the Sessions row — and the layout comes back exactly as it was.",
        .links = &.{ .{ .command = .{ .id = .@"sessions.mode", .label = "Enter or leave it" } }, .{ .settings = .{ .row = copy.settingsRow("ai.session_columns"), .label = "Sessions side by side" } } },
    } },
    .{ .label = "Bake AI glyphs into MnmlSymbols", .entry = .{
        .title = "Bake the AI glyphs",
        .body = "Writes the catalog of the Nerd Font glyphs mnml draws to `nerd-glyphs.tsv` under the data root and toasts the count — it builds and installs no font. A mark of your own goes into the MnmlSymbols font through Icon ▸ Custom SVG… on the terminal or Claude chip.",
        .links = &.{ .{ .command = .{ .id = .@"integrations.bake_ai_glyphs", .label = "Bake them" } }, .{ .command = .{ .id = .@"view.terminal_glyph_custom", .label = "Bake a custom terminal icon" } } },
    } },
    .{ .label = "Edit Codex glyph…", .entry = glyphEdit(.codex) },
    // ── the Icon submenus ──
    .{ .parent = "Icon", .label = "Claude Code", .entry = .{
        .title = "Icon — the Claude Code figure",
        .body = "Claude wears the Claude Code figure everywhere the chrome draws a mark for it — the tab bar's chip, a session's tab, its SESSIONS card, the dock. Picking it writes `ui.claude_mark = figure` to the home config; the tick shows the current choice. The glyph is in the MnmlSymbols font; a box instead of a figure means the font is not installed.",
        .links = &.{ .{ .settings = .{ .row = copy.settingsRow("ui.claude_mark"), .label = "Claude icon in Settings" } }, .{ .command = .{ .id = .@"integrations.bake_ai_glyphs", .label = "Bake the glyphs" } } },
    } },
    .{ .parent = "Icon", .label = "Anthropic", .entry = .{
        .title = "Icon — the Anthropic spark",
        .body = "Claude wears the Anthropic spark everywhere the chrome draws a mark for it — the tab bar's chip, a session's tab, its SESSIONS card, the dock. Picking it writes `ui.claude_mark = spark` to the home config; the tick shows the current choice. The glyph is in the MnmlSymbols font; a box instead of a spark means the font is not installed.",
        .links = &.{ .{ .settings = .{ .row = copy.settingsRow("ui.claude_mark"), .label = "Claude icon in Settings" } }, .{ .command = .{ .id = .@"integrations.bake_ai_glyphs", .label = "Bake the glyphs" } } },
    } },
    .{ .parent = "Icon", .label = "Ghostty", .entry = .{
        .title = "Icon — the ghost",
        .body = "The terminal chip and every terminal tab wear ghostty's ghost — the default. Picking it writes `ui.terminal_glyph = ghostty` to the home config; the tick shows the current choice. A custom SVG baked behind the ghost's codepoint keeps its own row below.",
        .links = &.{ .{ .command = .{ .id = .@"view.terminal_glyph_ghostty", .label = "Use the ghost" } }, .{ .settings = .{ .row = copy.settingsRow("ui.terminal_glyph"), .label = "Terminal icon in Settings" } } },
    } },
    .{ .parent = "Icon", .label = "Terminal", .entry = .{
        .title = "Icon — the plain terminal",
        .body = "The terminal chip and every terminal tab wear the plain terminal codicon instead of the ghost. Picking it writes `ui.terminal_glyph = terminal` to the home config; the tick shows the current choice. It is a Nerd Font glyph, so it draws on any patched font.",
        .links = &.{ .{ .command = .{ .id = .@"view.terminal_glyph_terminal", .label = "Use the plain terminal" } }, .{ .settings = .{ .row = copy.settingsRow("ui.terminal_glyph"), .label = "Terminal icon in Settings" } } },
    } },
    .{ .parent = "Icon", .label = "Custom SVG…", .command = .@"view.claude_mark_custom", .entry = .{
        .title = "Icon — a custom SVG for Claude",
        .body = "Asks for an SVG file and bakes it into the MnmlSymbols font behind the Claude Code figure's codepoint (U+F1E00), so the Claude chip and every Claude session tab wear your own art (`ui.claude_mark = custom`). The face is rebuilt under the data root and a toast offers the restart the terminal needs to notice. The figure row puts the shipped mark back.",
        .links = &.{ .{ .command = .{ .id = .@"view.claude_mark_custom", .label = "Pick an SVG" } }, .{ .settings = .{ .row = copy.settingsRow("ui.claude_mark"), .label = "Claude icon in Settings" } } },
    } },
    .{ .parent = "Icon", .label = "Custom SVG…", .command = .@"view.terminal_glyph_custom", .entry = .{
        .title = "Icon — a custom SVG",
        .body = "Asks for an SVG file and bakes it into the MnmlSymbols font behind the ghost's codepoint, so the terminal chip and every terminal tab wear your own art (`ui.terminal_glyph = custom`). The face is rebuilt under the data root and a toast offers the restart the terminal needs to notice. The ghost row puts the shipped glyph back.",
        .links = &.{ .{ .command = .{ .id = .@"view.terminal_glyph_custom", .label = "Pick an SVG" } }, .{ .settings = .{ .row = copy.settingsRow("ui.terminal_glyph"), .label = "Terminal icon in Settings" } } },
    } },
    // ── the terminal chip ──
    .{ .menu = "Terminal", .label = "Open shell (beside)", .entry = .{
        .title = "Open a shell beside the active pane",
        .body = "A new `$SHELL` in a split beside the active pane, in the workspace directory with mnml's environment, rendered by libghostty-vt. The chip's left click is this row; the half rows below place the shell explicitly. Closing the tab ends the shell.",
        .keys = &.{.{ .command = .@"term.shell", .label = "New shell" }},
        .links = &.{ .{ .command = .{ .id = .@"term.shell", .label = "Open a shell" } }, .{ .command = .{ .id = .@"term.scratch_toggle", .label = "The scratch terminal" } } },
    } },
    .{ .menu = "Terminal", .label = "Open shell in left half", .entry = shellHalf("left", .@"term.shell_left") },
    .{ .menu = "Terminal", .label = "Open shell in right half", .entry = shellHalf("right", .@"term.shell_right") },
    .{ .menu = "Terminal", .label = "Open shell in top half", .entry = shellHalf("top", .@"term.shell_top") },
    .{ .menu = "Terminal", .label = "Open shell in bottom half", .entry = shellHalf("bottom", .@"term.shell_bottom") },
    .{ .menu = "Terminal", .label = "Scratch terminal", .entry = .{
        .title = "The scratch terminal",
        .body = "One shell that toggles: the first call opens it in a split at the bottom, the next hides it, the next shows it again with its history intact — a place for the one-off command without a tab per command. It is per workspace and is not saved with the session, so it does not come back after a restart — `session.restore_terminals` brings back the ordinary shells only.",
        .keys = &.{.{ .command = .@"term.scratch_toggle", .label = "Toggle the scratch terminal" }},
        .links = &.{ .{ .command = .{ .id = .@"term.scratch_toggle", .label = "Toggle it" } }, .{ .settings = .{ .row = copy.settingsRow("session.restore_terminals"), .label = "Restore terminals" } } },
    } },
    // ── the Claude / Codex chips in the statusline ──
    .{ .label = "Open usage pane", .entry = .{
        .title = "The usage pane",
        .body = "The full figures behind the chip: for Claude the five-hour and weekly windows of every linked account with their reset times; for Codex the tokens and sessions today. Refresh asks the account's endpoint again. The pane is where an account is linked or renamed.",
        .links = &.{ .{ .command = .{ .id = .@"ai.claude_usage", .label = "Claude usage" } }, .{ .command = .{ .id = .@"ai.link_claude_token", .label = "Link an account" } } },
    } },
    .{ .label = "Refresh usage now", .entry = .{
        .title = "Refresh the usage",
        .body = "Asks the account's usage endpoint again instead of waiting for the next poll — the thing to do when a chip reads stale after a reset. A chip stuck at 0% on a linked account is a token that needs re-linking, which a refresh does not fix.",
        .links = &.{ .{ .command = .{ .id = .@"ai.refresh_usage", .label = "Refresh now" } }, .{ .command = .{ .id = .@"ai.link_claude_token", .label = "Re-link the token" } } },
    } },
    .{ .label = "Add Claude account…", .command = .@"ai.claude_add_account", .entry = .{
        .title = "Add a Claude account",
        .body = "Asks for a name, then for that account's Claude Code OAuth token, and adds it to `ai.claude_accounts` in the home config with a token file of its own under the data root. It is fetched at once and from then on with the others; the usage pane lists it and the chip counts it. Esc on the token prompt keeps the account unlinked — in the usage pane, L runs `claude login` as it and R captures that login into its file.",
        .keys = &.{.{ .chord = "a", .label = "Add (in the usage pane)" }},
        .links = &.{ .{ .command = .{ .id = .@"ai.claude_add_account", .label = "Add one" } }, .{ .command = .{ .id = .@"ai.claude_usage", .label = "The usage pane" } } },
    } },
    .{ .label = "Show last response", .entry = .{
        .title = "The last usage response",
        .body = "Opens the raw answer the usage endpoint gave last time, as text — for reading exactly what the account reports when the chip's figure looks wrong. A 401 here is an expired token; re-link it.",
        .links = &.{ .{ .command = .{ .id = .@"ai.show_last_response", .label = "Show it" } }, ask },
    } },
    .{ .label = "Session only", .entry = chipDetail("Session only", "the five-hour session window alone — its percentage and reset time", .@"ai.chip_show_session") },
    .{ .label = "Weekly only", .entry = chipDetail("Weekly only", "the weekly window alone — its percentage and reset time", .@"ai.chip_show_weekly") },
    .{ .label = "Both", .command = .@"ai.chip_show_both", .entry = chipDetail("Both", "the five-hour window and the weekly one side by side", .@"ai.chip_show_both") },
    .{ .label = "Reset countdown", .entry = .{
        .title = "Reset countdown on the chip",
        .body = "Adds the time until the window resets after the percentage — `42% 1h20m` — so the chip says when a full window opens again without a hover. Off, the percentage stands alone and the hover has the time.",
        .links = &.{.{ .command = .{ .id = .@"ai.chip_toggle_reset", .label = "Toggle it" } }},
    } },
    .{ .label = "All AI chips: off", .entry = chipsAll("off", "the active account alone, as a single account always shows", .@"ai.chip_show_all_off") },
    .{ .label = "All AI chips: compact", .entry = chipsAll("compact", "every linked account in one chip — `P40% · W62% · C12%` — the default", .@"ai.chip_show_all_compact") },
    .{ .label = "All AI chips: ticker", .entry = chipsAll("ticker", "one account at a time, rotating every four seconds, its letter first", .@"ai.chip_show_all_ticker") },
    // ── the tab menu ──
    .{ .label = "Close others", .entry = .{
        .title = "Close the other tabs",
        .body = "Closes every other tab in this leaf and keeps this one; a dirty buffer among them is kept open rather than asked about, and a toast counts them. Pinned tabs are kept. The undo chip offers the batch back for a few seconds.",
        .keys = &.{.{ .command = .@"buffer.reopen", .label = "Reopen the last closed" }},
        .links = &.{ .{ .command = .{ .id = .@"buffer.close_others", .label = "Close the others" } }, .{ .command = .{ .id = .@"buffer.pin_toggle", .label = "Pin this one first" } } },
    } },
    .{ .label = "Close to the right", .entry = .{
        .title = "Close the tabs to the right",
        .body = "Closes every tab after this one in the strip and keeps this one and those before it; a dirty buffer among them is kept, with a toast counting them. Pinned tabs sit at the front, so they are never to the right of anything.",
        .links = &.{.{ .command = .{ .id = .@"buffer.close_right", .label = "Close them" } }},
    } },
    .{ .label = "Pin tab", .entry = .{
        .title = "Pin the tab",
        .body = "A pinned tab stays at the front of the strip, is kept by *Close others*, and is never a preview tab. The pin is per tab and survives the session. The same row reads *Unpin tab* once it is pinned.",
        .links = &.{ .{ .command = .{ .id = .@"buffer.pin_toggle", .label = "Pin it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.preview_tabs"), .label = "Preview tabs" } } },
    } },
    .{ .label = "Unpin tab", .entry = .{
        .title = "Unpin the tab",
        .body = "Lets the tab back into the strip's normal order — it can be closed by *Close others* again, and it stays where it sits in the strip. The pin is per tab and was surviving the session.",
        .links = &.{.{ .command = .{ .id = .@"buffer.pin_toggle", .label = "Unpin it" } }},
    } },
    .{ .label = "Reveal in tree", .entry = .{
        .title = "Reveal in the tree",
        .body = "Expands the file tree down to this file and puts the cursor on its row, opening the left column if it was hidden. The row's own menu then has the file verbs — rename, cut, copy, a new file beside it.",
        .links = &.{ .{ .command = .{ .id = .@"view.reveal_in_tree", .label = "Reveal it" } }, .{ .command = .{ .id = .@"file.copy_path", .label = "Copy the path" } } },
    } },
    .{ .label = "Reveal in Finder", .entry = .{
        .title = "Reveal in the OS file manager",
        .body = "Opens the folder in Finder (macOS) or Explorer (Windows) with this file selected; on Linux `xdg-open` opens its folder, with nothing selected. `view.reveal_in_tree` is the in-app twin — the tree row rather than a window outside mnml.",
        .links = &.{ .{ .command = .{ .id = .@"view.reveal_active", .label = "Reveal it" } }, .{ .command = .{ .id = .@"file.copy_path", .label = "Copy the path" } } },
    } },
    .{ .label = "Rename…", .command = .@"term.rename", .entry = .{
        .title = "Rename the terminal",
        .body = "Gives this terminal tab a name of your own — `tests`, `server` — instead of the shell and command it shows; the SESSIONS card and the dock item take the same name. The name lives in the session, so it comes back with the tab.",
        .links = &.{.{ .command = .{ .id = .@"term.rename", .label = "Rename it" } }},
    } },
    .{ .label = "Restart", .command = .@"term.restart", .entry = .{
        .title = "Restart the terminal",
        .body = "Ends the child — the shell, or the session it is running — and starts it again in the same tab with the same command and directory. A Claude session resumes its conversation when its transcript exists, and starts fresh under the same id when it does not.",
        .links = &.{ .{ .command = .{ .id = .@"term.restart", .label = "Restart it" } }, .{ .command = .{ .id = .@"term.clear", .label = "Just clear the screen" } } },
    } },
    // ── submenu parents ──
    .{ .label = "Icon", .entry = .{
        .title = "Icon ▸ — the mark this chip wears",
        .body = "Opens the three marks to choose from: for the Claude chip and Claude session tabs the Claude Code figure, the Anthropic spark, or a custom SVG baked into the MnmlSymbols font (`ui.claude_mark`); for the terminal chip and every terminal tab the ghost, the plain terminal codicon, or a custom SVG baked into the MnmlSymbols font (`ui.terminal_glyph`). The tick marks the one in use; picking writes the home config, so the mark is the same in every workspace.",
        .keys = &.{.{ .chord = "→ / ←", .label = "Open / close the submenu" }},
        .links = &.{ .{ .settings = .{ .row = copy.settingsRow("ui.claude_mark"), .label = "Claude icon in Settings" } }, .{ .settings = .{ .row = copy.settingsRow("ui.terminal_glyph"), .label = "Terminal icon in Settings" } } },
    } },
    .{ .label = "Color", .entry = .{
        .title = "Color ▸ — the accent",
        .body = "Opens the palette of accents for this terminal or session: the colour goes on the tab, on the pane's rail down its left edge, and on the SESSIONS card, so two shells side by side stop being two identical grey rectangles. The tick marks the current one; *Auto* lets mnml pick. The choice lives in the session, so it comes back with the tab.",
        .keys = &.{.{ .chord = "→ / ←", .label = "Open / close the submenu" }},
        .links = &.{.{ .settings = .{ .row = copy.settingsRow("ui.pane_rail"), .label = "Pane colour rail" } }},
    } },
    .{ .label = "Clear (Ctrl+L)", .entry = .{
        .title = "Clear the terminal",
        .body = "Sends Ctrl+L to the child, which clears the screen the way the shell does — mnml keeps the scrollback, and the child keeps running. Restart is the other row when the child itself is stuck.",
        .links = &.{.{ .command = .{ .id = .@"term.clear", .label = "Clear it" } }},
    } },
};

fn newSession(comptime product: enum { claude, codex }, comptime half: []const u8) Entry {
    const claude = product == .claude;
    return .{
        .title = if (claude) "New Claude Code session — " ++ half ++ " half" else "New Codex session — " ++ half ++ " half",
        .body = (if (claude) "Starts another Claude Code session — the `claude` CLI in a terminal pane — in the " ++ half ++ " half of the active pane's leaf, so the code and the session sit side by side or stacked. Each session has its own SESSIONS card and rail colour. The grid rows below lay out two or four at once." else "Starts another Codex session — the `codex` CLI in a terminal pane — in the " ++ half ++ " half of the active pane's leaf, so the code and the session sit side by side or stacked. Each session has its own SESSIONS card and rail colour."),
        .links = &.{ .{ .command = .{ .id = if (claude) .@"ai.claude_code_new" else .@"ai.codex_new", .label = "New session beside the pane" } }, .{ .command = .{ .id = .@"ai.new_session_worktree", .label = "New session in a worktree" } } },
    };
}

fn newSessionTab(comptime product: enum { claude, codex }, comptime page: bool) Entry {
    const claude = product == .claude;
    const name = if (claude) "Claude Code" else "Codex";
    const cli = if (claude) "`claude`" else "`codex`";
    const id: command.CommandId = if (claude) (if (page) .@"ai.claude_code_new_page" else .@"ai.claude_code_new_tab") else (if (page) .@"ai.codex_new_page" else .@"ai.codex_new_tab");
    return .{
        .title = if (page) "New " ++ name ++ " session — new tab page" else "New " ++ name ++ " session — new tab",
        .body = if (page)
            "Starts another " ++ name ++ " session — the " ++ cli ++ " CLI in a terminal pane — alone on a fresh page in the TABS cluster, inserted after the current page and shown. The page you were on keeps its layout untouched; the next-session / previous-session keys cycle across pages to reach it."
        else
            "Starts another " ++ name ++ " session — the " ++ cli ++ " CLI in a terminal pane — as a new tab in the active leaf's strip, right after the current tab, with no split. The session gets the leaf; the tab you were on is one click or one next-session / previous-session step away.",
        .keys = &.{ .{ .command = .@"ai.focus_next_session", .label = "Next session" }, .{ .command = .@"ai.focus_prev_session", .label = "Previous session" } },
        .links = &.{ .{ .command = .{ .id = id, .label = "Open one" } }, .{ .command = .{ .id = .@"view.activity_sessions", .label = "The sessions section" } } },
    };
}

fn glyphEdit(comptime product: enum { codex }) Entry {
    _ = product;
    return .{
        .title = "Edit the Codex glyph",
        .body = "Cut in this build: the per-integration glyph builder is not here, so the row only toasts why. Two marks can still wear your own SVG — the terminal's and Claude's, through Icon ▸ Custom SVG… on their chips.",
        .links = &.{ .{ .command = .{ .id = .@"view.terminal_glyph_custom", .label = "Custom terminal icon" } }, .{ .command = .{ .id = .@"view.claude_mark_custom", .label = "Custom Claude icon" } } },
    };
}

fn shellHalf(comptime half: []const u8, comptime id: command.CommandId) Entry {
    return .{
        .title = "Open a shell in the " ++ half ++ " half",
        .body = "A new `$SHELL` in the " ++ half ++ " half of the active pane's leaf — the leaf is split that way and the shell takes the new side, focused. It runs in the workspace directory with mnml's environment. The tab menu's Rename gives it a name for the strip and the dock.",
        .links = &.{ .{ .command = .{ .id = id, .label = "Open it here" } }, .{ .command = .{ .id = .@"term.scratch_toggle", .label = "The scratch terminal" } } },
    };
}

fn chipDetail(comptime label: []const u8, comptime what: []const u8, comptime id: command.CommandId) Entry {
    return .{
        .title = "Claude chip — " ++ label,
        .body = "Picks the figure the statusline's Claude chip carries — this row is " ++ what ++ ". The tick marks the current one; the usage pane has every window whichever is picked. A chip at 100% means new turns queue until that window resets.",
        .links = &.{ .{ .command = .{ .id = id, .label = "Show this" } }, .{ .command = .{ .id = .@"ai.claude_usage", .label = "The usage pane" } } },
    };
}

fn chipsAll(comptime mode: []const u8, comptime what: []const u8, comptime id: command.CommandId) Entry {
    return .{
        .title = "Claude chip accounts — " ++ mode,
        .body = "Sets `ai.claude_meter_mode`, how the Claude chip shows several linked accounts: this row is " ++ what ++ ". With one account the chip is always the single one. The tick marks the current mode; the usage pane keeps the full figures whichever mode is set.",
        .links = &.{ .{ .command = .{ .id = id, .label = "Use this mode" } }, .{ .settings = .{ .row = copy.settingsRow("ai.claude_meter_mode"), .label = "Meter mode in Settings" } } },
    };
}

/// Rows whose entry is generated from the row rather than written for
/// it — a family: the theme menu's one row per theme; the rail's
/// `Show <section>` and `Move to <side>` rows, whose words are the
/// section's; the File menu's recent files; the `+` menu's Integrations
/// group, one row per enabled integration; the theme chip's `Toggle →
/// <name>`. Each family's body names the thing the row is about, so no
/// two rows of a family read the same.
fn family(app: *App, arena: Allocator, menu: []const u8, parent: ?[]const u8, item: command.MenuItem) Allocator.Error!?Entry {
    const label = item.label;
    if (std.mem.eql(u8, menu, "Theme")) {
        if (item.action == .set_theme) return .{
            .title = try std.fmt.allocPrint(arena, "Theme — {s}", .{label}),
            .body = try std.fmt.allocPrint(arena, "Recolours mnml with the `{s}` theme at once and writes `ui.theme = {s}` to the home config, so it holds in every workspace; the tick marks the one in use. A theme only recolours — glyphs and layout stay the same. `theme.toggle` swaps between the configured pair, and *Auto* follows the terminal's light or dark instead of a fixed name.", .{ label, label }),
            .keys = &.{.{ .command = .@"theme.toggle", .label = "Toggle the configured pair" }},
            .links = &.{ .{ .command = .{ .id = .@"theme.pick", .label = "The theme picker (with preview)" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.theme"), .label = "Theme in Settings" } } },
        };
        // `Toggle → dark` / `Toggle (primary ⇄ alt)` / `Toggle (set
        // ui.theme_toggle first)`: the label says whether there is a
        // pair to swap between.
        if (item.action == .command and item.action.command == .@"theme.toggle") return chips.themeToggle(app, arena, label);
    }
    // The rail's section menus: the title is the section's label.
    if (rail.sectionOf(menu)) |section| {
        if (std.mem.startsWith(u8, label, "Show ") and std.mem.eql(u8, label[5..], menu)) return try rail.show(app, arena, section);
        if (item.action == .move_section) return try rail.move(app, arena, section, item.action.move_section.side);
        if (item.action == .rail_hide) return try rail.hide(app, arena, item.action.rail_hide);
        if (item.action == .rail_to_dock) return try rail.toDock(app, arena, item.action.rail_to_dock);
    }
    // A pinned panel's row on the dock: the menu is the item's, the action names the section.
    if (item.action == .rail_from_dock) return try rail.fromDock(app, arena, item.action.rail_from_dock);
    if (std.mem.eql(u8, menu, "File")) if (parent) |p| if (std.mem.eql(u8, p, "Open recent file") and item.action == .command and menu_bar.isRecentId(item.action.command)) return try menu_bar.recentFile(app, arena, label);
    if (std.mem.eql(u8, menu, "Create…")) if (parent) |p| if (std.mem.eql(u8, p, "Integrations")) return try plus.integration(arena, label);
    if (item.action == .claude_account) return try claudeAccountRow(arena, item.action.claude_account);
    return null;
}

/// A row that acts on one Claude account: the usage pane's account menu,
/// or the palette's chooser when several are configured.
fn claudeAccountRow(arena: Allocator, a: command.ClaudeAccountAct) Allocator.Error!Entry {
    return switch (a.act) {
        .link => .{
            .title = try std.fmt.allocPrint(arena, "Link a token to {s}", .{a.name}),
            .body = try std.fmt.allocPrint(arena, "Opens a hidden prompt for the Claude Code OAuth token of `{s}` and writes it to that account's own token file (mode 0600), then fetches its usage. The token is the `accessToken` in the CLI's login — or paste the whole login blob, whose refresh token lets an expired token renew itself.", .{a.name}),
            .links = &.{ .{ .command = .{ .id = .@"ai.link_claude_token", .label = "Link a token" } }, .{ .command = .{ .id = .@"ai.claude_usage", .label = "The usage pane" } } },
        },
        .rename => .{
            .title = try std.fmt.allocPrint(arena, "Rename {s}", .{a.name}),
            .body = try std.fmt.allocPrint(arena, "Opens a prompt seeded with `{s}`; the new name is written to `ai.claude_accounts` in the home config and follows the account's numbers, schedule and identity pin. The token file keeps its name. At most 32 characters, no quotes or backslashes, and not another account's name.", .{a.name}),
            .links = &.{.{ .command = .{ .id = .@"ai.claude_rename_account", .label = "Rename an account" } }},
        },
        .remove => .{
            .title = try std.fmt.allocPrint(arena, "Remove {s}", .{a.name}),
            .body = try std.fmt.allocPrint(arena, "Asks first, then takes `{s}` out of `ai.claude_accounts` in the home config and out of the pane and the chip. Its token file is deleted when it lives under the data root and no other account uses it; a file elsewhere (under `~/.claude`, say) is left alone. The box says which.", .{a.name}),
            .links = &.{ .{ .command = .{ .id = .@"ai.claude_remove_account", .label = "Remove an account" } }, .{ .command = .{ .id = .@"ai.claude_add_account", .label = "Add one" } } },
        },
    };
}

/// The entry for a row of a menu titled `menu` (under `parent` when the
/// row is in a submenu): a curated row first, then a family. The
/// ladder and the audit resolve every row through this one function,
/// so a submenu row the audit reads off its parent is resolved the way
/// the pointer resolves it.
pub fn resolve(app: *App, arena: Allocator, menu: []const u8, parent: ?[]const u8, item: command.MenuItem) Allocator.Error!?Entry {
    if (lookupItem(menu, parent, item.label, item.action)) |e| return e;
    return try family(app, arena, menu, parent, item);
}

/// The on-screen fallback for a row the dictionary has nothing for:
/// the command's title and its chord under the active profile, rather
/// than the tooltip's `opens more rows`. Still a gap — the ladder
/// marks it — but a useful one.
pub fn rowFallback(app: *App, arena: Allocator, menu: u32, idx: u16) Allocator.Error!?struct { title: []const u8, body: []const u8 } {
    if (app.overlay != .menu) return null;
    const m = &app.overlay.menu;
    const sub = menu == 1 or menu == 3;
    const list = if (sub) (if (m.sub) |s| s.items else return null) else m.items;
    if (idx >= list.len) return null;
    const it = list[idx];
    return switch (it.action) {
        .command => |c| .{
            .title = try std.fmt.allocPrint(arena, "{s}: {s}", .{ m.title, it.label }),
            .body = if (try copy.chordOf(app, arena, c)) |chord|
                try std.fmt.allocPrint(arena, "Runs `{s}` — {s}. {s}, the chord at the row's right edge, does the same from the keyboard; the palette lists it under its group.", .{ command.name(c), command.title(c), chord })
            else
                try std.fmt.allocPrint(arena, "Runs `{s}` — {s}. No chord binds it in this profile; the palette lists it under its group.", .{ command.name(c), command.title(c) }),
        },
        .copy_text => .{
            .title = try std.fmt.allocPrint(arena, "{s}: {s}", .{ m.title, it.label }),
            .body = "Copies the row's own text to the clipboard — the value in the label, so the label is the preview.",
        },
        .open_url, .open_path => .{
            .title = try std.fmt.allocPrint(arena, "{s}: {s}", .{ m.title, it.label }),
            .body = if (it.action == .open_url) "Opens the URL in the label in the OS browser (`ui.external_browser` names which)." else "Opens the path in the label in the editor.",
        },
        else => .{
            .title = try std.fmt.allocPrint(arena, "{s}: {s}", .{ m.title, it.label }),
            .body = if (it.submenu.len > 0) try std.fmt.allocPrint(arena, "Opens a submenu of {d} rows — → or a click opens it, ← closes it.", .{it.submenu.len}) else "A row that sets one thing rather than running a command — the tick shows the current choice.",
        },
    };
}

/// The entry for a row of the open menu, by the menu's title, the
/// parent row (for a submenu), the row's label and what it does.
pub fn entry(app: *App, arena: Allocator, menu: u32, idx: u16) Allocator.Error!?Entry {
    if (app.overlay != .menu) return null;
    const m = &app.overlay.menu;
    const sub = menu == 1 or menu == 3;
    const list = if (sub) (if (m.sub) |s| s.items else return null) else m.items;
    if (idx >= list.len) return null;
    const parent: ?[]const u8 = if (sub) (if (m.sub) |s| (if (s.parent < m.items.len) m.items[s.parent].label else null) else null) else null;
    return try resolve(app, arena, m.title, parent, list[idx]);
}

/// By label alone — a submenu row the audit reads off its parent.
pub fn lookup(menu: []const u8, parent: ?[]const u8, label: []const u8) ?Entry {
    return lookupItem(menu, parent, label, null);
}

/// The label of the first row — or `parent/child` for a submenu row —
/// of the open menu the dictionary has nothing for; null when every
/// row is curated. The per-family tests open each menu for real and
/// ask this.
pub fn firstUncovered(app: *App, arena: Allocator) Allocator.Error!?[]const u8 {
    if (app.overlay != .menu) return "(no menu open)";
    const m = &app.overlay.menu;
    for (m.items, 0..) |it, i| {
        if ((try entry(app, arena, 0, @intCast(i))) == null) return it.label;
        for (it.submenu) |sub| if ((try resolve(app, arena, m.title, it.label, sub)) == null) return try std.fmt.allocPrint(arena, "{s}/{s}", .{ it.label, sub.label });
    }
    return null;
}

/// The first row that fits: its menu (or any), its parent (or none),
/// its label (whole, or as a prefix), and — when the row names one —
/// the command the item runs or the kind of action it is. `action`
/// null matches a row whatever it names.
pub fn lookupItem(menu: []const u8, parent: ?[]const u8, label: []const u8, action: ?command.MenuAction) ?Entry {
    for (rows) |r| {
        if (r.menu) |want| if (!std.mem.eql(u8, want, menu)) continue;
        if (r.parent) |want| {
            const have = parent orelse continue;
            if (!std.mem.eql(u8, want, have)) continue;
        }
        if (r.prefix) {
            if (!std.mem.startsWith(u8, label, r.label)) continue;
        } else if (!std.mem.eql(u8, r.label, label)) continue;
        if (action) |a| {
            if (r.command) |want| if (a != .command or a.command != want) continue;
            if (r.kind) |want| if (a != want) continue;
        }
        return r.entry;
    }
    return null;
}

/// For the AI: the menu, the row and the command it runs with its title.
pub fn askContext(app: *App, arena: Allocator, menu: u32, idx: u16) Allocator.Error!?[]const u8 {
    if (app.overlay != .menu) return null;
    const m = &app.overlay.menu;
    const sub = menu == 1 or menu == 3;
    const list = if (sub) (if (m.sub) |s| s.items else return null) else m.items;
    if (idx >= list.len) return null;
    const it = list[idx];
    return switch (it.action) {
        .command => |c| try std.fmt.allocPrint(arena, "- menu \"{s}\", row \"{s}\": runs `{s}` — {s}\n", .{ m.title, it.label, command.name(c), command.title(c) }),
        else => try std.fmt.allocPrint(arena, "- menu \"{s}\", row \"{s}\"{s}\n", .{ m.title, it.label, if (it.submenu.len > 0) " (opens a submenu)" else "" }),
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "menu rows resolve by title, parent and label; the Icon submenu rows are curated; an unknown row is not" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqualStrings("vim keymap", lookup("Keymap", null, "vim keymap").?.title);
    try t.expect(lookup("Other", null, "vim keymap") == null);
    try t.expectEqualStrings("Icon — the Anthropic spark", lookup("Claude Code launcher", "Icon", "Anthropic").?.title);
    try t.expectEqualStrings("Icon — the ghost", lookup("Terminal", "Icon", "Ghostty").?.title);
    try t.expect(lookup("Terminal", null, "Ghostty") == null);
    try t.expect(lookup("Terminal", null, "No such row") == null);
    try t.expectEqualStrings("Open a shell in the left half", lookup("Terminal", null, "Open shell in left half").?.title);
    try t.expect(std.mem.indexOf(u8, lookup("Claude", null, "Weekly only").?.body, "the weekly window alone") != null);
    // Every curated row passes the lint.
    var problems: std.ArrayListUnmanaged(copy.Problem) = .empty;
    for (rows) |r| try copy.lint(a, r.entry, &problems);
    for (problems.items) |p| std.debug.print("menus lint: {s}: {s}\n", .{ p.entry, p.what });
    try t.expectEqual(@as(usize, 0), problems.items.len);
}

test "no two curated menu rows share a body — a row differing only by its target comes from one template with the target's word in it" {
    var seen: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer seen.deinit(t.allocator);
    var dupes: usize = 0;
    for (rows) |r| {
        if (seen.get(r.entry.body)) |other| {
            std.debug.print("menus: `{s}` and `{s}` share a body: {s}\n", .{ other, r.label, r.entry.body[0..@min(60, r.entry.body.len)] });
            dupes += 1;
        } else try seen.put(t.allocator, r.entry.body, r.label);
    }
    try t.expectEqual(@as(usize, 0), dupes);
}

/// A row of the AI chips' *Show side by side* submenu.
fn columns(comptime n: u8) Entry {
    const ids = [_]command.CommandId{ .@"sessions.columns_1", .@"sessions.columns_2", .@"sessions.columns_3", .@"sessions.columns_4" };
    return .{
        .title = if (n == 1) "One session, maximised" else std.fmt.comptimePrint("{d} sessions side by side", .{n}),
        .body = if (n == 1) "The sessions mode shows one session across the whole editor area, the others stacked behind it as tabs — Ctrl+Tab steps through them. Writes `ai.session_columns = 1` home; the tick is the current count." else std.fmt.comptimePrint("The sessions mode stands {d} sessions side by side, each column a stack of the rest, dealt in the rail's order. Writes `ai.session_columns = {d}` home; the tick is the current count.", .{ n, n }),
        .links = &.{.{ .command = .{ .id = ids[n - 1], .label = "Use this count" } }},
    };
}
