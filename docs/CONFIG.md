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
        .tab_width = 4,
        .autosave_secs = 0, // 0 = off
        .trim_trailing_ws_on_save = false,
        .breadcrumb = true,
        .auto_pair = true,
        .auto_indent = true,
        .format_on_save = false,
        .will_save_wait_until = false,
        .format_on_type = false,
        .autosave_on_focus_loss = false,
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
        .text_width = 80,
        .ensure_trailing_newline = true,
        .chord_timeout_ms = 500, // vim's timeoutlen; clamped to 100..5000
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
        .theme_toggle = null, // a second theme for ui.toggle_theme
        .theme_auto_system = false,
        .ascii_icons = false,
        .tree_width = 30, // clamped to 10..80
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
        .auto_hide_narrow_width = 0, // a WIDTH rule: below this many columns both side columns are dropped for the frame (0 = never; a non-zero value is clamped to 40..300). Nothing is mutated — widening brings back what was open
        .sidebar = .always, // .always (docked) | .auto (hidden; the pointer at the column's screen edge reveals it as an overlay OVER the editor — no relayout, no pty resize) | .hidden (never on hover; a keyboard command still gives a one-shot overlay)
        .sidebar_reveal_ms = 250, // how long the pointer rests in the edge zone before the overlay slides in (0..5000)
        .sidebar_hide_ms = 400, // how long after the pointer leaves the overlay before it hides (0..5000)
        .dock = .{ // the LAUNCHER dock (`app/launcher_dock.zig`) — integrations, terminals, launchers and pinned commands along one edge of the editor area. Not the bottom panel (`ui.bottom_panel_*`) and not the dock widgets
            .mode = .auto_hide, // .always (the strip is carved out of the frame) | .auto_hide (nothing until the pointer rests at the edge, then it is painted OVER the editor) | .hidden (never on hover; `view.dock_toggle` still gives a one-shot reveal)
            .edge = .bottom, // .bottom (one row, icon + label) | .left | .right (three cells, icon only — the label moves into the tooltip). There is no .top: that row is the menu bar's
            .placement = .inner, // where a BOTTOM strip goes: .inner (the default — the editor area's last row, ABOVE the statusline, so neither it nor the `:` line moves) | .outer (the SCREEN's last row, UNDER the `:` line; everything else moves up one and a revealed strip covers that row). A side edge ignores it
            .labels = .icon_label, // how much of an item a BOTTOM strip paints: .icon_label (` glyph label `, today's row) | .icon (the glyph alone in the side form's three cells — padding, glyph, padding — with the name in the tooltip). A side edge is icon-only by geometry and ignores this
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
        .auto_equalize_splits = false,
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
        .sessions_sort = .auto, // .auto | .manual
        .session_bell = false, // ring the terminal bell when a session starts waiting for input (SESSIONS toasts once per edge either way)
        .session_ended_grace_min = 10, // minutes an ended session stays listed in SESSIONS before the history chip hides it (0 = at once)
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
        .ticket_prefixes = .{}, // e.g. .{ "TE", "OPS" }
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
        // The coverage chip reads `.tattle-claude-artifacts` under
        // `MNML_ARTIFACTS_HOME` when that is set, else your home directory.
        .coverage_chip_mode = .feature, // .both | .feature | .code | .ticker
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
        .hover_help_height = 8, // clamped to 3..20
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
        .tab_bar_ai_icon = .claude_code,
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
        // `app.quit` (Ctrl+Q, the menu bar's Quit, the palette) always stops to ask — Quit / Cancel
        // with nothing unsaved, Save all / Quit anyway / Cancel with something, Cancel focused either
        // way. `false` asks only when something is unsaved. `:q!` / `:qa!` and the IPC `quit` /
        // `restart` never ask.
        .confirm_quit = true,
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
    .ipc = .{ .write_screen = false }, // also dump screen.txt, status.json and rects.json every frame
    // ── terminal panes ─────────────────────────────────────────────────
    // Read when a pane starts; a pane already open keeps what it began with.
    .terminal = .{
        .scrollback_lines = 10000, // lines kept above the screen per pane (Shift+PageUp, the wheel)
    },

    // ── keys ───────────────────────────────────────────────────────────
    // One line per binding: chord → command id. "" / "none" / "unbound"
    // removes a default. .global applies to both profiles; .vim and
    // .standard on top of it. ZonGen rejects a chord written twice.
    // A shifted Tab has ONE chord however it is written: "shift+tab",
    // "<S-Tab>", "shift+backtab" and "backtab" are all `backtab`, and
    // "ctrl+shift+tab" is "ctrl+backtab" — that is what a terminal
    // sends, so a spec cannot name a key that never arrives.
    .keys = .{
        .global = .{
            .@"ctrl+p" = "picker.files",
            .@"ctrl+shift+p" = "none",
        },
        .vim = .{
            .@"space f f" = "picker.files",
            .@"g d" = "lsp.definition",
        },
        .standard = .{
            .@"ctrl+b" = "tree.toggle",
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
        // "local" (not in this release).
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
        // The Claude Code logins the quota chip and the usage pane
        // (ai.claude_usage) poll. `token_path` is the OAuth token file the
        // CLI's keychain item was copied into (`ai.link_claude_token`, or R
        // in the pane) — `~` expands, a relative path sits under the data
        // root beside the default `ai_token`; `active` marks the one the
        // chip shows alone (the CLI's live login wins when the keychain
        // names one). No entries = one `default` account on `ai_token` — or
        // the 0.2.x `[[ai.claude.accounts]]` blocks, which the migration keeps
        // verbatim as `.ai.claude.accounts` and the reader honours as-is.
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
    .git = .{ .repo_colors = .{ .mnml = "green", .@"mnml-zig" = "blue" } },

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
        .tasks = .{ "build" }, // task names to run on open (exec-bearing)
        // Panes to open. The first entry needs no .split; every later one
        // does. .kind = .pty runs .cmd under $SHELL -c (exec-bearing).
        .layout = .{
            .{ .kind = .editor, .path = "README.md" },
            .{ .kind = .pty, .cmd = "zig build --watch", .split = .right, .ratio = 40 },
        },
        .default_workspace = null, // "~/code/mnml"; ~ is expanded
    },

    // ── snippets / abbr ────────────────────────────────────────────────
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
        // .parser: .vimgrep (default, path:line:col: msg) | .eslint | .tsc | .ruff | .shellcheck | .pattern
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
        .autocapture_to_log = true,
        .profile_mode = .workspace, // .workspace | .shared | .ephemeral
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
        .dev_roots = .{ "../my-integrations" },
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
        // Prepend mnml's own source: the `mnml` catalogue — the
        // integrations mnml itself ships (Jira, Bitbucket, the SDK
        // sample). It is one ZON file, `data/marketplace.zon` in the
        // repo, packaged as `share/mnml/marketplace.zon` beside the
        // binary, so the tab lists the shipped set out of the box with
        // no config at all. Installing one of its rows runs
        // `<binary> --install` and links `<data root>/bin/<name>` at
        // the binary — PREFIX's copy after `run.sh install`, else this
        // checkout's `zig-out/bin` — which is what keeps a manifest
        // from ever hardcoding a repo path. A row says `installed`,
        // `update available` (the catalogue is ahead of the installed
        // manifest's version) or `not installed`.
        // MNML_MARKETPLACE_CATALOGUE=<file> points at a different
        // catalogue; see the three overrides below.
        .use_defaults = true, // prepend mnml's own source: the shipped integration catalogue
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
            .{ .local_folder = .{ .id = "private", .path = "~/mnml-private" } },
        },
        // Three environment overrides, for a scripted run (the .test
        // corpus, the UI specs) and for pointing a session somewhere
        // without editing a config:
        //   MNML_MARKETPLACE_CATALOGUE=<file>   the `mnml` source reads
        //       this catalogue instead of the shipped one. Relative
        //       paths are workspace-relative; `~` expanded.
        //   MNML_MARKETPLACE_LOCAL=<folder>     a local_folder source,
        //       and the ONLY source while it is set.
        //   MNML_MARKETPLACE_GITHUB=<owner>/<repo>[:<apps dir>]
        //       a github_monorepo_apps source (default apps dir
        //       `apps`), and likewise the only source. Pair it with
        //       MNML_MARKETPLACE_API=<base url> to point the fetch at
        //       a server other than api.github.com.
        // LOCAL and GITHUB replace the configured sources entirely;
        // CATALOGUE only changes which file the `mnml` source reads.
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
        .private_sources = .{ "~/mnml-private-scripts" },
        // Folders the Dev tab scans: every subfolder with a script.zon
        // is a script in development, reloaded when one of its files is
        // saved. MNML_SCRIPTS_DEV_ROOTS=<dir:dir> (`;` on Windows)
        // overrides, which is how the corpus and the UI specs point the
        // tab at a folder without writing a config.
        .dev_roots = .{ "../my-scripts" },
        .show_dev_tab = false,
    },

    // ── cloud ──────────────────────────────────────────────────────────
    .cloud_run = .{
        .defaults = .{ .agent_id = "", .env_id = "", .sandbox = "", .model = "" },
    },
    .jira = .{
        .domain = "", // MNML_JIRA_DOMAIN overrides
        .ticket_prefix = "", // MNML_JIRA_TICKET_PREFIX overrides
    },
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
    },

    // ── statusline ─────────────────────────────────────────────────
    .statusline = .{
        .hover_items = 8, // how many things a figure's hover lists before `… and N more`; 0 lists none
    },
}
```

The block above is parsed by a test (`docs config example parses clean`
in `src/config/load.zig`) — it cannot drift from the schema.

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

(`.tasks.<name>` bodies are not in the table: a task only runs when you
ask for it by name.)

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
  font. `chip.in_palette_bar` puts the chip on the palette bar; the
  row's and the chip's right-click menus toggle it (*Hide from top bar*
  / *Show on top bar*).
- A launcher needs at least one command and every command a `run`
  line; a manifest with no `binary` and no command is refused, by
  `--install` and by mnml's scan alike.

Where one comes from: the Marketplace tab (a `github_launcher_folder`
or `local_folder` source — the four in `launchers/` of the mnml-zig
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

`ui.dock` is mnml-zig's own Dock: a strip of the things you *start* —
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
| put a bottom strip above the statusline, or under the `:` line | `:dock inner` / `:dock outer` (`:dock above` / `:dock below` say the same thing), the *Launcher dock placement* row in Settings — worded *above statusline* / *below command line* — or the *Place:* rows on the strip's right-click menu. `ui.dock.placement` is the file form, `.inner` the default. A side edge ignores it: it is a column, and neither of those rows is its business |
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

**The bottom dock's band is the screen's last row; where it PAINTS is
`ui.dock.placement`.** The band — the row the dwell watches, and the
cells the `⋯` grip marks — is the frame's outermost row in both
placements, because the edge is where a hand goes to summon a thing.
What the placement settles is where the strip itself lands.

Under `.inner`, the default, it is the **editor area's last row**:
`always` carves it off the editor, `auto_hide` paints it over that
same row, and the statusline and the `:` line stay exactly where they
are with no dock at all. The `:` line's row is then never the strip's,
so the two coexist — a line can be open while the strip is out. The
grip is still on that row, though, so an open line takes its three
cells back rather than having a handle painted over what is being
typed.

Under `.outer` the strip is the **screen's last row**, under the `:`
line: everything else moves up one, and a revealed strip paints over
that row, covering the toast echo and the `⟳ … running…` chip while
it is up. There the `:` line owns the row outright: while one is open
the band is not watched at all, so the strip neither reveals nor
stays, and its grip goes with it. Closing the line asks for a fresh
`reveal_ms` rather than popping the strip up the same frame.

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

## Bookmarks

`bookmarks.open` is a picker over your web bookmarks, grouped by
environment — `dev  ·  ADX Admin`, the URL as the row's detail; Enter
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
            .name = "ADX Admin",
            .dev = "https://adx.dev.example.net/admin",
            .staging = "https://adx.staging.example.net/admin",
            .prod = "https://adx.example.com/admin",
            .envs = .{ .{ .env = "uat", .url = "https://adx.uat.example.net/admin" } },
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

The one thing deliberately NOT per-profile is the cross-process
rate-limit bucket (`$TATTLE_ARTIFACTS_ROOT` /
`~/.tattle-claude-artifacts/<service>-ratelimit.json`, resolved ahead
of the data root in `sdk/mnml-sdk/src/ratelimit.zig`). It is one
budget per machine: two profiles each spending a full budget against
the same API is the bug, not the feature.

## Writes

Settings screens and toggles write back with `persistScalar`: the file is
parsed, the one value's bytes are replaced in place, and comments and
order survive. A missing key is added at its section's indent; a missing
section is appended. An unchanged value is not written. Before every
write the previous file is copied to `backups/config.<YYYY-MM-DD-HHMMSS>.zon`
next to it, keeping the newest 50.

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
name is the half that survives. `Esc` puts back
the config, the input style, the theme, and the exact bytes of every
file written since the overlay opened — a file that did not exist is
removed again.

Rows are discrete choices (bools, enums, the theme) and numbers
(`tree_width`, `right_panel_width`, `bottom_panel_height`, `wheel_lines`, `md_image_rows`,
`hover_help_height`, `color_column`, `tab_width`, `text_width`,
`chord_timeout_ms` — 73 rows in all); text (`projects_dir`, the
labels) stays a file edit.

### Themes

`.ui.theme` names one of the bundled themes — every `themes/*.zon`,
the 94 NvChad palettes, matched case-insensitively (`"OneDark"` is
`onedark`). `theme.pick` / `:theme` opens a picker that previews as you
move and writes the pick to the home config on Enter; `:theme <name>`
and `:set theme=<name>` pick directly. `theme.toggle` flips to
`.ui.theme_toggle`, or to the first bundled theme of the other kind
when it is unset; `theme.reset` returns to `.ui.theme`;
`theme.auto_system` follows the OS appearance (checked every 15 s) and
`theme.auto_system_off` freezes it. Only a pick writes the file.

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

## Coming from 0.2.x (TOML)

mnml-zig reads no TOML — not `config.toml`, not the theme files, not
`trusted_workspaces.toml`. The last Rust release (0.2.22) carries the
converter, since it is the one that still has the typed TOML config:

```
mnml export-config-zon                # writes ~/.config/mnml/config.zon
mnml export-config-zon --out PATH     # or wherever you like
```

Run it once per config file you keep: the home file, and each
workspace's `.mnml/config.toml` (from inside that workspace, with
`--out .mnml/config.zon`). The output carries a `//` comment per key
from the schema's own doc table, and every key it could not place lands
verbatim in a trailing `// unmigrated:` block so nothing is lost
silently. The TOML file is left where it was; mnml-zig ignores it.

What mnml-zig says about a `config.toml` it finds where a `config.zon`
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
