# mnml config — `config.zon`

mnml reads three ZON files, in this order, each layered over the last:

| layer | path | trust |
|---|---|---|
| home | `~/.config/mnml/config.zon` (see *Where the home file lives*) | trusted |
| workspace | `<workspace>/.mnml/config.zon` | asked on first open |
| explicit | `--config PATH` | trusted |

A layer only has to mention what it changes. Every key has a shipped
default (`Config{}` in `src/config/Config.zig`); the tests assert them.

**Merge rules.** Scalars, enums, and lists replace the value below them.
`.keys.*`, `.snippets.<scope>`, and `.abbr` extend by key — a workspace
can add one chord without restating the home file's. `.lsp.<name>`,
`.tasks.<name>`, `.formatters.<ext>`, `.linters.<ext>`, and `.dap.<name>`
replace per name: the entry is the unit.

**Failure is local.** A syntax error drops that file; a typo inside `.ui`
drops `.ui` for that file and `.editor` still applies; a bad `.lsp.rust`
drops only `rust`. Every problem is one `file:line:col:` diagnostic in
the toast log, never a failed start. Duplicate keys are an error.

**Enums are enum literals.** `.input_style = .vim`, not `"vim"`. A value
that is not in the set is a type error at its line.

**Edit it as a tree.** Open any `.zon` file and click ` View as tree `
on its tab (`zon.view`): every field becomes a row with the widget its
type calls for — a bool toggles on Enter, an enum cycles on `←→` and
picks on Enter, a number steps and types, a string edits inline, a
list adds (`+`) / removes (`x`) / reorders (`J` `K`), an optional's
`null` offers `set…`, a union picks its tag. The comments below are
the rows' info lines. Each edit is the same splice the Settings
overlay writes with, so your comments and order survive; `*` marks a
changed row, Esc puts it back, `Ctrl+S` writes (a backup lands in
`backups/` beside the file) and the raw editor tab reloads. `Source`
on the tree's tab (`zon.source`, `e`) goes back to the text.

## The complete file

Every section and every key, at its default unless the comment says
otherwise. Copy what you need; leave the rest out.

```zon
.{
    // ── editor ─────────────────────────────────────────────────────────
    .editor = .{
        .input_style = .standard, // .vim | .standard
        .tab_width = 4, // an open buffer follows a change, unless its .editorconfig or :setlocal set its own
        .autosave_secs = 0, // a dirty buffer is saved this many seconds after its last change; 0 = off
        .trim_trailing_ws_on_save = false,
        .breadcrumb = true,
        .auto_pair = true,
        .auto_indent = true,
        .format_on_save = false, // who formats: see `.formatters` below
        .will_save_wait_until = false,
        .format_on_type = false,
        .autosave_on_focus_loss = false, // save every dirty buffer when the terminal loses focus
        .inlay_hints = true,
        // A built-in default server (json / yaml / html / css / csharp / …)
        // that is not on PATH: .quiet records it once per session — the LSP
        // chip reads ` LSP? `, its menu lists the server with its install
        // line and an Install… row — with no toast; .toast warns as a
        // server you named in .lsp does; .ignore says nothing anywhere.
        .lsp_missing_defaults = .quiet, // .quiet | .toast | .ignore
        .inline_values = true, // while the debugger is stopped: `  x = 1` after a line that names x
        // Blink the cursor mnml puts on the focused editor or text
        // field: it picks the blinking DECSCUSR variant and the
        // terminal owns the clock, so mnml runs no blink of its own.
        // A terminal pane follows .ui.pty_cursor.blink instead.
        .cursor_blink = false,
        .semantic_tokens_viewport = false,
        .semantic_tokens = true, // lay a server's semantic tokens over the syntax highlighting (off leaves tree-sitter alone)
        .code_lens = true,
        // A faint rule at every indent step of a line's leading white
        // space — the step is the buffer's indent (a .editorconfig, else
        // what the file is indented by, else tab_width) — with the guide
        // of the block the cursor is in brighter; .active paints only
        // that one. Never on a wrapped row's continuation or over a
        // selection. Toggle: editor.toggle_indent_guides.
        .indent_guides = .on, // .on | .off | .active
        // Dim text after the cursor's line: who last changed it, how long
        // ago and the commit's summary (git blame -L, run on the git
        // worker once the cursor rests). Nothing while the buffer has
        // unsaved changes or for a line not committed yet; a click on it
        // opens the commit in the graph. Toggle: git.toggle_line_blame.
        .line_blame = false,
        .text_width = 80,
        .ensure_trailing_newline = true,
        .chord_timeout_ms = 500, // vim's timeoutlen; clamped to 100..5000
        .report = 2, // vim's 'report': more than this many lines changed toasts "N fewer lines" / "N more lines" (vim profile)
        // The wheel (and a scrollbar drag) in the editor: .always carries the
        // cursor with the view (vim's Ctrl-E canon), .never moves the view
        // and pins it until the cursor moves (VS Code / Sublime), .auto
        // picks by input_style (vim → always, standard → never).
        .wheel_moves_cursor = .auto, // .auto | .always | .never
        // How much further a hard spin travels than a slow one: the
        // multiplier ramps on the wheel's rate (events per second) from
        // 1.0 under 45/s to the ceiling at 120/s — gentle ×1.5, normal
        // ×2.5, fast ×4 — so a single notch is always 1:1; a decaying wheel
        // (a free spin) is never amplified; .off is a plain 1:1 with a 40-line
        // flick bucket. docs/research/scroll-tuning.md has the numbers.
        .scroll_accel = .normal, // .off | .gentle | .normal | .fast
        .persistent_undo = false, // keep each file's undo + redo stacks in <data root>/undo/ across launches
        .clipboard = .auto, // .auto | .os | .internal — what `"+` / `"*` / Ctrl+C reach
        // The ceiling on what tree-sitter is asked to parse. A file that
        // opens larger than this many bytes gets no tree-sitter at all:
        // no parse, no tree, no spans, no injections — editing, search,
        // LSP and the git gutter are untouched. It is never silent: the
        // statusline shows `highlight off · 12 MB` and a toast names the
        // file; the chip (or `editor.highlight_this_file`) turns it on
        // for that one file, and `editor.highlight_toggle_file` switches
        // ANY buffer either way. Per buffer, never persisted. 0 is no
        // limit — every file is highlighted in full, however large.
        //
        // Why there is a ceiling at all: a parse tree is the largest
        // thing the editor holds. Measured, ONE tree over a 100 MB Rust
        // file is 2.5 GB — about 25× the source. At 4 MiB a session on
        // that file settles at 0.6 GB instead of 2.4 GB, and every
        // hand-written source file is still highlighted in full; what
        // the limit skips is a generated bundle or a log.
        .highlight_max_bytes = 4194304, // 4 MiB; 0 = no limit
        // The ceiling on what a LANGUAGE SERVER is started for. A file
        // that opens larger than this attaches none: no didOpen, no
        // diagnostics, completion, hover or go-to — editing, search,
        // highlighting and the git gutter are untouched. Never silent:
        // a toast names the file and the statusline reads `LSP off ·
        // 120 MB`; `editor.lsp_this_file` starts one for that buffer
        // after all. Per buffer, never persisted. 0 is no limit.
        //
        // Why there is a ceiling: `didOpen` has to carry the whole
        // file — the protocol offers no other way to hand a server a
        // document — so a 100 MB buffer is a 100 MB JSON string
        // encoded on the frame that opened it, and the answers scale
        // with it too (a 75 MB and a 196 MB reply came back from
        // rust-analyzer on that file). 50 MiB is VS Code's own
        // large-file threshold; mnml's Rust predecessor has no ceiling
        // at all. Nothing hand-written, and nothing generated that is
        // worth a server, comes near it.
        .lsp_max_bytes = 52428800, // 50 MiB; 0 = no limit
    },

    // ── ui ─────────────────────────────────────────────────────────────
    .ui = .{
        .theme = "onedark", // any theme name; an open set
        .cmdline_popup_border_color = "", // "#RRGGBB" for the `:` line's completion popup; "" = the theme's overlay border
        .theme_toggle = null, // a second theme for theme.toggle
        .theme_auto_system = false, // follow the OS light/dark from launch (theme.auto_system)
        .ascii_icons = false,
        .tree_width = 0, // 0 = auto: a fifth of the window, 30..48 cells, following a resize; a number (10..80) pins it
        .right_panel_visible = false,
        .right_panel_width = 32, // the right column (the Rust right panel's width)
        .bottom_panel_visible = false, // the dock at start (Rust's bottom panel)
        .bottom_panel_height = 12, // the dock's rows; clamped to 3..60
        // Every activity section lives in the left column, the right
        // column or the BOTTOM DOCK (`view.move_section_left` /
        // `_right`, the rail's right-click, vim `Ctrl-W H` / `L` / `J` /
        // `K` in a section, `:sidebar left|right|bottom`).
        // `sidebar_side` is the column a section takes when
        // `section_side` does not name one — the outline takes the other
        // side of it, and the diagnostics the dock (Rust opens
        // `lsp.diagnostics` as a pane under the editor). Every section
        // has a side (SEARCH and DEBUG are columns too). The session
        // keeps the sides a user moved; these are the starting point.
        // The sidebar's column carries the activity rail (at its outer
        // edge), `tree_width` and the sidebar's divider menu, so moving
        // the sidebar moves all three.
        .sidebar_side = .left, // .left | .right (the Settings row "Default sidebar side")
        .section_side = .{ // per section, null = the default above
            .explorer = null, // .left | .right | .bottom
            .git = null,
            .sessions = null,
            .http = null,
            .notes = null,
            .todos = null,
            .findings = null,
            .scripts = null,
            .search = null, // Rust's SEARCH sidebar section (the grep pane is its *Open as pane* door)
            .diagnostics = null, // null = the dock; `.right` is the pre-dock placement
            .outline = null,
        },
        .auto_hide_narrow_width = 0, // RENAMED: the old name of `.sidebar_auto_below` below. A non-zero value is read as that key (with a note at startup saying so) — one rule for a narrow terminal's columns, not two. Rename it in your config
        .sidebar = .always, // .always (docked) | .auto (hidden; the pointer at the column's screen edge reveals it as an overlay OVER the editor — no relayout, no pty resize) | .hidden (never on hover; a keyboard command still gives a one-shot overlay)
        .sidebar_auto_below = 100, // a narrow terminal's columns: below this many columns a `.always` column behaves as `.auto` (hidden; the screen edge or a section command brings it in over the editor) and it docks again once the terminal is this wide. An explicit `.auto` / `.hidden` is untouched (0 = never; a non-zero value is clamped to 40..300)
        .sidebar_reveal_ms = 250, // how long the pointer rests in the edge zone before the overlay slides in (0..5000)
        .sidebar_hide_ms = 400, // how long after the pointer leaves the overlay before it hides (0..5000)
        .dock = .{ // the LAUNCHER dock (`app/launcher_dock.zig`) — integrations, terminals, launchers and pinned commands along one edge of the editor area. Not the bottom panel (`ui.bottom_panel_*`) and not the dock widgets
            .mode = .auto_hide, // .always (the strip is carved out of the frame) | .auto_hide (nothing until the pointer rests at the edge, then it is painted OVER the editor) | .hidden (never on hover; `view.dock_toggle` still gives a one-shot reveal)
            .edge = .bottom, // .bottom (one row, icon + label) | .left | .right (three cells, icon only — the label moves into the tooltip). There is no .top: that row is the menu bar's
            .placement = .inner, // where a BOTTOM strip goes: .inner (the default — the editor area's last row, ABOVE the statusline, so neither it nor the `:` line moves) | .outer (the SCREEN's last row, UNDER the `:` line; everything else moves up one and a revealed strip covers that row) | .shared (the `:` line's row, right of the typed command — no row of its own, no grip, `.auto_hide` reads as `.always`; it steps aside while a typed command would reach it). A side edge ignores it
            .labels = .icon_label, // how much of an item a BOTTOM strip paints: .icon_label (` glyph label `, today's row) | .icon (the glyph alone in the side form's three cells — padding, glyph, padding — with the name in the tooltip) | .label (the word alone, no glyph; the running dot sits in the one padding cell before it). A side edge is icon-only by geometry and ignores this
            .@"align" = .center, // where the run sits along the strip: .center (macOS's Dock) | .start | .end. The pin chip keeps the far end whatever it says
            .plus = true, // the tab bar's own `+` is on the strip, opening the same Create… menu; false takes it off
            .plus_at = .right, // which END the `+` takes: .right (the last item, right before the pin chip — the bottom of a side strip) | .left (leading the run). `:dock plus left|right`
            .running_mark = .bright, // how a running item (a mounted integration, a live pty) is told from the rest: .bright (its icon at full strength, the idle ones dim — the tab bar's own rule, no extra cell) | .dot (a small • in the ITEM's colour in the padding cell before the icon) | .none. `:dock mark bright|dot|none`
            .order = .{}, // the strip's own order — item ids first to last (`browser`, `term.shell`, a pinned command's id). Listed ids lead in this order; anything unlisted (an integration installed later) follows in the default order; an unknown id is ignored. Written by the item menu's Move rows and Alt+←/→ on a focused item; the `+` is never in it
            .pins = .{}, // command ids pinned onto the strip, in this order — a built-in id or an integration's (`jira.open`). An id nothing answers to is skipped
            .reveal_ms = 250, // how long the pointer rests in the dock's edge band before an `auto_hide` strip appears (0..5000)
            .hide_ms = 400, // how long after the pointer leaves before it goes again (0..5000)
        },
        .edge_grips = true, // the three-dot handle at the middle of a hidden slide-in's edge: `⋯` on the menu bar's row and on the dock's bottom row, `⋮` on a side column's screen edge (`--ascii` spends one `.` per cell). Dwelling on it reveals, a left click reveals and PINS, a right click opens that surface's own menu. False gives the invisible bands back — they never move, so every reveal works either way
        .animations = true, // false is the reduced-motion switch: chrome animations with an instant end state are skipped (today the overlay's three-frame slide). --headless and the .test harness behave as if it were false
        .dashboard_refresh = .auto, // .auto | .fast | .slow | .manual — how SESSIONS, the sessions table and the cloud runs re-read on their own (the `sessions` / `cloud_agents.refresh` intervals below; a changed transcript is read within 500 ms on screen whatever this says, except under manual): auto is fast while a session is live and slow otherwise while on screen; fast / slow pin that; manual reads only on the ⟳ chip or `sessions.refresh`. Settings → Integrations → Dashboard refresh
        .auto_equalize_splits = false, // every split and every close re-shares the sizes equally; Settings → UI → Auto-equalize splits, the Window menu's ticked row and `view.toggle_auto_equalize_splits` flip it (written to the workspace config)
        .relative_line_numbers = false,
        .line_numbers = true,
        .cursor_line = false,
        .scrolloff = 0,
        .sidescrolloff = 0,
        .show_whitespace = false,
        .bracket_rainbow = false,
        .tree_preview_on_arrow = true,
        .preview_tabs = true, // VS Code's preview tabs: a tree click (or an arrow over a tree row) opens an italic tab the next glance takes over; a double-click, an edit, `view.keep_tab`, a pin or a drag keeps it. The vim profile never has them
        .syntax = true,
        .scrollbar = true,
        .wheel_lines = 3, // lines per wheel EVENT in a text body (the editor, a markdown preview, a diff — Rust's editor gain); lists move a row an event; ghostty reports a notched detent as three events
        .highlight_trailing_ws = false,
        .clock = true, // the statusline clock, HH:MM in the machine's zone; `clock.utc` switches it (a session choice) and the git graph's DATE / TIME column follows it, so the two clocks on one screen agree
        .stress_meter = false,
        .check_updates = true, // ask GitHub for the newest release once per launch; MNML_NO_UPDATE_CHECK=1 also skips it
        .activity_bar_pinned_integrations = .{}, // chip ids painted as launcher icons after the rail's sections; "Add to activity bar" on a row / chip menu writes here
        .plus_menu_pinned = .{},
        .plus_menu_hidden = .{},
        .auto_refresh_off = .{}, // panel ids whose auto-refresh is off
        .sessions_sort = .auto, // .auto (State: needs you → thinking → idle → ended) | .manual (the J / K order) | .waiting (the sessions that need you first, the manual order under them)
        .session_bell = false, // ring the terminal bell with a session notification (so session_notify gates it); a session no pane here runs rings it on its own. SESSIONS toasts once per edge either way
        .session_notify = .unfocused, // a desktop notification, through the terminal, when a session pane starts needing you (a permission prompt, a question) or ends: .off | .unfocused (its pane is not the focused one, or the terminal window is not) | .always. OSC 777 for ghostty and WezTerm, OSC 9 for iTerm2, both elsewhere
        .session_ended_grace_min = 10, // minutes an ended session stays listed in SESSIONS before the history chip hides it (0 = at once)
        .session_changes = .both, // .mtime | .git | .both — what "What did this session change" (sessions.changes) counts: a dirty or committed file written after the session started, one dirty now and not at the start or in a commit since its HEAD, or either
        .todos_sort = .newest, // .newest | .oldest | .name | .name_desc
        .notes_sort = .newest,
        .findings_sort = .newest,
        .statusline_segment_order = .{}, // .{} = the built-in order
        .highlight_word_under_cursor = false,
        .auto_md_preview = false,
        .color_column = 0, // 0 = off
        .wrap = false,
        .highlight_todo_keywords = false,
        .todo_keywords = .{ "TODO", "FIXME", "XXX", "HACK", "REVIEW" }, // what the TODOS panel scans for (after a comment opener, or a markdown list item)
        .render_markdown = false,
        .markdown_opens_rendered = true,
        .always_show_fold_arrows = false, // the gutter's ▼ on every foldable line, not only the hovered one
        .sticky_context = false,
        .md_image_rows = 12,
        .git_graph_branch_col = null, // null = auto width
        .git_graph_author_col = null,
        .git_graph_detail_col = null,
        .picker_position = .center, // .center | .top
        // The four first-party surfaces (browser, claude_code, codex,
        // http) — the palette-bar chip strip AND the always-present rows
        // of the INTEGRATIONS section's Installed tab. Omit to keep them;
        // set it to replace them. `enabled` (the chip paints and the row
        // reads live, not `(hidden)`) and `in_palette_bar` (the chip is on
        // the bar's strip) are the two the row menu's *Enable / Disable*
        // and *Show in / Hide from palette bar* write back here, in the
        // home config, whole. The other fields describe the row and are
        // not written by the UI.
        .integration_icons = .{
            .{
                .id = "browser",
                .glyph = "\u{EB01}",
                .fallback = "B",
                .command = "browser.open",
                .color = "blue",
                .label = "Browser",
                .enabled = true,
                .in_palette_bar = true,
                .description = null,
                .homepage = null,
                .docs = null,
                .repository = null,
                .author = null,
                .version = null,
                .commands = .{}, // .{ .{ .id = "x.y", .title = "…" } }
            },
        },
        .integration_icon_order = .{}, // ids, left to right
        .ticket_prefixes = .{}, // e.g. .{ "ENG", "OPS" }
        .now_playing_source = .mixr, // .auto | .mixr | .macos
        .now_playing_marquee = false,
        .preferred_music_app = .mixr, // .mixr | .music | .spotify
        .mixr_auto_play_on_open = true,
        .projects_dir = "", // "~/code"; ~ is expanded
        // `.auto` hides the words until the pointer rests on the
        // chrome row; `view.menu_bar_pin` (or the 󰐃 chip past the
        // last word) then keeps them up for the session, the way
        // the sidebar and the launcher dock pin. The pin is never
        // written here — unpinning is one click.
        .menu_bar = .always, // .always | .auto | .hidden
        .activity_bar = .always, // .always | .auto (pointer in column 0 reveals) | .hidden
        .rail = .{ // the activity bar's MEMBERSHIP — which rows it paints; `.activity_bar` above is whether it is there at all
            .hidden = .{}, // sections the bar leaves out: .explorer | .search | .git | .debug | .integrations | .sessions | .http | .notes | .todos | .findings | .scripts. A hidden section keeps its command and its keys. "Hide from activity bar" on a row's right-click writes here; "Show hidden sections ▸" on the gear's menu takes one back; "Show on dock instead" writes here AND pins the section's `view.activity_*` command onto `.dock.pins`
        },
        .debug_toolbar = .auto, // the step toolbar strip over the editor: .auto (while a debug session is live) | .always | .hidden
        .bufferline_diag_style = .count, // .count | .dot | .off
        // The coverage chip reads `feature-coverage/_trends/trends.json` and
        // `code-coverage/_trends/trends.json` under `$MNML_SHARED_STATE_DIR`
        // (`MNML_ARTIFACTS_HOME` overrides it for tests); unset, no chip.
        .coverage_chip_mode = .feature, // .both | .feature | .code | .ticker
        // The background-jobs chip in the statusline: a spinner and a
        // count while a language server starts, a fetch runs, a test
        // run or a send is out; the last failure's words, dimmed, for
        // ten seconds after one fails. A click opens the JOBS list
        // (`jobs.show`) — the running jobs with a Cancel row where one
        // can be stopped, and the last fifty that finished.
        .jobs_chip = .auto, // .auto (while busy or just failed) | .always | .hidden
        .expand_indicator = .chevron, // .chevron | .triangle
        // How a mounted integration's tab strip marks the tab that is
        // on: one row under the labels, in the pane's brand colour,
        // over exactly the active label's cells.
        //   .block  ▀ upper half-block, flush, the rest of the row empty
        //   .rule   ━ heavy under the active label, ─ across the strip
        //   .line   ─ under the active label only
        // A pane under about twelve rows spends no row on it and
        // underlines the active label instead.
        .tab_indicator = .block, // .block (half-block) | .rule (heavy + track) | .line (thin) | .quarter (quarter-height, flush under the label) | .quarter_track (the same bar across the whole strip, the active tab in colour)
        // Dragging the rule above the info view sets this (and writes it here); a double-click
        // on the rule puts back 8. The box keeps at least 4 rows and leaves the section above it 6.
        .hover_help_height = 8, // clamped to 4..60
        // How long the info view keeps an entry while the pointer travels from its target to the
        // box, crossing other targets on the way: held while the pointer keeps closing on the box
        // inside the column (or the triangle toward its near edge); a step outside switches at once.
        .hover_help_grace_ms = 900, // 0 switches at once; clamped to 5000
        .terminal_label = "terminal",
        // A terminal pane paints the cursor its child asked for
        // (DECSCUSR block / bar / underline, hidden by DECTCEM). The
        // focused pane's is filled and, in a real terminal, is the
        // host's OWN cursor — so Ghostty blinks it, and hollows it out
        // when the mnml window itself loses focus. Every other pty pane
        // gets a painted stand-in, which is what `unfocused` picks:
        //   .hollow a BLANK cell shows the full-cell outline mnml bakes
        //           at U+F2001 — ghostty's own unfocused shape. Without
        //           MnmlSymbols installed (./run.sh install-font) it is
        //           ▯ instead, and | under --ascii. A cell that already
        //           holds a character keeps it, repainted in the cursor
        //           colour: one cell holds one grapheme, so the outline
        //           and the character cannot share it
        //   .dim    a muted filled block: the cursor colour half-way to
        //           the pane's ground
        //   .none   nothing
        // `blink` passes the child's blink request out to the host,
        // which owns the clock. An unfocused pane never blinks.
        .pty_cursor = .{
            .unfocused = .hollow, // .hollow | .dim | .none
            .blink = true,
        },
        // Which panes wear the one-cell colour rail down their left
        // edge. Every pane takes a colour off the shared accent ladder
        // when it opens — the one the SESSIONS panel draws from — and
        // keeps it until it closes, skipping whatever another open pane
        // is already wearing, so two terminals are never the same
        // colour at the same time. A git pane wears its repo's accent
        // when there is more than one repo; a mounted integration is
        // not striped at all — the app colour is the sibling's own to
        // paint on the grid it owns.
        //   .all       every pane (the default)
        //   .sessions  only an AI session pane, the look before the
        //              rail was a rule
        //   .off       none
        .pane_rail = .all, // .all | .sessions | .off
        // What the editor area shows while no pane is open — at launch
        // with no session to restore, and after the last pane closes.
        //   .full     the start surface: a compact word mark, the
        //             workspace line, then WORKSPACES (the
        //             Switch workspace list; Enter shows it in the
        //             tree), RECENT FILES (Enter opens), SESSIONS (this
        //             workspace's Claude Code / Codex sessions no
        //             process holds; Enter resumes, and a `+ New Claude
        //             Code session here` row) and SHORTCUTS for the
        //             active profile, read from the command table
        //             (`Space f f` under vim, `Ctrl+P` under standard).
        //             j / k walk a list, Tab moves between lists, Enter
        //             acts, `?` opens the cheatsheet; a click acts too.
        //             What does not fit is dropped whole: under 30
        //             rows the word mark, then SHORTCUTS, then
        //             WORKSPACES, then SESSIONS.
        //   .minimal  the logo, the workspace and its branch, the
        //             recent files when there is room, the shortcut
        //             list and the version, every row centred
        //   .off      the bare ground
        .welcome = .full, // .full | .minimal | .off
        .focus_cue = .both, // how the focused pane and section are marked: .dim (every pane WITHOUT the keys paints its tab name, and the tree its workspace path, in the dim colour) | .rail (only the focused pane's rail at full colour — the others stepped back toward the ground — and the focused section's caps header in the accent) | .both (the default). The dim colour and the step-back come from the theme's contrast: never under 2.0:1 on their ground, in the pane's own hue, so a light theme's cue stays visible
        // The colour the FIRST pane of a kind opens in. A plain
        // terminal opens in white (the theme's text colour), a Claude
        // session in Claude's orange (the chip's), a Codex session in
        // the cyan its chip wears; every further pane of that kind
        // takes the next free ladder slot, as before. "First" is by
        // what is open: while a pane of the kind still holds the
        // default, the next of its kind goes to the ladder, and once
        // it closes the default is free again. A colour picked from
        // the tab's or the session card's Color menu always wins.
        //   .auto           the next free ladder slot, no default
        //   .white          the theme's text colour
        //   .claude_orange  Anthropic's orange, as the Claude chip wears it
        //   .green … .pink  a ladder colour by name
        .accent_defaults = .{
            .shell = .white, // .auto | .white | .claude_orange | .green | .blue | .yellow | .orange | .red | .purple | .cyan | .pink
            .claude = .claude_orange, // the same names; .claude_orange is the chip's
            .codex = .cyan, // the same names; .cyan is the chip's
        },
        // The shape of the cursor mnml puts on the focused editor or
        // text field. .terminal follows the editing mode, as vim does:
        //   NORMAL / VISUAL  a block
        //   INSERT           a bar — and so does modeless (standard)
        //                    editing, which is an insert caret all the time
        //   REPLACE          an underline
        // Any other value is that one shape everywhere. A terminal
        // pane is never overridden: its child asked for a shape over
        // DECSCUSR and gets it (.pty_cursor above).
        .cursor_shape = .terminal, // .terminal | .block | .bar | .underline
        .external_browser = "", // a program to spawn; "" = the OS default (exec-bearing)
        // MNML_OPEN_URL in mnml's environment overrides every opener,
        // this one included: unset or empty opens as usual, `none`
        // drops the URL, any other value is a file each URL is
        // appended to (`<epoch seconds>\t<url>`) and nothing opens.
        // The icon every terminal wears — a pty tab's icon, the strip's
        // terminal chip. .ghostty is Ghostty's ghost, which mnml bakes
        // into its own face at U+F2000 and paints whatever emulator it
        // is running inside; .terminal is the codicon, and the only
        // value that brings the per-emulator table back (kitty's cat,
        // Apple's apple); .custom is terminal_glyph_svg, baked at the
        // same codepoint. Right-click the terminal chip -> Icon (each
        // row draws the icon it picks), the Settings overlay's
        // "Terminal icon" row, or the view.terminal_glyph_* commands.
        // The KEY keeps the older "glyph" spelling so a config already
        // on disk keeps working; "icon" is the word the UI uses.
        .terminal_glyph = .ghostty, // .ghostty | .terminal | .custom
        // The SVG behind .custom. view.terminal_glyph_custom prompts for
        // it, bakes <data root>/fonts/MnmlSymbols.ttf and sets both keys.
        .terminal_glyph_svg = "",
        // The icon Claude Code wears, everywhere the chrome draws one:
        // the tab bar's right cluster, a Claude pty tab, the statusline
        // meter, the launcher dock, a SESSIONS card. .figure is the
        // Claude Code figure mnml bakes at U+F1E00; .spark is the
        // Anthropic spark, one codepoint along at U+F1E02; .custom is
        // claude_mark_svg, baked at the figure's own codepoint. Right-
        // click the cluster's Claude chip (or a Claude pty tab) -> Icon
        // (each row draws the icon it picks), or the Settings overlay's
        // "Claude icon" row. The KEY keeps the older "mark" spelling so
        // a config already on disk keeps working; "icon" is the word
        // the UI uses.
        .claude_mark = .figure, // .figure | .spark | .custom
        // The SVG behind .custom. view.claude_mark_custom prompts for
        // it, bakes <data root>/fonts/MnmlSymbols.ttf and sets both
        // keys — the twin of terminal_glyph_svg above, and the same
        // bake: one face carries both, so replacing one icon never
        // takes the other one back to the shipped drawing.
        .claude_mark_svg = "",
        .top_bar_cluster_mode = .auto, // .auto | .expanded | .compact
        // .none hides the AI chips; otherwise an enabled integration icon
        // shows its chip, and a CLI found on PATH shows its chip when named
        // here (.claude_code | .codex | .both). view.tab_bar_ai_* set it.
        .tab_bar_ai_icon = .claude_code, // .none | .claude_code | .codex | .both
        // What the tab strip's maximize button does on a LEFT click.
        // .zoom_pane is the leaf zoom: the active pane's leaf alone
        // fills the editor area, the other splits hide, the chrome
        // stays. .fullscreen drops the tree, the strips and the
        // statusline and keeps every pane. There is no third scope —
        // a leaf IS the tab group. The button's right-click menu lists
        // both and ticks this one; while something is maximized the
        // button is the way back whatever the value says.
        .maximize_click = .zoom_pane, // .zoom_pane | .fullscreen
        .ai_layout_mode = .grid, // .grid (Claude tiles 2×2 → 4×2, eight per screen) | .tabs
        .ai_chip_use_mnml_glyphs = false, // deprecated, read by nothing: the chips always paint mnml's baked marks
        .auto_show_sessions_on_ai_activate = true,
        .git_section_default_expanded = false,
        .integrations_section_default_expanded = false,
        .hover_help = true,
        .hover_tooltip = false,
        .click_echo = false,
        .focus_follows_mouse = .off, // .off | .panes | .all — opt-in focus follows mouse: .panes focuses the split (editor, terminal, session) the pointer moves onto; .all also hands the side columns and the dock the keys. Never while a menu, picker, prompt, confirm or the which-key popup is up, a button is held or a chord is half-typed; it moves only the focus, never the view or the cursor
        .focus_follows_mouse_delay_ms = 0, // how long the pointer rests on the new target before it takes the focus; 0 is at once, clamped to 2000
        // `app.quit` (Ctrl+Q, the menu bar's Quit, the palette) always stops to ask — Quit / Cancel
        // with nothing unsaved, Save all / Quit anyway / Cancel with something, Cancel focused either
        // way. `false` asks only when something is unsaved. `:q!` / `:qa!` and the IPC `quit` /
        // `restart` never ask.
        .confirm_quit = true,
        // A terminal pane copies a mouse selection when the button comes up (ghostty's copy-on-select);
        // Ctrl+C over a selection then only clears it. `false`: a drag only selects and Ctrl+C over a
        // selection copies it. Either way Ctrl+C over a selection sends the child nothing, and with no
        // selection it is the child's ^C.
        .copy_on_select = true,
        .first_launch_complete = false, // set by the first-launch flow
        .config_toml_notice_shown = false, // set once the 0.2 config.toml notice has shown on this data root (see "Coming from 0.2.x")
        .integrations_toml_notice_shown = false, // set by `integrations.dismiss_toml_notice` — the 0.2 manifests notice, "Don't show again"
        .show_workspace_dots = true,
        // .builtin | .glow | .pandoc | .{ .custom = "cmd" } (exec-bearing)
        .md_preview_engine = .builtin,
    },

    // ── session / ipc ──────────────────────────────────────────────────
    .session = .{
        // Reopen the last session's panes, layout and chrome on
        // launch. Beside the editors, the previews and the
        // terminals that comes back a review in progress: a git
        // status pane, a workspace Search (its query, its case /
        // whole-word / regex options and the row it was on), a
        // commit graph, a worktree / HEAD / staged / per-file
        // diff and an image. Each re-RUNS its query rather than
        // replaying a saved result, and one whose subject is
        // gone (not a repo any more, the file deleted) is
        // skipped without a word.
        .restore = true,
        // What a saved TERMINAL pane comes back as. On .running a plain
        // shell restarts in the cwd it was saved in, and an AI session
        // pane whose session could be named resumes it — `claude
        // --resume <id>` off the id on its command line, `codex resume
        // <id>` off the id mnml looked up in the rollout that session
        // opened. Never a second session under an id that exists, never
        // a new billed one, and never `codex resume --last` (the newest
        // session on the machine is not necessarily this pane's): a
        // session that cannot be named falls through. On .dormant every
        // terminal pane waits instead. Either way a pane whose command
        // cannot be re-run safely — an arbitrary command line, a bare
        // `claude` with no id, a Codex pane whose session could not be
        // told apart from another started in the same directory —
        // comes back dormant.
        .restore_terminals = .running, // .running (a shell restarts, a Claude / Codex pane resumes its session) | .dormant (every terminal pane comes back `[exited] — any key restarts …`)
    },
    .ipc = .{
        .write_screen = false, // also dump screen.txt, status.json and rects.json every frame
        // Whether the file channel may drive INPUT at a live terminal
        // (key, type, click, scroll, drag, mouse_*, hover). The set an
        // integration needs (segments, badges, toasts, progress,
        // notify, register-command) is always taken; run-command of a
        // command above `view`, and open-pty, ask first (`.api` below);
        // the headless loop takes everything regardless.
        .allow_input = false,
        // Whether a key, click, wheel or paste at the live terminal writes
        // {"event":"input","kind":"key|mouse|paste"} to events.jsonl (one
        // a second per kind; never what was pressed; never the channel's
        // own input) — how a host replaying a script sees a person take
        // over (demo/attract/)
        .report_input = false,
    },
    // What a program in a pane may have mnml do without asking (see
    // "Commands a program asks for" below). Config-file only, and
    // stripped from an untrusted workspace's layer.
    .api = .{
        // Serve the API socket `mnml remote` talks to (docs/API.md). Off,
        // nothing is bound and no pane is told a socket. Read at start;
        // turned off while running, the socket answers only "the API is off".
        .enabled = true,
        // Command ids any caller may run unasked, e.g. .{ "git.refresh" }
        .allow_commands = .{},
        // Callers you trust, by name; "file-channel" is the file channel.
        // `.allow` takes classes (.exec covers open-pty), `.commands` ids.
        // An example — the default is .{}.
        .clients = .{
            .{
                .name = "file-channel",
                .allow = .{ .view }, // .view | .edit | .write | .exec
                .commands = .{ "test.run_file" },
            },
        },
    },
    // ── terminal panes ─────────────────────────────────────────────────
    // Read when a pane starts; a pane already open keeps what it began with.
    .terminal = .{
        .scrollback_lines = 10000, // lines kept above the screen per pane (Shift+PageUp, the wheel) — and what the terminal's search (`term.search`: `/` in terminal-normal, Ctrl+F under standard) reaches
        .osc52 = true, // a program in a pane may copy to the clipboard (OSC 52; neovim, tmux, ssh); reads are never answered
        // A shell pane's zsh, bash or fish loads mnml's shell integration:
        // OSC 133 marks around every prompt, command line and output, and
        // OSC 7 for the directory — so a multi-line prompt (starship,
        // powerlevel10k) is redrawn in place when the pane is resized, and
        // prompt jumps work with any prompt. Dotfiles untouched: zsh through
        // ZDOTDIR; bash as `bash --init-file`, which reads the login files
        // (/etc/profile, ~/.bash_profile …) first — so the shell is not a
        // login shell to `shopt login_shell`, `logout` or ~/.bash_logout;
        // fish through `--init-command` (fish 4 marks its own prompts and is
        // left to it). Each stands aside when another integration already
        // marks prompts. Off: exactly as before.
        .shell_integration = true,
    },

    // ── cloud ──────────────────────────────────────────────────────────
    .cloud_run = .{
        .defaults = .{ .agent_id = "", .env_id = "", .sandbox = "", .model = "" },
    },
    // There is no `.jira` section: its `.domain` and `.ticket_prefix` (and
    // MNML_JIRA_DOMAIN / MNML_JIRA_TICKET_PREFIX) were never read, and are
    // gone. The Jira integration's site is its own config's `.jira_url`
    // (integrations/jira/README.md); a session's ticket chip comes from
    // `.ui.ticket_prefixes`. A `.jira` left in a config.zon is reported as
    // an unknown section and ignored.
    .cloud_agents = .{
        .label = "",
        .short_id = "",
        .region = "", // MNML_CLOUD_AGENTS_REGION overrides
        .account_id = "",
        .runs_table = "",
        .cluster = "",
        .task_definition = "",
        .sg_export_name = "",
        .log_group = "",
        .aws_profile_fallback = "", // MNML_AWS_PROFILE overrides
        .s3_artifacts_bucket = "",
        .default_workspace_label = "", // "" reads as "cloud"
        .managed_agents_enabled = false,
        .refresh = .{ .fast_ms = 10000, .slow_ms = 30000, .idle_ms = 120000 }, // the cloud's own defaults, longer than the local ones because every read is an `aws` call. How often the runs table is read again: fast while SESSIONS or the sessions table is on screen and a run is in progress, slow while one is on screen with nothing running, idle while neither is; 0 is never. A response with the same bytes as the last is not parsed again
    },

    // ── dashboards ─────────────────────────────────────────────────────
    // How often the SESSIONS listing is read again behind its views — the
    // section, the sessions table. Milliseconds; 0 is never. `fast_ms`
    // applies while a view is on screen and a session is thinking or in a
    // tool, `slow_ms` while one is on screen with nothing live, `idle_ms`
    // while none is (the listing stays warm for the next open). The first
    // read starts with the app. `ui.dashboard_refresh` (Settings →
    // Integrations → Dashboard refresh) picks auto / fast / slow / manual;
    // the ⟳ chip and `sessions.refresh` read everything now, always.
    // The transcripts themselves are not on these intervals: a stat per
    // transcript (and a listing of the directories, for new ones) runs
    // every 500 ms while a view is on screen and every 2 s while none is
    // (never under manual), and a transcript whose size or mtime moved is
    // read at that tick — so a quiet machine stats and reads nothing.
    .sessions = .{
        .refresh = .{ .fast_ms = 2000, .slow_ms = 5000, .idle_ms = 30000 }, // the liveness pass: the process table, each session's state, `git status` per working directory — off screen it runs only while a session has a process or a transcript moved; on screen it runs every interval (a resumed session shows only as its process), and a view coming on screen runs one pass at once
    },

    // ── keys ───────────────────────────────────────────────────────────
    // One line per binding: chord → command id. "" / "none" / "unbound"
    // removes a default. .global applies to both profiles; .vim and
    // .standard on top of it. ZonGen rejects a chord written twice.
    // A shifted Tab has ONE chord however it is written: "shift+tab",
    // "<S-Tab>", "shift+backtab" and "backtab" are all `backtab`, and
    // "ctrl+shift+tab" is "ctrl+backtab" — that is what a terminal
    // sends, so a spec cannot name a key that never arrives.
    // The which-key popups read the keymap, rebinds included: a
    // `.standard` chord under `ctrl+k` is a row of the Ctrl+K popup
    // (the standard profile's `whichkey.leader`), a `.vim` chord under
    // `space` a row of the `<leader>` tree (docs/KEYMAP_PROFILES.md).
    .keys = .{
        .global = .{
            .@"ctrl+p" = "picker.files",
            .@"ctrl+shift+p" = "none",
        },
        .vim = .{
            .@"space f f" = "picker.files",
            .@"g d" = "lsp.goto_definition",
        },
        .standard = .{
            .@"ctrl+b" = "view.toggle_tree",
        },
    },

    // ── lsp ────────────────────────────────────────────────────────────
    // One entry per server. .cmd/.args are exec-bearing (stripped from an
    // untrusted workspace; .extensions etc. still apply). .settings and
    // .initialization_options are forwarded verbatim as JSON; a server's
    // `workspace/configuration` for a section the settings hold (`python`,
    // `python.analysis`) gets that part, any other gets them whole.
    // pyright (the python row, or any *pyright* binary) starts with
    // `.python.pythonPath` = `<root>/.venv/bin/python` (else `venv/`, else
    // the workspace's) when one exists; a `pythonPath` / `venvPath` in
    // .settings, flat or under `.python`, wins.
    // Built-in defaults (`src/lsp/client.zig`), each overridable field by
    // field under its name: rust (rust-analyzer), python (pyright),
    // typescript, go (gopls), c (clangd), zig (zls), lua, json
    // (vscode-json-language-server --stdio, .json/.jsonc), yaml
    // (yaml-language-server --stdio), html, css (.css/.scss/.less; the
    // vscode-*-language-server pair from `npm i -g
    // vscode-langservers-extracted`), csharp (csharp-ls, `dotnet tool
    // install -g csharp-ls`; roots at the nearest `*.sln` / `*.slnx`
    // anywhere above the file, else the nearest `*.csproj`, else
    // global.json — ranked, so every project of a solution shares one
    // server; a `*` marker is a glob) and bash (bash-language-server
    // start, `npm i -g bash-language-server`; .sh/.bash/.zsh, and any
    // extension-less script or dotfile the detector reads as shell —
    // the server runs shellcheck itself when it finds it, so the builtin
    // `.linters` row for shell stands down while it is attached). A
    // default that is not installed is `.editor.lsp_missing_defaults`'
    // business (quiet); a server named here that is missing always toasts.
    // An entry written to this file AFTER launch is found on the next
    // open of a matching file, for a default-owned extension too (a
    // `.lsp.zig.cmd` pointing at a zls off PATH takes over from the
    // default without a restart); a trust change re-reads the table and
    // forgets which servers were missing. `.cmd` is resolved once, on
    // mnml's own PATH (a `# env: PATH=…` header in a `.test`, an in-app
    // env edit), and that path is what is spawned. A server's requests
    // to mnml carry whichever id kind the server chose — zls asks
    // `workspace/configuration` with a string id — and `.settings` go
    // back under that same id, which is how zls learns its
    // `zig_lib_path` (definition / hover / completion into std) and
    // `enable_build_on_save`.
    .lsp = .{
        .rust = .{
            .cmd = "rust-analyzer", // null = mnml's built-in default
            .args = .{},
            .extensions = .{ "rs" },
            .root_markers = .{ "Cargo.toml" },
            .settings = .{ .cargo = .{ .allFeatures = true } },
            .initialization_options = .{},
        },
    },

    // ── ai ─────────────────────────────────────────────────────────────
    .ai = .{
        .backend = null, // legacy; .auto | .api | .sub | .off
        .routing = .{
            .claude = .{ .backend = null }, // wins over .backend
            .codex = .{ .backend = null },
        },
        // A named way to start claude / codex; the AI chip's right-click lists
        // them and the mnml-ai-<name> shim exports .env. The built-in `default`
        // (the bare binary) is implicit.
        .launch_profiles = .{
            .{
                .name = "work",
                .product = .claude, // .claude | .codex
                .binary = "claude", // a path, or a name on PATH
                .args = .{},
                .env = .{ "KEY=VALUE" },
                .cwd_mode = .workspace, // .workspace | .home | .file_dir
                .worktree = false, // true: every session of this profile starts in a git worktree of its own
            },
        },
        .default_profile = .{ .claude = null, .codex = null }, // a profile name per product; null = the built-in
        // Where a session worktree goes. null = `<repo>-worktrees` beside the
        // repository; `~` expands, a relative path sits under the repository.
        .default_worktree_root = null,
        .inline_suggestions = true,
        // Which backend answers a ghost-text request. Not a typed field —
        // ai.setup_suggestions writes it and a runtime override wins for the
        // session. "claude-code" (your Max/Pro plan, via `claude -p`),
        // "claude-api" ($ANTHROPIC_API_KEY), "copilot" (your GitHub Copilot
        // seat, per-workspace and off until you opt in — see .copilot below),
        // "local" (not in this release). Unset by default: no request goes
        // out and a one-time hint points at ai.setup_suggestions — the value
        // here is an example.
        .suggest_backend = "claude-code",
        // The model ghost text asks, and ONLY ghost text — the panes and the
        // agents keep .model. It defaults to a fast one: a suggestion is worth
        // having only if it beats you to the next token, so the trade the rest
        // of the app makes (the best model, however long it takes) is the wrong
        // one here.
        .suggest_model = "claude-haiku-4-5",
        // Idle time after your last keystroke before a request goes out
        // (50..5000, clamped). Lower feels eager and spends more; higher waits
        // out a typing burst.
        .suggest_idle_ms = 300,
        // The wall-clock budget one request gets (500..120000, clamped). Past
        // it the child is killed, the statusline chip turns to ! and :messages
        // says `timeout`. An answer that arrives after four seconds is for a
        // cursor that has moved on.
        .suggest_timeout_ms = 4000,
        // The wall-clock budget one AI job's CLI gets — `claude -p` / `codex
        // exec` behind ai.explain / fix / ask / chat, git.ai_commit,
        // git.explain_branch and the PR drafts (5000..3600000, clamped). Past
        // it the child is killed, the pane says so and a toast names this key.
        // Cancel (`c`), closing the pane and a re-ask (`r`) kill it at once.
        // The same budget bounds each request of the API backend. The API's
        // base URL is the real one unless MNML_ANTHROPIC_BASE_URL (an
        // environment variable — never a config key, which a cloned repo
        // could set to collect your key) points it at a proxy or a mock.
        .cli_timeout_ms = 600000,
        // Also read out of `.ai` without a typed field. `.model` is the
        // model ai.explain / fix / ask / chat ask for — the Messages API
        // backend's model, and `claude -p --model` when it is not the
        // default. The next four are the API backend's alone: an extra
        // system prompt (null = none), whether the agent loop gets its
        // read-only tools, whether it may also write files, and the reply's
        // token cap (1..199999; anything else is the default). `.layout_mode`
        // is the 0.2.x spelling of `.ui.ai_layout_mode` ("grid" / "tabs")
        // and wins over it when set.
        .model = "claude-sonnet-4-5",
        .system_prompt = null,
        .api_tools = true,
        .api_write_tools = false,
        .max_tokens = 4096,
        .layout_mode = null, // "grid" | "tabs"; null = .ui.ai_layout_mode
        // GitHub Copilot as the ghost-text backend. NOTHING is sent until
        // THIS workspace opts in: `suggest_backend = "copilot"` alone shares
        // nothing, and there is no key that opts in on another workspace's
        // behalf. `ai.copilot_status` says what is shared right now and why.
        .copilot_here = false, // the opt-in, per workspace, default off
        .copilot = .{
            // The language server's argv. Empty = `copilot-language-server
            // --stdio` on PATH. mnml NEVER downloads it — a missing binary is
            // one toast with the install line. Write
            // .{ "npx", "--yes", "@github/copilot-language-server", "--stdio" }
            // if that is how you want it fetched (exec-bearing).
            .command = .{},
            // Files never sent. Empty = the shipped list (.env*, *.pem, *.key,
            // id_*). Setting it REPLACES that list; the secret-name check and
            // the gitignore check apply either way and cannot be turned off.
            .exclude = .{},
            // A GitHub Enterprise instance, passed to the server as
            // `github-enterprise.uri`.
            .github_enterprise_uri = null,
        },
        .claude_show_all_accounts = false,
        // How the statusline's Claude chip shows several accounts: .off = the
        // active one alone, .compact = a sparkline block per account, .ticker =
        // one account at a time, 4 s each (ai.chip_show_all_*). With one
        // account it is always the single chip; what that chip shows —
        // session %, weekly %, both; the reset countdown — is the chip's
        // right-click (ai.chip_show_session / _weekly / _both, ai.chip_toggle_reset).
        .claude_meter_mode = .compact, // .off | .compact | .ticker
        // The sessions mode — the Sessions row of the activity bar, or
        // sessions.mode: the editor layout is put aside and every Claude Code
        // / Codex session stands in this many columns side by side, each a
        // stack of the rest; leaving puts the layout back. 1 is one session
        // maximised. 1..4, clamped on load; the AI chips' right-click
        // *Show side by side* sets it (sessions.columns_1 … _4).
        .session_columns = 2,
        // The Claude Code logins the quota chip and the usage pane
        // (ai.claude_usage) poll. `token_path` is the OAuth token file the
        // CLI's keychain item was copied into (`ai.link_claude_token`, or R
        // in the pane on macOS) — `~` expands, a relative path sits under the data
        // root beside the default `ai_token`; `active` marks the one the
        // chip shows alone (the CLI's live login wins when the keychain
        // names one). No entries = one `default` account on `ai_token` — or
        // the 0.2.x `[[ai.claude.accounts]]` blocks, which the migration keeps
        // verbatim as `.ai.claude.accounts` and the reader honours as-is.
        // The app edits this list itself, one account per line:
        // ai.claude_add_account (`a` in the usage pane) appends a name with
        // a token file of its own (`ai_token.<slug of the name>`, under the data root),
        // ai.claude_rename_account changes a name, ai.claude_remove_account
        // drops an entry and deletes its token file when that file is the
        // data root's. Comments inside the list do not survive such an edit.
        // MNML_CLAUDE_USAGE_FIXTURE=<dir> replaces the wire with files (the
        // tests, the spec dumps; see src/ai/usage.zig).
        .claude_accounts = .{
            .{ .name = "personal", .token_path = "ai_token.personal" },
            .{ .name = "work", .token_path = "~/.claude/work.json", .active = true },
        },
    },

    // ── tools ──────────────────────────────────────────────────────────
    // Forwarded verbatim to integrations; mnml reads nothing here.
    .tools = .{},

    // ── http / ws ──────────────────────────────────────────────────────
    .http = .{
        .default_env = null, // name of the env in .env files
        .collection_root = .hidden, // .hidden (.rqst/) | .workspace
        .auto_format_body = true,
        .sync_normalize = false,
        // Transport defaults for every send; a block's own directive
        // (`# @insecure`, `# @timeout 5s`, `# @no-redirect`,
        // `# @max-redirects 3`, `# @proxy host:port`) overrides them for
        // that request, and the Auth tab's Options rows write those lines.
        .insecure = false, // skip the certificate chain check (curl -k)
        .timeout_ms = null, // a deadline over the whole send; null waits
        .follow_redirects = true,
        .max_redirects = 10,
        .proxy = null, // "host:port", "user:pass@host:port", "http://host:port"
    },
    .ws = .{
        .subprotocols = .{},
        .ping_interval_secs = 30,
        .reconnect_max_attempts = 3, // after a drop, or a server close of 1001 / 1011–1014
        .reconnect_on_close = false, // true: after every server Close frame (1000, 4xxx, …)
    },

    // ── sonos ──────────────────────────────────────────────────────────
    .sonos = .{
        .enabled = true,
        .host = null, // null = discover
        .room = null,
        .poll_secs = 3,
        .chip_label = .never, // .never | .hover | .always
        .prefer_airplay = true,
    },

    // ── git_graph ──────────────────────────────────────────────────────
    .git_graph = .{ .lane_spacing = 1 },

    // ── git ────────────────────────────────────────────────────────────
    // Repo accents, by repo name: one of green blue yellow orange red
    // purple cyan pink (`src/ui/accent_color.zig`, the same palette the
    // sessions use), or "none" for the auto slot. With two or more repos
    // in the workspace the app writes each repo's slot here the first
    // time it sees it (the first assignment wins across restarts) and the
    // repo pill's right-click Color menu writes a pick; one repo shows no
    // accent. Home layer only — a workspace file's entries are read but
    // the app writes home.
    .git = .{ .repo_colors = .{ .api = "green", .@"web-app" = "blue" } },

    // ── tasks / startup ────────────────────────────────────────────────
    // The project runners need no entry here: `test.run_all` /
    // `run_file` / `run_at_cursor` / `rerun_failed` pick the project
    // from the nearest manifest at or above the open file — Cargo.toml
    // (`cargo test`), package.json (`npm test`), go.mod (`go test`),
    // *.csproj / *.sln (`dotnet test`, in the TESTS pane), build.zig
    // (`zig build test` / `zig test <file>` / `zig build test
    // -Dtest-filter=<name>` when the build.zig declares that option, else
    // `zig test <file> --test-filter <name>`; the TESTS pane, rows from
    // `zig`'s own report), or a Python layout (`pytest`). A `.cs` / `.zig`
    // file asks for its own project first, so a `package.json` at the
    // root of a mixed repo does not take it. `.tasks` is for everything
    // else — a task runs only when you name it.
    .tasks = .{
        .build = .{ .cmd = "zig build", .cwd = null },
        .@"test" = .{ .cmd = "zig build test" }, // keywords need @"…"
    },
    .startup = .{
        .tasks = .{ "build" }, // task names to run on open (exec-bearing); an example — the default is .{}
        // Panes to open. The first entry needs no .split; every later one
        // does. .kind = .pty runs .cmd under $SHELL -c (exec-bearing).
        .layout = .{
            .{ .kind = .editor, .path = "README.md" },
            .{ .kind = .pty, .cmd = "zig build --watch", .split = .right, .ratio = 40 },
        },
        .default_workspace = null, // "~/code/mnml"; ~ is expanded
    },

    // ── snippets / abbr ────────────────────────────────────────────────
    // A scope is a language name or an extension — `.rust` and `.rs` are
    // one scope, `.yml` is `.yaml` — or `.global` for every file. TSX
    // files also take the `.ts` snippets, JSX files the `.js` ones. Read
    // at launch and on every config reload.
    .snippets = .{
        .rust = .{
            .@"fn" = "fn $1($2) {\n    $0\n}",
        },
        .zig = .{
            .@"test" = "test \"$1\" {\n    $0\n}",
        },
    },
    .abbr = .{
        .teh = "the",
    },

    // ── formatters / linters (exec-bearing) ────────────────────────────
    // A row is keyed by a file extension OR by a language key — the one
    // `mnml` detects from the file's name, its extension or its shebang
    // (`src/highlight/detect.zig`): `.sh` answers for `run.sh`, for a
    // `bin/run-all` that starts `#!/usr/bin/env bash`, and for a `.zshrc`.
    // A row for the exact extension wins over the language's. The builtin
    // tables (`src/lsp/tools.zig`) are read the same way.
    // Who formats a file (`lsp.format`, `editor.format`, format-on-save):
    //   1. `.formatters.<ext>` below — you chose the tool; it wins.
    //   2. the builtin tool for the extension (prettier / rustfmt / ruff /
    //      stylua …) when the PROJECT carries its config — a `.prettierrc`
    //      (or a `prettier` key in package.json), `rustfmt.toml`,
    //      `ruff.toml`, `stylua.toml` — and the tool is found; the
    //      project chose, whatever the language server would do.
    //   3. the language server, when it formats.
    //   4. the builtin tool, without a project config.
    // `editor.format_external` skips the list and always runs the tool.
    // A tool given by a bare name (a builtin's, or one here or under
    // `.linters`) is looked for in `node_modules/.bin` beside the file and
    // in each directory above it up to the workspace root, then on PATH —
    // npm's rule: a JS/TS project's own prettier and eslint run.
    .formatters = .{
        .rs = .{ .cmd = .{ "rustfmt", "--edition", "2024" } }, // stdin → stdout
        .zig = .{ .cmd = .{ "zig", "fmt", "--stdin" } },
        // A tool that rewrites the file: the buffer is written, the tool runs
        // on {file} (the workspace-relative path), the result is read back.
        .go = .{ .cmd = .{ "gofmt", "-w", "{file}" }, .in_place = true },
    },
    // Linters run on open and on save, beside a language server's
    // diagnostics (source id 0 in the panel). A BUILTIN row stands down
    // for a file a server is attached to — bash-language-server runs
    // shellcheck itself, and the tool's copy of each finding doubled the
    // panel, the badges and `]d`. A row written here was asked for and
    // runs regardless, as does `editor.lint_external`.
    .linters = .{
        .sh = .{ .cmd = .{ "shellcheck", "-f", "gcc" }, .parser = .shellcheck },
        // .parser: .vimgrep (default, path:line:col: msg) | .eslint (its --format=json, or the unix lines) | .tsc | .ruff | .shellcheck | .pattern
        // .pattern matches a line template of placeholders literally between them:
        .log = .{ .cmd = .{ "mylint", "{file}" }, .parser = .pattern, .pattern = "{file}:{line}:{col}: {severity}: {message}" },
    },

    // ── dap (exec-bearing) ─────────────────────────────────────────────
    .dap = .{
        // The key is the file extension `dap.run` (F5) looks the adapter
        // up by. `.launch` is the request body, verbatim, after
        // `${file}` / `${fileBasename}` / `${fileDirname}` /
        // `${workspaceFolder}` are filled in; left out, it is
        // `{ program: ${file}, cwd: ${workspaceFolder} }`.
        .lldb = .{
            .cmd = "lldb-dap",
            .args = .{},
            .launch = .{ .program = "${workspaceFolder}/zig-out/bin/mnml-zig" }, // verbatim
        },
        // lldb-dap (Xcode: `xcrun -f lldb-dap`; LLVM: on PATH) on a
        // `cc -g` binary. The client sends `launch` on the `initialize`
        // reply and configures on `initialized`, the order lldb-dap and
        // debugpy need.
        .c = .{
            .cmd = "lldb-dap",
            .launch = .{ .program = "${workspaceFolder}/prog", .cwd = "${workspaceFolder}" },
        },
        // Attaching is the same table with `.request = "attach"` and the
        // adapter's own keys — lldb-dap takes a `.pid`; `dap.run` then
        // attaches. Stop on an attached session DETACHES (`disconnect {
        // terminateDebuggee: false }`) — the process you attached to
        // keeps running.
        .cpp = .{
            .cmd = "lldb-dap",
            .launch = .{ .request = "attach", .pid = 12345 },
        },
        // debugpy: `python3 -m debugpy.adapter` over stdio. `.console =
        // "internalConsole"` keeps the program's output in the Debug
        // Console (mnml answers a `runInTerminal` reverse request with
        // a failure). To attach, start the program with `python3 -m
        // debugpy --connect 127.0.0.1:5678 script.py` and use the
        // `.listen` shape below instead of `.program`.
        .py = .{
            .cmd = "python3",
            .args = .{ "-m", "debugpy.adapter" },
            .launch = .{ .program = "${file}", .cwd = "${workspaceFolder}", .console = "internalConsole" },
            // .launch = .{ .request = "attach", .listen = .{ .host = "127.0.0.1", .port = 5678 } },
        },
        // `$NAME` / `${NAME}` in .cmd or an argument expands from the
        // environment when the adapter is spawned; dap.run re-reads
        // this table when the file has no adapter yet (trusted only).
        //
        // Built in, consulted after this table and the re-read, so an
        // entry here for the same key wins (`dap.builtin_adapters`):
        //   .cs = .{ .cmd = "netcoredbg", .args = .{ "--interpreter=vscode" } }
        //     launch = { program: <csproj dir>/bin/Debug/<TargetFramework>/<AssemblyName>.dll, cwd: <csproj dir> }
        //     — derived from the nearest .csproj at or above the file
        //     (`<AssemblyName>` else the file's stem; `<TargetFramework>`,
        //     else the first of `<TargetFrameworks>`, else net8.0). The
        //     assembly must be built: `dotnet.debug` runs `dotnet build` in
        //     a task pane first and starts the session when it exits 0;
        //     `dap.run` (F5) on a .cs file launches what is already built.
        //     netcoredbg is a release download (github.com/Samsung/netcoredbg);
        //     its `all` / `user-unhandled` exception filters appear in
        //     `dap.exceptions`, `user-unhandled` on by default.
    },

    // ── browser / ci / integrations ────────────────────────────────────
    .browser = .{
        .headless = false,
        // Every Document / XHR / Fetch request is appended to
        // <ws>/.rqst/captured/log.jsonl as it starts. The headers are the
        // page's own: the Cookie Chrome's network stack adds reaches a
        // re-send (Enter) and a copy-as-curl (y), never this file.
        .autocapture_to_log = true,
        .profile_mode = .workspace, // .workspace | .shared | .ephemeral
        // Where Chrome keeps cookies / logins: .workspace is
        // <ws>/.mnml/chrome-profile, .shared <data root>/chrome-profile.
        // A second pane opens on the lowest free `-N` sibling — one no
        // open pane uses and no live Chrome holds (Chrome's own
        // SingletonLock). A lock held by a headless Chrome an earlier
        // mnml started and left behind (a kill -9, a panic: its argv
        // names this profile and it was adopted by pid 1) is cleared by
        // stopping that Chrome, and the pane's log says so; any other
        // holder — another mnml's pane, your own Chrome — is left alone.
        // .ephemeral gives every open its own
        // <ws>/.mnml/chrome-profile-ephemeral-<random>, deleted when the
        // pane closes; browser.wipe_profile clears any a crash left.
    },
    .ci = .{
        .provider = null, // "codebuild" …
        .project = null,
        .region = null,
    },
    .integrations = .{
        .auto_update_cargo = false,
        .auto_update_git = false,
        .open_as = .split, // .split (a mounted integration opens BESIDE the active pane, side by side — the Rust behaviour) | .tab (another tab in the active leaf)
        .equalize_on_open = true, // after an integration split, even the splits out whatever ui.auto_equalize_splits says
        // How a pane that opens as a SPLIT sizes itself — every such
        // path, not only an integration's: terminals and the session
        // panes go through the same rule (src/app/arrange.zig).
        //   .context — an empty editor area takes the pane full, and a
        //     split evens out every sibling along the new split's axis
        //     (three panes are thirds, four are quarters). A stack
        //     across that axis keeps the proportions it was dragged to.
        //   .fixed — the old behaviour: the new pane halves the active
        //     one and nothing else moves (an integration's
        //     equalize_on_open still applies, a terminal's does not).
        .arrange = .context,
        // Folders the INTEGRATIONS section's Dev tab scans: every
        // subfolder with a build.zig and a manifest.zon beside it is an
        // integration in development (Build / Install / Rebuild +
        // reinstall from the row). Relative to the workspace, `~`
        // expanded. A workspace with sdk/mnml-sdk adds its own
        // integrations/ by itself.
        .dev_roots = .{ "../my-integrations" }, // an example — the default is .{}
        // The statusline poller: what keeps a manifest's chip counts
        // live with no pane open. It runs each manifest's
        // `values_sources` command (`mnml-bitbucket --values`) on that
        // source's interval, staggered, backing off on a failure, and
        // never while a pane of that integration is open.
        .poll = .{
            // Off means a chip moves only when its pane or its refresh
            // command says so.
            .enabled = true,
            // The floor under every manifest's own poll_interval_secs —
            // your say in how hard your API budget may be spent. The
            // poller's own 30-second floor still applies underneath.
            .min_interval_secs = 60,
        },
        // Every integration's requests, one JSON line each, in
        // <data root>/requests/<service>.jsonl (integrations.requests
        // opens the view). Integrations mnml starts are handed both as
        // MNML_REQUEST_LOG / MNML_REQUEST_LOG_MAX_MB.
        .request_log = .{
            .enabled = true,
            .max_mb = 4, // the ceiling before a file rotates; one older generation is kept
        },
        // Host the API broker while mnml runs: one queue per service
        // in front of the shared token bucket, so the pane you are
        // looking at gets the next token before a warmer or a batch
        // script that asked earlier. One broker per service across
        // every mnml on the machine (a second window becomes its
        // client), and the REQUESTS header shows it.
        //
        // Off puts everything back on the file bucket and its
        // first-come order — including the integrations mnml starts,
        // which are told so rather than left to open a socket nobody
        // is on. Unix sockets only: Windows has the file bucket.
        .broker = true,
    },

    // ── workspaces ─────────────────────────────────────────────────────
    .workspaces = .{
        .{ .name = "mnml", .path = "~/Projects/mnml", .group = "personal" },
    },

    // ── marketplace ────────────────────────────────────────────────────
    .marketplace = .{
        .enabled = true,
        .cache_ttl_secs = 3600,
        // Prepend mnml's own sources. First, this repo's releases: every
        // mnml release carries `integrations.json`, the index of the
        // integrations built for that version — each on its own
        // `<id>-v<version>` tag, one archive per platform with its
        // sha256. A row is listed only when its SDK is compatible with
        // this mnml's and it was released for this platform. Install
        // downloads the archive, refuses it unless the sha256 matches,
        // writes the binary to `<data root>/integrations/<id>/bin/`,
        // links `<data root>/bin/<name>` at it and runs
        // `<binary> --install`. A dev build (a checkout, whose version
        // has no release) skips the index. Nothing is bundled in the
        // mnml archive; the first-launch setup offers Jira and Bitbucket
        // from the same index.
        //
        // Second, the `mnml` catalogue — the integrations this checkout
        // builds (Jira, Bitbucket, the SDK sample): `data/marketplace.zon`,
        // also packaged as `share/mnml/marketplace.zon`. Installing one
        // of its rows runs `<binary> --install` and links
        // `<data root>/bin/<name>` at the binary — PREFIX's copy after
        // `run.sh install`, else this checkout's `zig-out/bin` — which is
        // what keeps a manifest from ever hardcoding a repo path. A
        // catalogue row the release index also lists is dropped: the
        // index's download is the install. A row says `installed`,
        // `update available` (the source is ahead of the installed
        // manifest's version) or `not installed`.
        //
        // With no config at all, `<data root>/marketplace/local/` is
        // listed too, as the `local` source with the Private badge:
        // every *.zon in it a manifest, every folder with a build.zig
        // and a manifest.zon an integration built in place — and a repo
        // symlinked in whole lists its `integrations/<id>/` folders (up
        // to three levels down; never its own build.zig.zon). Symlink a
        // private integrations repo there and it shows up for its
        // author, nowhere else.
        .use_defaults = true, // prepend this mnml's release index and the checkout's catalogue
        .sources = .{
            .{ .crates_keyword = .{ .id = "crates.io", .keyword = "mnml-integration" } },
            .{ .github_launcher_folder = .{ .id = "me/launchers", .repo = "me/launchers", .path = "launchers" } },
            .{ .github_monorepo_apps = .{ .id = "me/apps", .repo = "me/mono", .apps_dir = "apps" } },
            // A folder on this machine or a mounted share — the private
            // path: every *.zon in it is a manifest to install as-is (a
            // launcher), every subfolder with a build.zig and a
            // manifest.zon a Zig integration built in place. Relative to
            // the workspace, `~` expanded. `MNML_MARKETPLACE_LOCAL=<folder>`
            // in the environment makes such a folder the only source.
            // The repo's own launchers/ lists as ✓ Official, not Private:
            // it is the official set.
            //
            // No need to write this by hand: `marketplace.add_source`
            // (the palette, the Marketplace tab's `+ source` chip, the
            // INTEGRATIONS tab strip's right-click menu) and the
            // first-launch setup's Private integrations row take a folder,
            // `owner/repo[:apps_dir]`, or a GitHub repo URL (https or no
            // scheme, a trailing `.git`, `…/tree/<branch>/<dir>` for the
            // apps dir, `git@github.com:owner/repo.git`; the branch is
            // dropped — a source lists the default branch) and append
            // the entry here, in the HOME config.zon only (never a
            // workspace's), comments and order kept. Refused: a folder
            // with nothing to install, a folder or repo already a source
            // (folders compared by real path, repos ignoring case), and
            // anything while `.enabled = false`. The id is the folder's
            // or repo's name, made unique.
            .{ .local_folder = .{ .id = "private", .path = "~/mnml-private" } },
            // A release index somewhere else — a mirror, or a fork's
            // releases. `{version}` in the URL is this mnml's version; a
            // dev build skips a URL that needs one.
            .{ .release_index = .{ .id = "mirror", .url = "https://mirror.example/mnml/v{version}/integrations.json" } },
        },
        // Four environment overrides, for a scripted run (the .test
        // corpus, the UI specs) and for pointing a session somewhere
        // without editing a config:
        //   MNML_MARKETPLACE_CATALOGUE=<file>   the `mnml` source reads
        //       this catalogue instead of the shipped one. Relative
        //       paths are workspace-relative; `~` expanded.
        //   MNML_MARKETPLACE_INDEX=<url>        a release_index source
        //       named `index` at that URL, and the ONLY source while it
        //       is set — how a dev build installs from a release.
        //   MNML_MARKETPLACE_LOCAL=<folder>     a local_folder source,
        //       and the ONLY source while it is set.
        //   MNML_MARKETPLACE_GITHUB=<owner>/<repo>[:<apps dir>]
        //       a github_monorepo_apps source (default apps dir
        //       `apps`), and likewise the only source. Pair it with
        //       MNML_MARKETPLACE_API=<base url> to point the fetch at
        //       a server other than api.github.com.
        // INDEX, LOCAL and GITHUB replace the configured sources
        // entirely; CATALOGUE only changes which file the `mnml` source
        // reads.
        .show_dev_tab = false,
        // The Marketplace tab opens with a FONTS section: every Nerd
        // Font family installed (the platform font folders, read from
        // the font files' own name tables) against the latest release,
        // with a one-click update on macOS. Nothing here configures it;
        // two environment variables do: MNML_FONT_DIRS=<dir:dir> (`;`
        // on Windows) replaces the folders scanned, MNML_NERDFONTS_LATEST=X.Y.Z
        // names the latest release and skips the once-a-day lookup
        // (cached at <data root>/cache/nerdfonts-latest.json).
    },

    // ── scripts ────────────────────────────────────────────────────────
    // Installed Lua scripts (docs/LUA.md, "Installing scripts"). A
    // script is a directory under <data root>/scripts/<name>/ holding a
    // script.zon, an init.lua and optionally lib/*.lua and a README.md,
    // and it gets its OWN Lua state: its own budget clock, its own
    // decoration namespaces, its own require root. The SCRIPTS section
    // lists them on three tabs — installed · marketplace · dev — the way
    // INTEGRATIONS does.
    // Installed scripts land in <data root>/scripts/ unless
    // MNML_SCRIPTS_ROOT=<folder> names somewhere else — how the corpus
    // keeps each file's installs to itself.
    .scripts = .{
        // The curated set ships with mnml — the repo's own lua/ folder,
        // packaged as share/mnml/lua beside the binary — so the
        // Marketplace tab lists it out of the box with no config at
        // all. This key points the tab at a folder of YOUR script
        // directories instead: an offline mirror, a company set, a test
        // fixture. Relative to the workspace, `~` expanded.
        // MNML_SCRIPTS_MARKETPLACE=<folder> overrides it, which is how
        // the corpus and the UI specs seed the tab.
        .marketplace_local = "",
        // Folders of script directories you maintain — a company repo, a
        // mounted share. Listed with the `private` badge; the same trust
        // dialog on install. Relative to the workspace, `~` expanded.
        .private_sources = .{ "~/mnml-private-scripts" }, // an example — the default is .{}
        // Folders the Dev tab scans: every subfolder with a script.zon
        // is a script in development, reloaded when one of its files is
        // saved. MNML_SCRIPTS_DEV_ROOTS=<dir:dir> (`;` on Windows)
        // overrides, which is how the corpus and the UI specs point the
        // tab at a folder without writing a config.
        .dev_roots = .{ "../my-scripts" }, // an example — the default is .{}
        .show_dev_tab = false,
    },

    // ── statusline ─────────────────────────────────────────────────────
    .statusline = .{
        .hover_items = 8, // how many things a figure's hover lists before `… and N more`; 0 lists none
    },
}
```

The block above is parsed by a test (`docs config example parses clean`
in `src/config/load.zig`): a key the schema lacks, or a section left
out, fails it. The values beside the keys are not compared by that test
— they are the defaults because the file is kept that way. Sections
appear in `Config.zig`'s field order.

## Commands a program asks for

The API socket (`docs/API.md`, `mnml remote`) asks the same way and
writes the same audit lines, with the asking pane as the client
(`pane:4`, and its title in the toast); a grant for the session lasts
while that pane is open, and a `.api.clients` row named `pane:<id>`
matches it. A connection without a pane's token is `unknown` and may
only read. `.api.enabled` (Settings → Integrations → API) turns the
socket off.

Any program in a pane can append a line to
`<workspace>/.mnml/ipc/command`. Under the live terminal, that file
channel's `run-command` of anything that can change more than the
view, and every `open-pty`, waits for you:

- A warn toast says what is asked — `a program wants to run
  scratch.new (edit) through the file channel` — with a **Review**
  button. It never steals the key you are typing.
- Review (a click on the toast, or `toast.run_action`) opens the
  confirm box: **Allow once**, **Allow *edit* for the session**,
  **Deny**, **Cancel**. Cancel holds the focus and puts the request
  back on its toast.
- Nothing answered in two minutes is denied.

Every command has a class — `view`, `edit` (a buffer), `write` (disk,
git, the network, config) or `exec` (a process) — listed in
`docs/commands.md`. A `view` command runs unasked; a command registered
at runtime is `exec`. A grant for the session covers one class until
mnml quits.

Every decision is a line in `<workspace>/.mnml/ipc/audit.jsonl`
(owner-only) and an `{"event":"api",…}` line in `events.jsonl`:

```json
{"ts":1759400000123,"client":"file-channel","method":"run-command","target":"git.commit","class":"write","decision":"denied","by":"user"}
```

`decision` is `free`, `allowlisted`, `granted-once`,
`granted-session`, `denied` or `timed-out`; `events.jsonl` also gets a
`pending` line when a request starts waiting.

To let something through unasked, write it in `config.zon` — there is
no Settings row:

```zig
.api = .{
    .allow_commands = .{ "git.refresh" },
    .clients = .{ .{ .name = "file-channel", .allow = .{ .edit }, .commands = .{ "test.run_file" } } },
},
```

The headless loop (`--headless`, the `.test` runner) is the test driver
and is never asked. `mnml-drive launch --allow-input` writes a
`file-channel` row allowing every class, since a channel that may type
can already run anything a key can.

## Workspace trust

A workspace config is written by whoever owns the repo. Before its
exec-bearing keys apply, mnml lists them and asks once:

```
 Trust this workspace?
   proj runs programs from its .mnml/config.zon:
     • language server zig — runs `zls` when you open a file
     • format on save zig — runs `zig fmt` when you save
   Until trusted these settings are ignored; the rest apply.
                                        [T]rust   [D]on't trust
```

*Don't trust* is the focused choice, so a reflexive Enter is the safe
answer; the question comes back next launch. *Trust* records a
fingerprint of the claims — FNV-1a over each `kind / key / command`
line, sorted — in `<data root>/trusted_workspaces.zon`, keyed by the
canonical workspace path:

```zon
.{
    .@"/Users/me/proj" = "3f2a9c0e11d4b7a8",
}
```

A later change to any command changes the fingerprint and asks again;
ordinary edits to the file do not. A workspace file with no
exec-bearing key never asks. Until trusted, these are dropped from the
workspace layer and everything else still applies:

| key | runs |
|---|---|
| `.ui.external_browser` | when you open a link |
| `.ui.md_preview_engine = .{ .custom = … }` | when you preview markdown |
| `.lsp.<name>.cmd` / `.args` | when you open a file |
| `.formatters.<ext>` | when you save |
| `.linters.<ext>` | when you lint |
| `.dap.<name>` | when you start a debug session |
| `.startup.layout[]` with `.kind = .pty` | immediately, on open |
| `.startup.tasks` | immediately, on open |
| `.ai.launch_profiles[]` (`.binary` / `.args` / `.env` / `.worktree`) and `.ai.default_profile` | when you start a Claude / Codex session |
| `.ai.copilot.command` | when you type, with Copilot ghost text on |
| `.ai.copilot_here` | when you type, with Copilot ghost text on |
| `.mnml/init.lua` (the script beside the config) | on open, and on `script.reload` |
| `.mnml/integrations/*.zon` (the manifests beside the config) | when one of their commands runs |
| `.scripts.dev_roots` / `.scripts.private_sources` (every script folder under them) | every time mnml starts |
| `.scripts.marketplace_local` (the folder the SCRIPTS Marketplace tab badges `official`) | when you install from the Marketplace tab |

(`.tasks.<name>` bodies are not in the table: a task only runs when you
ask for it by name. Nor is `.integrations.dev_roots`: the INTEGRATIONS
Dev tab only lists what is there until you build a row.)

The table is `exec_bearing` in `src/config/trust.zig` — whose one
other row, an installed script's directory (`<data root>/scripts/<name>/`),
is not a workspace key: `script.install` puts its claims on screen
before the first run — and a unit test
there walks every `Config` key: one whose name reads like it could run
something (`cmd`, `command`, `binary`, `args`, `env`, `roots`,
`sources`, …) fails the build until it carries a verdict — a row here,
or a reason it runs nothing.

The terminal and `--headless` (IPC hosts, `run.sh headless`) decide
trust the same way, from the same store. Only the `.test` runner trusts
its workspace outright: it made that workspace itself, in a temp
directory, and the `.mnml/init.lua` in it is the script under test.

`.ai.copilot_here` is the one row that is not an argv. It is in the
table because its effect is the same shape: a repo you cloned could
otherwise ship a `.mnml/config.zon` that opts *you* into sending that
repo's files to GitHub, without you typing anything. Stripped, it reads
as its default `false` — the safe direction — and a trusted workspace
lists it by name: *Copilot sharing ai.copilot_here — runs `send this
workspace's open files to GitHub Copilot` when you type, with Copilot
ghost text on*. A layer that only turns it **off** claims nothing.

## Launchers and integration manifests

An integration is a manifest at `<data root>/integrations/<id>.zon`
(or `<ws>/.mnml/integrations/<id>.zon` for one project); the schema is
`sdk/mnml-sdk/src/manifest.zig` and `docs/SDK.md`. A manifest without a
`binary` is a **launcher**: it ships no program, and each of its
commands carries a `run` line — an ex line, usually `:term <tool> …` —
that mnml expands and runs when the command fires:

```zig
.{
    .id = "htop",
    .label = "htop",
    .description = "Interactive process viewer",
    .chip = .{ .glyph_codepoint = "F1D00", .fallback = "H", .color = "green", .in_palette_bar = false },
    .commands = .{
        .{ .id = "htop.open", .title = "htop: open", .keys = .{"space i H"}, .run = ":term htop" },
    },
}
```

- `run` (or `ex`) may name mnml's context: `{{workspace}}`,
  `{{workspace_name}}`, `{{current_file}}` (workspace-relative),
  `{{current_file_abs}}`, `{{current_file_dir}}`, `{{cursor_line}}`,
  `{{cursor_col}}` (1-based), `{{selection}}` (its first line). An
  unknown `{{token}}` stays as written. A `term <prog>` line whose
  program is not on PATH toasts the install hint instead of opening a
  pane.
- `chip.glyph` is a Nerd Font glyph; `chip.glyph_codepoint` (`F1D00`)
  paints a codepoint verbatim when `glyph` is empty — for a mark in
  mnml's own font block; `chip.fallback` is what paints without the
  font. A mark in that block has to be baked into `MnmlSymbols.ttf`
  (`src/glyph/builder.zig`, art under `data/glyphs/`); the Bitbucket and
  Jira chips' Atlassian marks are `U+F1C15`–`U+F1C18` (pull request,
  pipeline, board, release), and the Rust-era chips an older installed
  face carries sit below them at `U+F1C03`–`U+F1C14`.
  `chip.in_palette_bar` puts the chip on the palette bar; the
  row's and the chip's right-click menus toggle it (*Hide from top bar*
  / *Show on top bar*).
- A launcher needs at least one command and every command a `run`
  line; a manifest with no `binary` and no command is refused, by
  `--install` and by mnml's scan alike.

Where one comes from: the Marketplace tab (a `github_launcher_folder`
or `local_folder` source — the four in `launchers/` of the mnml
repo are the official set), the Dev tab (an SDK checkout lists its
`launchers/` beside its `integrations/`), or `launcher.add_local` (a
prompt for a `.zon` path). Install is the file appearing in the data
root; uninstall is deleting it.

**Pinned icons.** `.ui.activity_bar_pinned_integrations = .{ "htop" }`
paints the named chips after the activity bar's sections, each the
chip's glyph in its colour; a click runs the chip's command (a pty
pane, no side panel), a right click opens the chip's menu. *Add to
activity bar* / *Remove from activity bar* on an Installed row's menu,
a chip's menu or the icon's own writes the list to the home config.

## The two strips — the activity bar is for panels, the launcher dock for launchers

The activity bar holds **panels** (every rail row is a section with a
column or a pane); the launcher dock holds **launchers** (the
integrations, the terminals, pinned commands). The split is by kind
and it is deliberate; what is editable is membership, through two
keys:

| key | what it moves |
|---|---|
| `ui.rail.hidden = .{ .todos, .findings }` | sections the activity bar does not paint. The rows after a hidden one close up; the section's command (`view.activity_todos`) and its keys still open it — hiding a row hides a row |
| `ui.dock.pins = .{ "view.activity_todos" }` | a section's own command pinned on the dock is listed there as a **pinned panel**: the section's glyph and name, the running dot while its column is open |

The menus are the surface (there is no Settings row: the settings
overlay's v1 idiom is one discrete choice per row, and a set of eleven
is not that):

| where | row | what it does |
|---|---|---|
| a rail row's right-click, after the section's verbs | *Hide from activity bar* | adds the section to `ui.rail.hidden` |
| the same menu | *Show on dock instead* | adds it to `ui.rail.hidden` **and** pins its command onto `ui.dock.pins` |
| the gear's right-click, while anything is hidden | *Show hidden sections ▸* | one child per hidden section; choosing it takes the section out of `ui.rail.hidden` |
| a pinned panel's right-click on the dock | *Move back to activity bar* | unpins it from `ui.dock.pins` and takes it out of `ui.rail.hidden` |
| the same menu | *Unpin from dock* | the plain unpin — the section stays hidden on the bar until the gear menu restores it |

The palette has the same three verbs for the keyboard, each acting on
the section the bar marks: `view.rail_hide_section`,
`view.rail_show_on_dock`, `view.rail_show_sections` (every hidden
section back; the dock keeps its pins). Both keys persist to the home
config. A script's section (`mnml.section{}`) has no config name and
gets none of the rows.

## The launcher dock

`ui.dock` is mnml's own Dock: a strip of the things you *start* —
the `+`, the installed integrations, a *New terminal* item plus one per
open terminal (a click focuses it), the installed launchers, and any
command `ui.dock.pins` names — along one edge of the editor area,
centred on it the way macOS's Dock is.

An integration is on the strip when it is **installed and not
disabled** — a manifest whose binary resolves and whose chip *Disable*
has not been pressed, and every first-party surface (Browser, Claude
Code, Codex, HTTP: the Installed tab's `Inst (4)`). Its chip's
visibility is a different question: `.enabled = false` on a
`ui.integration_icons` row, or `.in_palette_bar = false` on a manifest
chip, hides the CHIP — the tab cluster's, the palette bar's — and the
Installed tab paints `(hidden)`; the launcher stays on the dock. So
Claude Code, Codex and HTTP, whose chips ship hidden, are on the dock
out of the box.

The `+` leads the run. It is the tab bar's own `+`, and it opens the
same *Create…* menu — the one `ui.plus_menu_pinned` /
`ui.plus_menu_hidden` curate. `ui.dock.plus = false` takes it off.

It is not the **bottom panel** (`ui.bottom_panel_*`, `Ctrl-W J` / `K`),
which hosts sections and panes, and it is not the **dock widgets**, the
small panels pinned to a corner of the buffer. When the launcher dock
and the bottom panel are both at the bottom, the launcher dock is the
outermost row and the panel sits inside it, as the editor does.

| what | how |
|---|---|
| show / hide it | `view.dock_toggle` — a one-shot reveal even under `.hidden` |
| keep it up | `view.dock_pin`, or the 󰐃 chip at the strip's end. The pin lasts the session and rides in `session.zon`; it never edits the config |
| change the mode | `view.dock_cycle_mode`, `:dock always\|auto\|hidden`, or the *Launcher dock* row in Settings |
| move it | `view.dock_move`, `:dock bottom\|left\|right`, or the *Launcher dock edge* row in Settings |
| put a bottom strip above the statusline, under the `:` line, or on it | `:dock inner` / `:dock outer` / `:dock shared` (`:dock above` / `:dock below` / `:dock cmdline` say the same thing), the *Launcher dock placement* row in Settings — worded *above statusline* / *below command line* / *on command line* — or the *Place:* rows on the strip's right-click menu. `ui.dock.placement` is the file form, `.inner` the default. A side edge ignores it: it is a column, and neither of those rows is its business |
| icons, labels, or both | `:dock icons` / `:dock labels` / `:dock text`, the *Launcher dock labels* row in Settings, or the *Show:* rows on the strip's right-click menu. `ui.dock.labels` is the file form — `.icon` is the glyph alone in three cells, `.icon_label` (the default) is ` glyph label `, `.label` is the word with no glyph anywhere. It is the BOTTOM strip's question — a side dock is three cells wide and paints the glyph alone whatever the key says, `.label` included |
| centre the run, or push it to an end | `:dock center` / `:dock start` / `:dock end`, the *Launcher dock alignment* row in Settings, or the *Align:* rows on the strip's right-click menu. `ui.dock.align` is the file form (`.@"align"` in the file — `align` is a Zig keyword), and `.center` is the default. The pin chip keeps the far end whatever it says, and a run with no room to move is laid from the start rather than clipped on the left. On a side edge it centres the items down the column |
| take the `+` off | `:dock plus`, the *Launcher dock + button* row in Settings, or the *Show the + button* row on the strip's right-click menu. `ui.dock.plus` is the file form |
| put the `+` at the other end | `:dock plus left` / `:dock plus right`, the *Launcher dock + end* row in Settings, or the *+ at the … end* rows on the strip's right-click menu (worded *right* / *left* on a bottom strip, *bottom* / *top* on a side one). `ui.dock.plus_at` is the file form and `.right` — the last item, before the pin chip — is the default |
| change how a running item is marked | `:dock mark bright` / `dot` / `none`, the *Launcher dock running mark* row in Settings, or the *Running mark:* rows on the strip's menu. `ui.dock.running_mark` is the file form. `.bright` (the default) paints the running item's icon and word at full strength and leaves the idle ones dim — the tab bar's active/inactive rule, and no extra cell; `.dot` puts a small `•` in the item's own colour in the padding cell before the icon; `.none` marks nothing. The row never shuffles between them |
| reorder the strip | an item's right-click menu: *Move left* / *Move right* / *Move to start* / *Move to end* (*up* / *down* on a side strip), or `Alt+←` / `Alt+→` / `Alt+Home` / `Alt+End` while the item has the keyboard cursor (`view.focus_dock`; plain `Home` / `End` jump). `view.dock_item_move_prev` / `_next` / `_first` / `_last` are the command ids. The whole strip's ids are written to `ui.dock.order`; the `+` keeps its end and every open terminal (`term`) moves as one |
| use the keyboard | `view.focus_dock` (vim `Ctrl-W D`, or `:dock focus`): `h` / `l` walk a bottom strip, `j` / `k` a side one, Enter runs, Esc leaves |
| pin a command | a chip's right-click menu grows *Pin to dock*, and a pinned row's own menu takes it off again; `ui.dock.pins` is the file form |
| put a section on it | *Show on dock instead* on the section's rail row — its `view.activity_*` command lands in `ui.dock.pins` and the item wears the section's glyph and name; *Move back to activity bar* on the item undoes it (see "The two strips" above) |
| find it when it is hidden | the `⋯` grip at the middle of its band (`ui.edge_grips`) — a click there reveals and pins in one gesture |

**The outer-band rule.** A dock on a side edge always owns the
outermost column of the frame, and an auto-hiding side column's reveal
edge moves one cell inwards to make room — so the outer cell summons
the dock and the next cell in summons the column, and neither surface
can be left unsummonable. The top row is never the dock's: that is the
menu bar's, which is why there is no `.top` edge.

An `always` dock is carved out of the frame like any other chrome. An
`auto_hide` one is **paint only**: it draws over the editor and nothing
is re-laid-out, so no pane moves and no terminal is resized when the
pointer brushes an edge.

**The bottom dock's band is the row its strip paints, and
`ui.dock.placement` picks that row.** The band — the row the dwell
watches, and the cells the `⋯` grip marks — is always the row the
strip comes up on, so hovering the grip, clicking it and
`view.focus_dock` all bring the items up exactly where the grip was,
never apart from it. The two places a bottom strip lives are *above the
statusline* (`.inner`) and *on the command line* (`.shared`); `.outer`
puts it under the `:` line.

Under `.inner`, the default, it is the **editor area's last row**, and
so are the band and the grip: `always` carves it off the editor,
`auto_hide` paints it over that same row, and the statusline and the
`:` line stay exactly where they are with no dock at all. The `:`
line's row is never the strip's or the grip's, so the two coexist — a
line can be open while the strip is out, and the grip stays up while
you type. That row is also the panes' last, so the grip takes the blank
cells nearest its middle rather than paint over text there, and steps
aside when the row has none — the whole row still brings the strip up.

Under `.outer` the strip, its band and its grip are the **screen's
last row**, under the `:` line: everything else moves up one, and a
revealed strip paints over that row, covering the toast echo and the `⟳ … running…` chip while
it is up. There the `:` line owns the row outright: while one is open
the band is not watched at all, so the strip neither reveals nor
stays, and its grip goes with it. Closing the line asks for a fresh
`reveal_ms` rather than popping the strip up the same frame.

Under `.shared` the strip is **on the `:` line's row** — the free part
of it, right of the typed command, which rarely reaches the middle of
the row. It carves no row of its own and has nothing to summon, so
`mode = .auto_hide` reads as `.always` there, no `⋯` grip is drawn and
no dwell band is watched (`.hidden` still hides it). With no line open
the run and the pin chip sit on the whole row per `ui.dock.align`,
labels, `+` and running mark as on any bottom strip; the toast echo and
the `⟳ … running…` chip keep to the cells left of the run. An open
line never moves the items: they stay exactly where they were while you
type. **It steps aside rather than move:** once the line's paint — the
`:`, the typed text and the caret cell — plus one cell of air would
reach the first item, the strip (run and pin chip) is not painted at
all for that keystroke and registers no hit, and it comes back the
moment the line closes or shortens. Under `.@"align" = .start` the run
begins at the row's second cell, so it steps aside the moment any line
opens — pick `.center` or `.end` to keep it up while you type.

## Split zoom

`view.toggle_zoom` ("Zoom the split") — vim `Ctrl-W z` or which-key
`space s z`, standard `Ctrl+K Ctrl+M` (VS Code's Toggle Maximize
Editor Group), the tab strip's maximize button (with `ui.maximize_click =
.zoom_pane`, the default) — gives the focused split the whole editor
area. The other splits of the tab page are hidden, not closed: the tab
strip shows only the zoomed split's tabs, the statusline carries a
` zoom ` chip in the mode chip's colour, and the same command (or a
click on the chip) puts the layout back exactly — the ratios, the focus
and the other pages are never touched. While zoomed the zoom follows
the focus, so a focus step shows the split it lands in rather than
sending keys to one nobody can see.

Anything that changes the split tree un-zooms first: a split, closing
the zoomed pane or a split, a move (`Ctrl-W H/J/K/L`), a rotate, the
split leaving for a page of its own (`Ctrl-W T`). A tab switch inside
the zoomed split, a resize or a new tab in it keeps the zoom. The zoom
is per tab page — a new page starts un-zoomed, and switching back to a
zoomed page lands on its zoomed split — and it is written to
`.mnml/session.zon` per page, so a restart comes back zoomed. Full
screen (`view.fullscreen`) composes with it: full screen hides the
chrome, the zoom hides the sibling splits, and with both on one pane has
the window.

## Named layouts

A named layout is one tab page written down under a name and put back
on demand. `:layout save <name>` (or `layout.save`, which prompts) writes
the current page to `.mnml/layouts/<name>.zon`: its split tree with the
ratios, which pane is focused, its zoom, and for every pane its kind and
what reopens it — a file's path (editor, markdown preview, image), a
terminal's cwd and command line, an AI session's CLI and id (it comes
back resumed), an `.http` file and its `### block`, a browser pane's
URL, a git status / graph / worktree diff by repo, a Search by its query
and options. It is the same shape `.mnml/session.zon` uses for a page,
plus the request and browser panes the session leaves out. Paths under
the workspace are written relative to it, so a layout can be committed
and used from another clone. Scratch buffers and list panes are left
out; a page with nothing else is refused.

| | |
|---|---|
| `:layout save <name>` · `layout.save` | write this tab page under `<name>` (letters, digits, `-` `_` `.`, not first; 64 at most); over an existing name the confirm box asks first (Cancel selected) — `:layout save! <name>` replaces without asking |
| `:layout load <name>` | replace this tab page with the layout |
| `:layout load! <name>` | the same without the unsaved-changes question |
| `layout.pick` · `layout.load` | a picker over the saved layouts, each with its pane / split count and what it holds; the pick loads, and Shift+Delete deletes the row after asking, then the picker comes back |
| `:layout delete <name>` · `layout.delete` | delete the file, after the confirm box asks (`layout.delete` picks the name first); `:layout delete! <name>` does not ask |
| `:layout list` (or a bare `:layout`) | toast the saved names |

The View menu's *Layouts* submenu and which-key `space W` (`s` save,
`l` pick, `d` delete) carry the same commands.

Loading replaces the current tab page. Its panes that no other page
shows close; when any of them has unsaved changes the confirm box asks
first (Cancel holds the focus), and on Load those stay open as
background tabs of the new page — nothing is lost, and `tab.reopen`
brings the replaced page's files back. A pane whose subject went away
(a deleted file, a directory that is no longer a repo, no Chrome for a
browser pane) is skipped and counted in the toast. A terminal with a
command line comes back running it — unlike a session restore, a load
is the user asking for it.

**Trust.** A layout file is workspace content, so its terminal commands
and AI sessions are exec-bearing: in an untrusted workspace they are
refused with a toast (the rest of the layout opens), as `.startup.layout`'s
pty entries are (Workspace trust above). The exception is a file this
mnml wrote: `save` records a fingerprint of the file's command lines and
their cwds in `<data root>/written_layouts.zon`, and a file whose commands
still match it loads them anywhere — edit a command by hand and it is
someone else's again. A plain shell (no command) runs nothing the file
chose and is never refused.

## Session worktrees

A Claude / Codex session can start in a git worktree of its own —
opt-in, off by default (`src/app/session_worktree.zig`). Per launch:
*New session in a worktree…* on the AI chip's right-click, the `+`
menus and `+ New session`, or `ai.new_session_worktree`. Per profile:
`.ai.launch_profiles[].worktree = true` sends every session of that
profile this way. Either prompts for a branch name (seeded
`session-<n>`, or `<profile>-<n>`), runs `git worktree add -b <name>
<root>/<name> HEAD` in the workspace's repository and opens the session
in the tree with `MNML_WORKSPACE` pointing at it.

`<root>` is `<repo>-worktrees` beside the repository (this project's
own convention: `mnml-zig-worktrees/<track>`) unless
`.ai.default_worktree_root` names another — `~` expands, a relative
path sits under the repository, an absolute one is taken as is. The
name is validated as a branch name; an existing directory or branch is
refused with the reason.

The SESSIONS row tags the session `⑂ <name>`; its menu offers *Open
worktree in tree*, *Merge into <branch>…* (`--no-ff`, refused while
the main tree has uncommitted changes) and *Remove worktree…*
(`worktree remove` + `branch -d`; an unmerged branch asks once more
with Force). The git panel's WORKTREES row paints the session's accent
and carries the same two verbs. The trees mnml made are remembered in
`.mnml/session.zon` (`sessions_worktrees`). `.worktree` on a profile
is stripped with the profile from an untrusted workspace config
(Workspace trust above).

## Walking the splits

`view.focus_next_split` / `view.focus_prev_split` step through the
page's splits in layout order, with wrap — the way Terminal.app's
`Shift+Cmd+→` / `Shift+Cmd+←` step through its tabs
(`src/app/cmd_view.zig`). With the sidebar open it sits before the
first split: previous from the first split lands on it, previous from
it on the last split, and next runs the same ring the other way.

| profile | next | previous |
|---|---|---|
| vim | `Ctrl-W w` | `Ctrl-W W` (Neovim's own pair; the handler's `Ctrl-W` prefix) |
| standard | `ctrl+alt+shift+right` | `ctrl+alt+shift+left` |

The standard pair has three modifiers because the two-modifier arrows
are taken: `ctrl+shift+→/←` and `alt+shift+→/←` extend a selection by a
word, and `ctrl+alt+→/←` are `buffer.next` / `buffer.prev`. Either
command rebinds under `.keys.standard` / `.keys.vim` like any other.

With Claude / Codex sessions laid out as tabs (`.ui.ai_layout_mode =
.tabs`) they share one leaf, and the split walk would have nowhere to
go: from a session pane on a one-leaf page the pair steps through that
leaf's session tabs instead, in strip order with wrap, skipping its
other tabs — what a SESSIONS card's Enter does. Anywhere else, and with
fewer than two sessions there, it is the split walk.

**`Shift+Cmd+←/→` itself.** Terminal.app keeps Cmd for itself — those
two are its own previous / next tab — and sends no Cmd chord to a
program at all, so a TUI cannot bind them there. ghostty can hand them
on: these two lines in its config send what `ctrl+alt+shift+→ / ←`
sends (`CSI 1;8C` / `CSI 1;8D`; 8 is 1 + shift 1 + alt 2 + ctrl 4,
the same bytes with or without the kitty keyboard protocol, which keeps
the legacy form for the arrows), so the standard profile's walk runs
on `Shift+Cmd+→ / ←`. ghostty 1.3 binds neither by default
(`ghostty +list-keybinds --default`).

```
keybind = super+shift+arrow_right=text:\x1b[1;8C
keybind = super+shift+arrow_left=text:\x1b[1;8D
```

In the vim profile, bind the same chords to the commands under
`.keys.vim` first (`.@"ctrl+alt+shift+right" =
"view.focus_next_split"`, `.@"ctrl+alt+shift+left" =
"view.focus_prev_split"`). `src/tui/loop.zig`'s test reads the two
sequences through the terminal parser into the standard profile's
chords.

## Terminal panes

A terminal pane's child is told it runs inside mnml. Every child gets
`MNML_PANE=1` — an integration opened with `:term <binary>` keys its
chrome on it and leaves the outer border to the pane — and
`MNML_WORKSPACE`, the workspace it belongs to (a session worktree's
pane gets the worktree). A shell also gets the prompt's environment:
the theme's colours as `MNML_PROMPT_BG`, `_FG`, `_ACCENT`, `_BLUE`,
`_GREEN`, `_RED`, `_YELLOW` and `_GREY` (`#rrggbb`), `MNML_CONTEXT=mnml`,
and `MNML_PROMPT_SCRIPT` — the path of the mnml prompt
(`themes/mnml-prompt.sh`, written as `prompt.sh` into the data root and
rewritten when a new build carries a different one). Turn it on with
one line in `~/.zshrc` or `~/.bashrc`; outside mnml it does nothing:

```sh
[ -n "$MNML_PROMPT_SCRIPT" ] && . "$MNML_PROMPT_SCRIPT"
```

The prompt shows the directory, the git branch (`±` when dirty), a
failed command's status, and the time and context on the right
(`MNML_PROMPT_ASCII=1` draws it without Nerd Font glyphs). It also
reports the shell's directory (OSC 7) and its prompt marks (OSC 133).

## Bookmarks

`bookmarks.open` is a picker over your web bookmarks, grouped by
environment — `dev  ·  Admin console`, the URL as the row's detail; Enter
hands the URL to the browser (`.ui.external_browser`, or the OS
default). The mechanism is mnml's; the URLs are yours, in two files
that both load and add up — a repo's file extends your own set rather
than hiding it:

1. `<data root>/bookmarks.zon`
2. `<workspace>/.mnml/bookmarks.zon`

```zig
.{
    .sites = .{
        // One destination in several environments: dev / staging /
        // prod as fields, any other name under .envs.
        .{
            .name = "Admin console",
            .dev = "https://admin.dev.example.net",
            .staging = "https://admin.staging.example.net",
            .prod = "https://admin.example.com",
            .envs = .{ .{ .env = "uat", .url = "https://admin.uat.example.net" } },
        },
    },
    .bookmarks = .{
        // A one-off; .env defaults to "other".
        .{ .label = "Metabase", .url = "https://metabase.example.net", .env = "prod" },
    },
}
```

A site expands to one row per environment it names, in the order dev,
staging, prod, then `.envs` as written; an empty URL is skipped. A
malformed file is skipped rather than fatal. With neither file the
command toasts the path to write.

## Where the home file lives

1. `$MNML_DATA_ROOT/config.zon` when the variable is set
2. `<binary dir>/mnml-data/config.zon` when that directory exists and
   contains `.opted-in` (portable mode)
3. `$XDG_CONFIG_HOME/mnml/config.zon` when the variable is set
4. `$HOME/.config/mnml/config.zon`

That ladder answers for the `stable` profile; the `dev` profile is the
same answer with `-dev` on the end (below).

## Profiles

One machine runs two mnmls: the installed `mnml` you live in and the
build you are working on. A **profile** decides which state each one
touches. There are two, and `stable` is the default — you ask for the
other:

```sh
MNML_PROFILE=dev mnml           # or
mnml --profile dev              # the flag writes the variable for the process
./run.sh                        # the dev workflow: dev unless you say otherwise
```

|                   | `stable`                   | `dev`                        |
| ----------------- | -------------------------- | ---------------------------- |
| data root         | the ladder above           | the same, `-dev` appended     |
| `config.zon`      | `~/.config/mnml`           | `~/.config/mnml-dev`          |
| session file      | `<ws>/.mnml/session.zon`   | `<ws>/.mnml/session-dev.zon`  |
| IPC mailbox       | `<ws>/.mnml/ipc`\*         | `<ws>/.mnml/ipc-zig`          |
| running marker    | `mnml-running-$USER…`\*    | `mnml-zig-running-$USER…`     |
| statusline        | —                          | a `dev` chip beside the mode  |
| window title      | `mnml — work`              | `mnml [dev] — work`           |

\* the build names these: `zig build release` and `run.sh install` pass
`-Dinstall-names`, which spells the stable profile the way a shipped
mnml does. This repo's own builds keep `ipc-zig` /
`mnml-zig-running-…` for BOTH profiles, so nothing in the tree moves;
the dev profile's names are its own either way. `MNML_IPC_DIR` still
overrides the mailbox outright.

The suffix applies at every rung, including an explicit
`$MNML_DATA_ROOT` — `MNML_DATA_ROOT=/tmp/x MNML_PROFILE=dev` is
`/tmp/x-dev`. A test with a private root stays private.

`mnml profile` prints all five for the profile in play.

### Seeding

The first dev launch finds an empty dev root and copies your setup out
of the stable one — `config.zon`, `integration-settings.zon`,
`integrations/` (manifests and their configs), `launchers/`, `themes/`
— then toasts `dev profile seeded from ~/.config/mnml`. It never
copies a credential (any name containing `token`, `secret`,
`credential`, `password`, `cookie`, a `.pem` / `.key`), a cache, a
backup, the trash, a request log or a session. It is one-shot: a dev
root with any state is left alone.

```sh
mnml profile seed --from stable --force   # copy again, filling in what is missing
```

`--force` never overwrites a file the dev root already has — it is a
second pass, not a rollback.

Every dev launch also links the integrations built beside the running
binary into `<dev root>/bin/`, which is where mnml looks for an
integration's binary first. So the dev profile drives the integrations
you just built and the stable profile drives the ones you installed.

### What integrations see

An integration inherits `MNML_DATA_ROOT` from the host, already
resolved for the profile, so its config, cache, sync marks, etags and
request log land under the dev root without the integration knowing
profiles exist.

The one thing meant NOT to be per-profile is the cross-process
rate-limit bucket. Its file is the first of these that applies
(`sdk/mnml-sdk/src/ratelimit.zig`):

1. `<SERVICE>_RATELIMIT_STATE` (`JIRA_RATELIMIT_STATE`, …) names the
   file outright
2. `$MNML_SHARED_STATE_DIR/<service>-ratelimit.json`
3. `<MNML_DATA_ROOT>/ratelimit/<service>.json`
4. `~/.config/mnml/ratelimit/<service>.json`

It should be one budget per machine: two profiles each spending a full
budget against the same API is the bug, not the feature. With
`MNML_SHARED_STATE_DIR` unset the bucket falls back under the data
root, which is the profile's — set the variable to have every profile,
and any other tool on the machine that agrees to the file format,
share one budget.

## Sandbox

`mnml --sandbox` runs mnml against a throwaway home — what a brand-new
user sees, with nothing you do reaching your real config, state or
credentials. POSIX only (it re-executes itself; Windows refuses the
flag with a message).

```sh
mnml --sandbox                 # the sandbox's own empty workspace
mnml --sandbox ~/some/proj     # your workspace, with a throwaway home
mnml --sandbox-keep            # the same, and the directory survives the exit
```

Before any config is read, mnml makes `mnml-sandbox-XXXXXXXX` under the
temp root (`$TMPDIR`, else `/tmp`) and re-executes itself — the same
pid — with these set on top of the environment it was started with
(everything else passes through):

| variable | value |
| --- | --- |
| `HOME` | `<root>` |
| `XDG_CONFIG_HOME` | `<root>/xdg` |
| `MNML_DATA_ROOT` | `<root>/xdg/mnml` (the dev profile adds `-dev`) |
| `MNML_SANDBOX` | `<root>` — what paints the chip |
| `MNML_SANDBOX_PID` | the pid, which is the process that removes `<root>` |

A shell pane, an integration and any `mnml` subcommand run from inside
inherit all of it. Without a workspace argument the sandbox opens
`<root>/workspace`, not the directory you ran it from.

- **You can see it.** A yellow ` sandbox ` chip beside the mode, `mnml
  [sandbox] — ws` as the window title, and a first-frame toast naming
  the directory. If `MNML_SANDBOX` is set but `HOME` is not a throwaway
  directory, or the data root is outside it, the chip turns red and
  reads ` sandbox? `, with a warning that stays until dismissed.
- **Your workspace is left alone.** Its session is neither restored
  nor autosaved (`session.save` by hand still writes), and the
  running-instance marker is not written, so `run.sh restart` / `stop`
  still mean your real instance. The workspace's IPC mailbox
  (`.mnml/ipc…`) is still used.
- **An already-throwaway home is used as it is.** When `HOME` is
  already under the temp root (or named `mnml-sandbox-*`) and neither
  `XDG_CONFIG_HOME` nor `MNML_DATA_ROOT` points outside it, a bare
  `--sandbox` does not re-execute; it only sets `MNML_SANDBOX`.
- **On exit** the process that made the directory removes it; a nested
  mnml in a shell pane never does, and a directory mnml did not make is
  never touched. `--sandbox-keep` keeps it and prints its path. SIGTERM,
  SIGHUP and SIGINT (a closed window, `kill`, a stopped container) end the
  run the way a quit does — the directory is removed and the exit status
  is 128 + the signal, 143 for SIGTERM; a second signal exits at once. A
  crash or `kill -9` leaves it for the OS's temp cleanup.
- Only the app takes the flag — the terminal UI and `--headless`. A
  one-shot subcommand (`mnml run FILE`, `mnml test`, …) ignores it.

### `--demo`

`mnml --demo` is `--sandbox` with something in it: a small Zig project
with history, offline Jira and Bitbucket, and a stand-in Claude Code. It
needs no network and no account, and it is the same fixture the site's
recordings are made from. It opens its own workspace, so it takes no
workspace argument, and it will not start inside a sandbox.

On top of the sandbox's variables the re-exec sets these, and drops
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `BITBUCKET_ACCESS_TOKEN`,
`BITBUCKET_APP_PASSWORD`, `BITBUCKET_PERSONAL_TOKEN`, `MNML_JIRA_CONFIG`,
`MNML_BITBUCKET_CONFIG`, `MNML_MARKETPLACE_LOCAL` and `MNML_ENV`:

| variable | value |
| --- | --- |
| `MNML_DEMO` | `<root>/tour` — the workspace; with `MNML_SANDBOX`, what turns the chip into ` demo ` |
| `PATH` | `<root>/demo/bin` first — the stand-in `claude` and `codex` |
| `JIRA_BASE_URL` / `BITBUCKET_BASE_URL` | `@<root>/demo/jira.url` / `@<root>/demo/bb.url`, the fakes' URL files |
| `JIRA_API_TOKEN` / `BITBUCKET_API_TOKEN` | the fakes' own tokens |
| `BITBUCKET_ACCESS_TOKEN` | the Bitbucket fake's token again — the name the Jira pane's linked pull requests read (your real one is dropped first) |
| `JIRA_RATELIMIT_STATE` / `BITBUCKET_RATELIMIT_STATE` | files under `<root>/demo/` |
| `MNML_NO_UPDATE_CHECK` | `1` |
| `MNML_OPEN_URL` | `none` — a link opens nothing |
| `MNML_AGENTS_PGID` | a process group nobody is in: the agents scan sees the demo's sessions, not the machine's |
| `GIT_CEILING_DIRECTORIES` | `<root>` |
| `MNML_DEMO_HOST_DATA_ROOT` | the data root this run would have used without the sandbox — where the Marketplace installed the integrations |

Then, before the first frame:

- **The workspace** `<root>/tour` is written from files the binary
  carries (`data/demo/`), and `git` makes its history: five commits and
  a merge, a commit of request files by a second author, an open
  `feature/cli-args` branch, then a modified file and an untracked one.
  Without `git` the files are there and the history is not.
- **The home** gets a `config.zon` that skips the first-launch setup,
  an `init.lua` that opens `src/util.zig` with a Claude Code session on
  its right and a shell under that (edit it to change the first screen),
  three earlier agent transcripts for the sessions views, and the Jira
  and Bitbucket configs.
- **The integrations** `mnml-jira` and `mnml-bitbucket` are looked
  for, in order, beside the binary (a source build's `zig-out/bin`),
  then where the Marketplace put them in `MNML_DEMO_HOST_DATA_ROOT` —
  its link `bin/<name>`, then the file it installed,
  `integrations/<id>/bin/<name>`. Each is linked into the sandbox's
  data root and its `--install` run.
- **The fakes** `mnml-fake-jira` and `mnml-fake-bitbucket` beside the
  binary start on ports the OS picks, each in a process group of its
  own and told to exit with mnml; their URLs go into the workspace's
  `.mnml/env/dev.env`, which `requests/*.http` use. A release carries
  them there: the macOS and Linux archives, the `.deb` / `.rpm`
  (`/usr/bin`), the Homebrew formula, the installer script and
  `run.sh install` all put them beside `mnml`. The Windows zip and MSI
  do not, since Windows has no `--demo`.

Whatever is not found is skipped and named in the first frame's toast,
with the directories it was looked for in (`--headless` prints the same
note to stderr). A ` demo ` chip sits where the sandbox chip does. On
exit — a quit, or SIGTERM / SIGHUP / SIGINT — the fakes are stopped,
then the whole sandbox is removed.

## Writes

Settings screens and toggles write back with `persistScalar`: the file is
parsed, the one value's bytes are replaced in place, and comments and
order survive. A missing key is added at its section's indent; a missing
section is appended. An unchanged value is not written. Before every
write the previous file is copied to
`backups/config.<YYYY-MM-DD-HHMMSS>-<NNNN>.zon` next to it — the stamp in
UTC, the counter so that several writes in one second (a Settings row
held under `→`) each keep their own copy — keeping the newest 50.

### The settings overlay

`view.settings`, `:settings`, or `Ctrl+,` opens the sectioned list —
`── UI ──`, `── Editor ──`, `── AI ──`, `── Integrations ──`, `── Reset ──`
— one row per discrete-choice key, and a `‹ [32] ›` row per number:

```
 ▸ Line numbers:      off / [on]
   TODOS sort:        [newest] / oldest / name / name_desc
   Theme:             [onedark] ‹ 62/94 ›
   Input style:       vim / [standard]  *
```

`▸` marks focus, `[brackets]` the current choice, a trailing `*` a value
that is not the shipped default. `←→` adjust, `↑↓` move, Tab /
Shift-Tab step a section, `Ctrl+R` resets the focused row, `Enter` (or
a click outside) keeps and closes, `Esc` cancels — a live filter first.

The two profiles differ in one place. **Vim** keeps its letters: `h l`
adjust, `j k` move, `[` `]` section, `g` `G` the ends, `r` reset the
row, `R` reset all, `q` save. **Standard** has none of them and is
type-to-filter: any printable key opens the search pill and goes into
the query, so typing the name of the row you came for finds it instead
of running five commands (`/` and space are the exceptions — the
family's filter chord and the row's toggle). The footer advertises
whichever set is live — and while the search pill has the keys it
advertises the pill's own (`←→` move the caret, Enter hands the list
back, Esc clears the query), because none of `adjust`, `move` or `save`
is true there. Reset-all is the `Reset all to defaults` row
under `── Reset ──` there, and in both profiles it asks before it
throws anything away.

**The file follows the row.** Adjusting a row applies at once and writes
the value to the row's file, so what you see is what is on disk. Which
file depends on the row: a per-project view setting (line numbers, wrap,
format on save, …) goes to the workspace's `.mnml/config.zon`; a
preference (theme, input style, ASCII icons, AI, Sonos, …) goes to the
home config. The title names the focused row's file — under `~` for a home-scope
row, and cut from the LEFT when it is longer than the box, so the file
name is the half that survives. A row whose key a layer loaded after
its file also sets — a `--config` file, or the workspace's
`.mnml/config.zon` over a home row — says so there (`→
~/.config/mnml/config.zon · overridden by .mnml/config.zon`), and
changing it still writes the row's file and warns that the other
file's value wins at the next launch. `Esc` puts back
the config, the input style, the theme, and the exact bytes of every
file written since the overlay opened — a file that did not exist is
removed again.

Rows are discrete choices (bools, enums, the theme) and numbers
(`tree_width` — whose 0 reads `auto`, one step below 10 —, `right_panel_width`, `bottom_panel_height`,
`sidebar_auto_below`, `wheel_lines`, `md_image_rows`,
`hover_help_height`, `hover_help_grace_ms`, `color_column`, `focus_follows_mouse_delay_ms`,
`tab_width`, `text_width`, `chord_timeout_ms`, `report`, `suggest_idle_ms`,
`suggest_timeout_ms` — 117 rows in all, plus the Reset row); text
(`projects_dir`, the labels) stays a file edit.

### Themes

`.ui.theme` names one of the bundled themes — every `themes/*.zon`,
the 94 NvChad palettes, matched case-insensitively (`"OneDark"` is
`onedark`). `theme.pick` / `:theme` opens a picker that previews as you
move and writes the pick to the home config on Enter; `:theme <name>`
and `:set theme=<name>` pick directly. `theme.toggle` flips to
`.ui.theme_toggle`, or to the first bundled theme of the other kind
when it is unset; `theme.reset` returns to `.ui.theme`;
`theme.auto_system` follows the OS appearance (checked every 15 s) and
`theme.auto_system_off` freezes it. `.ui.theme_auto_system = true`
starts that follow at launch. Only a pick writes the file.

A theme file is the palette as NvChad ships it, `0xrrggbb` values:

```zon
.{
    .name = "onedark",
    .kind = .dark, // .dark | .light
    .base_30 = .{ .white = 0xabb2bf, .black = 0x1e222a, /* … */ },
    .base_16 = .{ .base00 = 0x1e222a, /* … base0F */ },
}
```

Every UI role derives from it at build time with the same fallback
chains 0.2.x used (`one_bg2 → one_bg → black`, `light_grey → grey_fg2
→ grey_fg → grey → white`, `cyan → blue`, …); a missing `base_16` slot
takes onedark's. A malformed theme fails the build, not the launch.

### First launch

`.ui.first_launch_complete` gates the setup wizard: while it is false
the terminal loop opens it on start (after the trust dialog, if any).
Enter writes only what was touched — `editor.input_style`,
`ui.ascii_icons`, `ai.routing.<product>.backend`,
`ai.inline_suggestions` — plus `first_launch_complete = true`, to the
home config. Esc writes nothing and asks again next launch;
`first_launch.show` reopens it any time.

Space is the install key and writes no config. On the Nerd Font section
with "boxes" answered it runs this OS's install of Symbols Nerd Font
Mono (`brew install --cask font-symbols-only-nerd-font`; on Linux the
NerdFontsSymbolsOnly zip into `~/.local/share/fonts/nerd-symbols` and
`fc-cache -f`; on Windows PowerShell into the per-user font directory
with an HKCU registration, no admin); on Claude Code + Codex it runs
the vendors' installers for whichever CLI is missing; on the `code`
shim (macOS) it links the VS Code bundle's `code` into `/usr/local/bin`
under sudo. Each runs in an `install: …` pane; the wizard closes for
the pane, keeps its answers, and comes back when the pane ends — with
the rows re-detected, and, for the font, a toast saying how to point
your terminal at it (keyed off `TERM_PROGRAM`) that appears only when
the pane exited 0.

Section 8, Integrations, offers the first-party integrations — Jira and
Bitbucket — as checkboxes, none checked, each with the version on offer
and whether it is installed. `y` / `→` check the focused row, `Tab`
moves to the next, a click toggles one. Space installs the checked ones
on the spot, and Enter installs them on the way out: both go through
the marketplace's own install (the release index for a released mnml,
downloaded and sha256-checked; the checkout's build in a dev one), one
after another, and the rows follow along (`queued`, `installing…`,
`installed`). Nothing checked installs nothing, and Esc installs
nothing whatever is checked. The rows come from the Marketplace tab's
listing, which opening the wizard fetches.

Under the checkboxes, the Private integrations row: Space (or a click)
on it opens the Marketplace's add-a-source prompt — the same one as
`marketplace.add_source` and the tab's `+ source` chip — for a folder,
`owner/repo[:apps_dir]` or a GitHub repo URL. Enter adds the source to
`marketplace.sources` in the home config.zon and the setup comes back
with its id and how many integrations it found; Esc, or an empty line,
changes nothing. The row is optional: skipping it adds nothing.

## Coming from 0.2.x (TOML)

mnml 0.3 and later reads no TOML — not `config.toml`, not the theme
files, not `trusted_workspaces.toml`. The last release of mnml 0.2.x
(Rust), 0.2.22, carries the converter, since it is the one that still
has the typed TOML config:

```
mnml export-config-zon                # writes ~/.config/mnml/config.zon
mnml export-config-zon --out PATH     # or wherever you like
```

Run it once per config file you keep: the home file, and each
workspace's `.mnml/config.toml` (from inside that workspace, with
`--out .mnml/config.zon`). The output carries a `//` comment per key
from the schema's own doc table, and every key it could not place lands
verbatim in a trailing `// unmigrated:` block so nothing is lost
silently. The TOML file is left where it was; mnml 0.3+ ignores it.

What mnml 0.3+ says about a `config.toml` it finds where a `config.zon`
should be (and only then — a `.toml` beside a `.zon` is nothing):

- **Once per data root, a toast** naming the file and the converter
  line above. `ui.config_toml_notice_shown = true` is written to the
  home config the first time; after that the same line is in
  `:messages` on every launch and nowhere else.
- **For a workspace file, `RESTRICTED` on the statusline** for as long
  as the file stands with no `.zon` beside it — the workspace's whole
  config is not in effect, which is what the chip means. Its hover says
  so and a click (`workspace.review_trust`) repeats the converter line.
  Converting the file (the `.zon` appears) clears the chip on the next
  launch or `workspace.review_trust`.

The 0.2 integration manifests (`<data root>/integrations/*.toml`,
`<workspace>/.mnml/integrations/*.toml`) are the same decision: never
read, never deleted or renamed. The INTEGRATIONS section says once per
launch, and on the Installed tab's empty state, that `N integrations
from mnml 0.2 are not loaded — 0.3 integrations install from the
Marketplace`; *Don't show again* on that toast's right-click menu (or
`integrations.dismiss_toml_notice`) writes
`ui.integrations_toml_notice_shown = true`.

What changes shape on the way:

| 0.2.x TOML | ZON |
|---|---|
| `[abbr]` | `.abbr` |
| `[startup] tasks`, `[[startup.layout]]`, `default_workspace` | `.startup = .{ .tasks, .layout, .default_workspace }` |
| `[[marketplace.source]] type = "crates_keyword"` | `.marketplace.sources = .{ .{ .crates_keyword = .{ … } } }` (a tagged union) |
| `[[ui.integration_icon]]` | `.ui.integration_icons = .{ … }` |
| `md_preview_engine = "custom:cmd"` | `.md_preview_engine = .{ .custom = "cmd" }` |
| `input_style = "vim"` and every other closed-set string | an enum literal: `.input_style = .vim` |
| a formatter / linter `cmd = "rustfmt"` string | a list: `.cmd = .{ "rustfmt" }` |
| `claude_show_all_accounts = "true"` (bool-or-string) | a bool |
| `[keys.global] "ctrl+p" = "picker.files"` | `.keys = .{ .global = .{ .@"ctrl+p" = "picker.files" } }` |
| legacy glyph names, `DEAD_INTEGRATION_IDS` | remapped / dropped |

What does not need migrating:

- **Themes.** All 94 bundled themes ship as `themes/*.zon`; a custom
  `.toml` in your data root is not read. Convert it with the same shape
  as above (`tools/theme_toml2zon.zig` in the repo is the script that
  produced the bundled files) and drop it beside them.
- **Trust.** `trusted_workspaces.toml` is not read; each workspace with
  exec-bearing settings asks once more and is remembered in
  `trusted_workspaces.zon`.
- **`session.json`, `.rqst/history.jsonl`.** JSON, read best-effort with
  unknown fields ignored and rewritten in the 0.3 shape.

Nothing is automatic: a 0.3.0 launch with no `config.zon` starts on the
shipped defaults and the first-launch wizard, and says so in a toast if
a `config.toml` is sitting next to where the ZON file would be.
